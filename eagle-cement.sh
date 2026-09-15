#!/usr/bin/env bash
#
# eagle-cement.sh — deploy and operate the Eagle Cement RFID stack on a local
# Ubuntu server as two independent instances: production and staging.
#
# Each instance gets its own database, API process, Angular bundle and RFID
# bridge, so staging can run a different build against different data without
# ever touching production.
#
#   instance   database              API    web    reader port
#   prod       eagle_cement_prod     8000   4200   20059
#   staging    eagle_cement_staging  8001   4201   20059
#
# The reader port is shared: there is one physical reader dialling one IP:port,
# and only the backend URL differs between the two bridges. One TCP port means
# one listener, so exactly one bridge runs at a time — see 'bridge-switch'.
#
# The camera stack (go2rtc) is shared the same way and for the same reason:
# there is one set of gate cameras on one set of ports. It runs as a docker
# compose project once per host, not once per instance, and both APIs point at
# it.
#
#   host component  containers                         ports
#   camera          eagle-cement-go2rtc                1984 api, 8554 rtsp,
#                                                      8555 tcp+udp webrtc
#
# Everything binds 0.0.0.0 except the bridge dashboard, because the readers and
# workstations reach this box over the plant LAN. That includes go2rtc's control
# API, which is unauthenticated — the ufw rules from 'firewall' are what confine
# it to LAN_CIDR.
#
# Usage: sudo ./eagle-cement.sh <command> [instance] [component]
# Run `./eagle-cement.sh help` for the full command list.
#
set -euo pipefail
umask 022

VERSION=1.0.0
SELF="$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# configuration — every value here can be overridden in a conf file
# ---------------------------------------------------------------------------

SOURCE_MODE=local
SRC_ROOT="$(cd "$HERE/.." && pwd)"

GIT_REF_PROD=main
GIT_REF_STAGING=main
GIT_URL_SERVER=git@github.com:Geoplan-Philippines/rfid-based-authorization-server.git
GIT_URL_CLIENT=git@github.com:Geoplan-Philippines/rfid-based-authorization-client.git
GIT_URL_BRIDGE=git@github.com:Geoplan-Philippines/rfid-bridge.git
GIT_URL_CAMERA=git@github.com:Geoplan-Philippines/camera-access.git

APP_ROOT=/opt/eagle-cement
SVC_USER=eagle

API_PORT_PROD=8000
WEB_PORT_PROD=4200
API_PORT_STAGING=8001
WEB_PORT_STAGING=4201

# The one port the reader dials, for both instances. There is a single physical
# reader configured with one IP:port, so this is a property of the hardware, not
# of an instance — the only thing that differs between prod and staging is the
# backend.url the bridge posts to. Two processes cannot hold one TCP port, so
# exactly one bridge runs at a time; 'bridge-switch' hands it over.
BRIDGE_PORT=20059

DB_HOST=127.0.0.1
DB_PORT=5432
DB_USER=eagle
DB_NAME_PROD=eagle_cement_prod
DB_NAME_STAGING=eagle_cement_staging
DB_PASSWORD=

API_BASE_URL=/api/v1
FILE_BASE_URL=

JWT_SECRET_PROD=
JWT_SECRET_STAGING=

RESEND_API_KEY=
RESEND_EAGLE_CEMENT_TEMPLATE_ID=
RESEND_FROM_EMAIL=
RESEND_VERIFY_TEMPLATE_ID=
TRANSACTION_ALERT_RECIPIENTS=
OCR_SPACE_API_KEY=

# --- camera stack (go2rtc + ANPR) ------------------------------------------
# Shared by both instances: one set of gate cameras, one set of ports. Set
# CAMERA_ENABLED=no on a host that has no cameras wired up yet.
CAMERA_ENABLED=yes

CCTV_DOME_URL=
CCTV_FACE_URL=
CCTV_PLATE_URL=

GO2RTC_API_PORT=1984
GO2RTC_RTSP_PORT=8554
GO2RTC_WEBRTC_PORT=8555

# go2rtc hands this address to the browser as its WebRTC candidate. Empty means
# "this box's LAN address", which is what a workstation on the plant LAN needs —
# 127.0.0.1 only ever works for a browser running on the server itself.
GO2RTC_WEBRTC_ADDR=

ANPR_PORT=9137
ANPR_DETECTOR_MODEL=yolo-v9-t-384-license-plate-end2end
ANPR_OCR_MODEL=cct-xs-v2-global-model
ANPR_CONFIDENCE_THRESHOLD=0.4
ANPR_DEVICE=cpu
ANPR_CROP_PADDING=0
ANPR_SAVE_WIDE_IMAGE=true
ANPR_LOG_LEVEL=INFO

# The ANPR service's own push-to-backend path. Off by default: today the NestJS
# side pulls frames through /cctv/anpr/detect instead.
ANPR_UPLOAD_ENABLED=false
ANPR_UPLOAD_INSTANCE=prod

# The server-side worker that polls the plate stream continuously. Only one
# instance should record from the shared camera, so staging is off by default.
ANPR_CONTINUOUS_PROD=true
ANPR_CONTINUOUS_STAGING=false
ANPR_STREAM_ID=gate_plate
ANPR_POLL_INTERVAL_MS=1500

BRIDGE_FRAME_FORMAT=AUTO_DETECT
BRIDGE_SESSION_GAP_MS=120000
BRIDGE_SESSION_MAX_MS=0
BRIDGE_LOG_RAW_PROD=false
BRIDGE_LOG_RAW_STAGING=true
BRIDGE_UI_EXPOSE=no
BRIDGE_UI_PORT_PROD=20090
BRIDGE_UI_PORT_STAGING=20091

# Empty means: derive it from the subnet this box sits on.
LAN_CIDR=

NODE_MAJOR=22

# Later files win, so /etc beats a conf sitting next to the script.
# The /etc copy is mode 600 and root-owned, so a non-root user reading it would
# abort the script — skip it instead, keeping 'help' and 'status' usable.
for _f in "$HERE/eagle-cement.conf" /etc/eagle-cement/deploy.conf; do
    if [[ -f $_f && -r $_f ]]; then
        # shellcheck disable=SC1090
        source "$_f"
    elif [[ -f $_f && $EUID -ne 0 ]]; then
        printf 'note: %s is not readable as this user — using defaults.\n' "$_f" >&2
    fi
done

INSTANCES=(prod staging)

# Per-instance components: built and run once for prod and once for staging.
ALL_COMPONENTS=(server client bridge)
# Host components: one shared deployment that both instances talk to.
HOST_COMPONENTS=(camera)

CAMERA_DIR="$APP_ROOT/camera"
COMPOSE_PROJECT=eagle-cement-camera

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_BOLD=
fi

log()   { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
step()  { printf '%s  ·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
ok()    { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }
head1() { printf '\n%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

need_root() {
    [[ $EUID -eq 0 ]] || die "'$1' needs root. Re-run with: sudo $SELF $*"
}

confirm() {
    local prompt=$1 answer
    read -r -p "$prompt [y/N] " answer </dev/tty || true
    [[ ${answer,,} == y || ${answer,,} == yes ]]
}

# Runs a build step as the unprivileged service user with a writable HOME, so
# bun/npm/angular caches land somewhere real instead of failing on /nonexistent.
as_svc() {
    runuser -u "$SVC_USER" -- env \
        HOME="$APP_ROOT/.home" \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        "$@"
}

# ---------------------------------------------------------------------------
# instance / component resolution
#
# These set shell arrays in the *current* shell rather than piping through a
# subshell, so a bad argument aborts the whole run instead of silently
# producing an empty loop.
# ---------------------------------------------------------------------------

# Sets INST, INST_DIR, ports, DB_NAME, GIT_REF, JWT_SECRET, BRIDGE_LOG_RAW.
load_instance() {
    case "${1:-}" in
        prod)
            INST=prod
            API_PORT=$API_PORT_PROD
            WEB_PORT=$WEB_PORT_PROD
            BRIDGE_UI_PORT=$BRIDGE_UI_PORT_PROD
            DB_NAME=$DB_NAME_PROD
            GIT_REF=$GIT_REF_PROD
            JWT_SECRET=$JWT_SECRET_PROD
            BRIDGE_LOG_RAW=$BRIDGE_LOG_RAW_PROD
            ANPR_CONTINUOUS=$ANPR_CONTINUOUS_PROD
            ;;
        staging)
            INST=staging
            API_PORT=$API_PORT_STAGING
            WEB_PORT=$WEB_PORT_STAGING
            BRIDGE_UI_PORT=$BRIDGE_UI_PORT_STAGING
            DB_NAME=$DB_NAME_STAGING
            GIT_REF=$GIT_REF_STAGING
            JWT_SECRET=$JWT_SECRET_STAGING
            BRIDGE_LOG_RAW=$BRIDGE_LOG_RAW_STAGING
            ANPR_CONTINUOUS=$ANPR_CONTINUOUS_STAGING
            ;;
        *) die "unknown instance '${1:-}' — expected: prod | staging | all" ;;
    esac
    INST_DIR="$APP_ROOT/$INST"
}

select_instances() {
    case "${1:-all}" in
        all)          SELECTED_INSTANCES=("${INSTANCES[@]}") ;;
        prod|staging) SELECTED_INSTANCES=("$1") ;;
        *) die "unknown instance '$1' — expected: prod | staging | all" ;;
    esac
}

# Splits the requested component into the per-instance set (looped over prod and
# staging) and the host-level set (done once). 'camera' belongs to the host, so
# asking for it selects no per-instance work at all.
select_components() {
    case "${1:-all}" in
        all)
            SELECTED_COMPONENTS=("${ALL_COMPONENTS[@]}")
            # A host with no cameras wired up yet still deploys everything else.
            if [[ ${CAMERA_ENABLED,,} == yes ]]
            then SELECTED_HOST_COMPONENTS=("${HOST_COMPONENTS[@]}")
            else SELECTED_HOST_COMPONENTS=()
            fi
            ;;
        server|client|bridge)
            SELECTED_COMPONENTS=("$1")
            SELECTED_HOST_COMPONENTS=()
            ;;
        camera)
            SELECTED_COMPONENTS=()
            SELECTED_HOST_COMPONENTS=(camera)
            ;;
        *) die "unknown component '$1' — expected: server | client | bridge | camera | all" ;;
    esac
}

# Where each component's source is synced to and built.
app_dir() {
    case "$1" in
        server) echo "$INST_DIR/server" ;;
        client) echo "$INST_DIR/client" ;;
        bridge) echo "$INST_DIR/bridge-src" ;;
        camera) echo "$CAMERA_DIR/camera-access" ;;
    esac
}

repo_dir() {
    case "$1" in
        server) echo "rfid-based-authorization-server" ;;
        client) echo "rfid-based-authorization-client" ;;
        bridge) echo "rfid-bridge" ;;
        camera) echo "camera-access" ;;
    esac
}

git_url() {
    case "$1" in
        server) echo "$GIT_URL_SERVER" ;;
        client) echo "$GIT_URL_CLIENT" ;;
        bridge) echo "$GIT_URL_BRIDGE" ;;
        camera) echo "$GIT_URL_CAMERA" ;;
    esac
}

lan_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
    [[ -n $ip ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip:-127.0.0.1}"
}

# The subnet the readers and workstations live on. Derived from the interface
# holding the primary address unless LAN_CIDR pins it explicitly.
lan_cidr() {
    if [[ -n $LAN_CIDR ]]; then echo "$LAN_CIDR"; return; fi
    local ip iface cidr
    ip=$(lan_ip)
    iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
    cidr=$(ip -4 -o route show scope link dev "$iface" 2>/dev/null \
        | awk '$1 ~ /\// {print $1; exit}')
    echo "${cidr:-$ip/32}"
}

# Prints the database password, generating it on first use. Returns non-zero
# (rather than aborting) when it exists but is not readable, so the read-only
# reporting commands still work for a non-root user — they just cannot probe
# the database.
db_password() {
    if [[ -n $DB_PASSWORD ]]; then printf '%s' "$DB_PASSWORD"; return; fi
    local f="$APP_ROOT/.db-password"
    if [[ -s $f ]]; then
        [[ -r $f ]] || return 1
        cat "$f"
        return
    fi
    [[ $EUID -eq 0 ]] || return 1
    install -d -m 755 "$APP_ROOT"
    (umask 077; openssl rand -hex 24 > "$f")
    cat "$f"
}

database_url() {
    printf 'postgresql://%s:%s@%s:%s/%s?schema=public' \
        "$DB_USER" "$(db_password)" "$DB_HOST" "$DB_PORT" "$DB_NAME"
}

# ---------------------------------------------------------------------------
# bootstrap — one-time host preparation
# ---------------------------------------------------------------------------

cmd_bootstrap() {
    need_root bootstrap
    log "Preparing this host for the Eagle Cement stack"

    step "Installing base packages"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y -qq
    apt-get install -y -qq \
        curl ca-certificates gnupg git rsync unzip jq openssl iproute2 \
        postgresql postgresql-contrib nginx openjdk-17-jdk-headless

    install_node
    install_bun
    [[ ${CAMERA_ENABLED,,} == yes ]] && install_docker

    step "Creating service user '$SVC_USER'"
    if ! id "$SVC_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$APP_ROOT/.home" --create-home \
                --shell /usr/sbin/nologin "$SVC_USER"
    fi
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$APP_ROOT" "$APP_ROOT/.home"

    local inst
    for inst in "${INSTANCES[@]}"; do
        load_instance "$inst"
        install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 \
            "$INST_DIR" "$INST_DIR/server" "$INST_DIR/client" "$INST_DIR/web" \
            "$INST_DIR/bridge" "$INST_DIR/bridge-src" \
            "$INST_DIR/uploads" "$INST_DIR/backups"
    done

    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 \
            "$CAMERA_DIR" "$CAMERA_DIR/camera-access"
    fi

    step "Enabling PostgreSQL"
    systemctl enable --now postgresql

    # Every site we generate listens on its own port (4200/4201), so nginx has
    # no reason to hold :80. The stock 'default' site does, which makes nginx
    # refuse to start on any host already running something there.
    if [[ -e /etc/nginx/sites-enabled/default ]]; then
        step "Disabling the stock nginx 'default' site (it binds :80)"
        rm -f /etc/nginx/sites-enabled/default
    fi

    step "Enabling nginx"
    systemctl enable nginx
    nginx -t >/dev/null 2>&1 || { nginx -t; die "the base nginx config is broken"; }
    reload_nginx

    write_systemd_units

    step "Linking $SELF into /usr/local/bin/eaglectl"
    ln -sf "$HERE/$SELF" /usr/local/bin/eaglectl

    ok "Host ready. Next: sudo $SELF init all"
}

install_node() {
    local have=0
    command -v node >/dev/null 2>&1 && have=$(node -v | sed 's/^v//; s/\..*//')
    if (( have >= 20 )); then
        step "Node.js $(node -v) already present"
        return
    fi
    step "Installing Node.js $NODE_MAJOR from NodeSource"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y -qq nodejs
}

install_bun() {
    if command -v bun >/dev/null 2>&1; then
        step "bun $(bun --version) already present"
        return
    fi
    step "Installing bun (both repos ship a bun.lock)"
    BUN_INSTALL=/opt/bun bash -c 'curl -fsSL https://bun.sh/install | bash'
    ln -sf /opt/bun/bin/bun  /usr/local/bin/bun
    ln -sf /opt/bun/bin/bunx /usr/local/bin/bunx
    chmod -R a+rX /opt/bun
}

# The camera stack ships as containers (go2rtc upstream publishes no .deb, and
# the ANPR service needs a pinned Python/ONNX runtime), so the host needs Docker
# and the compose v2 plugin. Ubuntu's own docker.io is often too old to have
# 'docker compose', so prefer Docker's apt repo and fall back to the distro
# packages only if that is unreachable.
install_docker() {
    if docker compose version >/dev/null 2>&1; then
        step "Docker $(docker --version | awk '{print $3}' | tr -d ,) with compose v2 already present"
        systemctl enable --now docker >/dev/null 2>&1 || true
        return
    fi

    step "Installing Docker Engine and the compose plugin"
    install -d -m 755 /etc/apt/keyrings
    if curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc 2>/dev/null; then
        chmod a+r /etc/apt/keyrings/docker.asc
        local codename
        codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
            "$(dpkg --print-architecture)" "$codename" > /etc/apt/sources.list.d/docker.list
        apt-get update -y -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    else
        warn "download.docker.com is unreachable — falling back to the distro packages"
        apt-get install -y -qq docker.io docker-compose-v2
    fi

    docker compose version >/dev/null 2>&1 \
        || die "Docker is installed but 'docker compose' is not available — install the compose v2 plugin"
    systemctl enable --now docker
}

write_systemd_units() {
    step "Installing systemd template units"

    cat > /etc/systemd/system/eagle-api@.service <<EOF
[Unit]
Description=Eagle Cement API (%i)
Documentation=https://github.com/Geoplan-Philippines/rfid-based-authorization-server
After=network-online.target postgresql.service
Wants=network-online.target
Requires=postgresql.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
# The app reads .env from its working directory and serves uploads from
# ./uploads, so the working directory is what separates prod from staging.
WorkingDirectory=$APP_ROOT/%i/server
ExecStart=/usr/bin/node $APP_ROOT/%i/server/dist/main.js
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20
SyslogIdentifier=eagle-api-%i

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP_ROOT/%i

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/eagle-bridge@.service <<EOF
[Unit]
Description=Eagle Cement RFID Bridge (%i)
Documentation=https://github.com/Geoplan-Philippines/rfid-bridge
After=network-online.target eagle-api@%i.service
Wants=network-online.target eagle-api@%i.service

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
WorkingDirectory=$APP_ROOT/%i/bridge
# HOME steers the bridge's log dir to <workdir>/RfidBridge/logs.
Environment=HOME=$APP_ROOT/%i/bridge
ExecStart=/usr/bin/java -Djava.awt.headless=true -Dbridge.config=$APP_ROOT/%i/bridge/bridge.properties -jar $APP_ROOT/%i/bridge/rfid-bridge.jar
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=20
SyslogIdentifier=eagle-bridge-%i

NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=$APP_ROOT/%i

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

# ---------------------------------------------------------------------------
# init — database + per-instance configuration
# ---------------------------------------------------------------------------

cmd_init() {
    need_root init "$@"
    select_instances "${1:-all}"
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        head1 "Initialising '$INST'"
        init_database
        write_server_env
        write_bridge_properties
        write_nginx_site
    done
    reload_nginx

    # Host-level and shared, so it is written once regardless of which instance
    # was asked for.
    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        head1 "Initialising the shared camera stack"
        write_camera_config
    fi

    ok "Configuration written. Next: sudo $SELF deploy ${1:-all}"
}

psql_admin() { runuser -u postgres -- psql -v ON_ERROR_STOP=1 -tAc "$1"; }

init_database() {
    local pass; pass=$(db_password)

    if [[ $(psql_admin "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'") == 1 ]]; then
        step "Role '$DB_USER' exists — syncing its password"
        psql_admin "ALTER ROLE $DB_USER WITH LOGIN PASSWORD '$pass'" >/dev/null
    else
        step "Creating role '$DB_USER'"
        psql_admin "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$pass'" >/dev/null
    fi

    if [[ $(psql_admin "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'") == 1 ]]; then
        step "Database '$DB_NAME' already exists — left as it is"
    else
        step "Creating database '$DB_NAME'"
        psql_admin "CREATE DATABASE $DB_NAME OWNER $DB_USER" >/dev/null
    fi

    # Prisma migrations create and drop objects in the public schema.
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -d "$DB_NAME" \
        -c "GRANT ALL ON SCHEMA public TO $DB_USER" >/dev/null
}

write_server_env() {
    local envfile="$INST_DIR/server/.env" secret=$JWT_SECRET

    if [[ -z $secret ]]; then
        # Reuse the existing secret so a re-init does not sign everyone out.
        [[ -f $envfile ]] && secret=$(sed -n 's/^JWT_SECRET=//p' "$envfile" | head -1)
        [[ -n $secret ]] || secret=$(openssl rand -hex 32)
    fi

    step "Writing $envfile"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$INST_DIR/server"
    {
        echo "# Generated by $SELF for the '$INST' instance."
        echo "# Re-run 'sudo $SELF init $INST' to refresh it."
        echo "NODE_ENV=production"
        echo "PORT=$API_PORT"
        echo
        echo "DATABASE_URL=$(database_url)"
        echo
        echo "# The bundle is same-origin behind nginx, so CORS only matters for a"
        echo "# dev client or a direct-to-API tool elsewhere on the LAN."
        echo "CORS_ALLOWED_ORIGINS=http://localhost:$WEB_PORT,http://$(lan_ip):$WEB_PORT"
        echo
        echo "JWT_SECRET=$secret"
        echo
        echo "RESEND_API_KEY=${RESEND_API_KEY:-null}"
        echo "RESEND_FROM_EMAIL=$RESEND_FROM_EMAIL"
        [[ -n $RESEND_VERIFY_TEMPLATE_ID ]] && echo "RESEND_VERIFY_TEMPLATE_ID=$RESEND_VERIFY_TEMPLATE_ID"
        echo "RESEND_EAGLE_CEMENT_TEMPLATE_ID=$RESEND_EAGLE_CEMENT_TEMPLATE_ID"
        echo "TRANSACTION_ALERT_RECIPIENTS=$TRANSACTION_ALERT_RECIPIENTS"
        echo
        echo "OCR_SPACE_API_KEY=${OCR_SPACE_API_KEY:-null}"
        echo
        echo "# The camera stack is shared by both instances. It listens on all"
        echo "# interfaces, but an API on this box takes the loopback path."
        echo "GO2RTC_API_URL=http://127.0.0.1:$GO2RTC_API_PORT"
        echo "ANPR_SERVICE_URL=http://127.0.0.1:$ANPR_PORT"
        echo "# One camera, so only one instance should be recording from it."
        echo "ANPR_CONTINUOUS_ENABLED=$([[ ${CAMERA_ENABLED,,} == yes ]] && echo "$ANPR_CONTINUOUS" || echo false)"
        echo "ANPR_STREAM_ID=$ANPR_STREAM_ID"
        echo "ANPR_POLL_INTERVAL_MS=$ANPR_POLL_INTERVAL_MS"
    } > "$envfile"
    chown "$SVC_USER:$SVC_USER" "$envfile"
    chmod 600 "$envfile"
}

write_bridge_properties() {
    local propfile="$INST_DIR/bridge/bridge.properties" key=""

    # Never clobber a minted API key on re-init.
    [[ -f $propfile ]] && key=$(sed -n 's/^api\.key=//p' "$propfile" | head -1)

    step "Writing $propfile"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$INST_DIR/bridge"
    cat > "$propfile" <<EOF
# Generated by $SELF for the '$INST' instance.
# On the reader, set Destination IP to $(lan_ip) and Destination Port to $BRIDGE_PORT.
listen.port=$BRIDGE_PORT

# Straight to the API over loopback — no nginx hop, no upload size limit.
backend.url=http://127.0.0.1:$API_PORT/api/v1/transactions/rfid-reads

# Mint one with: sudo $SELF bridge-key $INST
api.key=$key

post.enabled=true
frame.format=$BRIDGE_FRAME_FORMAT

# One tag presence = one POST = one backend transaction. session.gap.ms is the
# quiet time with no reads before a tag's session closes.
session.gap.ms=$BRIDGE_SESSION_GAP_MS
session.max.ms=$BRIDGE_SESSION_MAX_MS

log.raw=$BRIDGE_LOG_RAW
EOF
    chown "$SVC_USER:$SVC_USER" "$propfile"
    chmod 600 "$propfile"
    [[ -n $key ]] || warn "no API key yet for '$INST' — run: sudo $SELF bridge-key $INST"
}

write_nginx_site() {
    local site=/etc/nginx/sites-available/eagle-cement-$INST.conf
    step "Writing $site (listen $WEB_PORT)"
    cat > "$site" <<EOF
# Generated by $SELF for the '$INST' instance. Do not edit by hand.
server {
    listen $WEB_PORT;
    listen [::]:$WEB_PORT;
    server_name _;

    root $INST_DIR/web;
    index index.html;

    # Truck/driver photos and plate crops are posted through here.
    client_max_body_size 25m;

    access_log /var/log/nginx/eagle-cement-$INST.access.log;
    error_log  /var/log/nginx/eagle-cement-$INST.error.log;

    location /api/ {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }

    location /uploads/ {
        proxy_pass http://127.0.0.1:$API_PORT;
        proxy_set_header Host \$host;
    }

    location ~* \.(?:js|css|woff2?|png|jpe?g|gif|svg|ico)\$ {
        expires 30d;
        add_header Cache-Control "public";
        try_files \$uri =404;
    }

    # Angular routes are client-side: anything else falls through to index.html.
    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    ln -sfn "$site" "/etc/nginx/sites-enabled/eagle-cement-$INST.conf"
    nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx rejected the generated config"; }
}

reload_nginx() {
    systemctl reload nginx 2>/dev/null && return 0
    systemctl restart nginx 2>/dev/null && return 0

    # Almost always a port clash: another web server already owns a port one of
    # the enabled sites wants. Name the culprit instead of the systemd boilerplate.
    warn "nginx would not start. Ports currently in use by other processes:"
    local port
    for port in 80 443 ${WEB_PORT:-}; do
        ss -lptnH "sport = :$port" 2>/dev/null \
            | grep -v nginx | sed 's/^/      /' || true
    done
    die "resolve the conflict (or stop the other server), then: systemctl restart nginx"
}

# ---------------------------------------------------------------------------
# camera stack — go2rtc + the ANPR service, as one docker compose project
#
# Shared by both instances because the gate cameras are: one RTSP source per
# view, one WebRTC listener, one model in memory.
#
# Every port is published on 0.0.0.0, so go2rtc's API, its RTSP republisher and
# the ANPR service are all reachable from other machines on the plant LAN —
# useful for VLC, for /docs, and for testing a detection from a workstation.
# Note that go2rtc's control API is unauthenticated: anyone who can reach
# GO2RTC_API_PORT can add, remove or repoint a stream. The ufw rules written by
# 'firewall' scope that to LAN_CIDR, which is the only thing limiting it.
#
# The two APIs on this box still talk to the stack over 127.0.0.1 — same
# listener, shortest path.
# ---------------------------------------------------------------------------

# Runs docker compose against the generated project. Every call is from inside
# CAMERA_DIR because the compose file's build context and bind mounts are
# relative to it.
compose() {
    ( cd "$CAMERA_DIR" && docker compose -p "$COMPOSE_PROJECT" "$@" )
}

camera_available() {
    [[ ${CAMERA_ENABLED,,} == yes ]] || return 1
    command -v docker >/dev/null 2>&1
}

write_camera_config() {
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 \
        "$CAMERA_DIR" "$CAMERA_DIR/camera-access"
    write_compose_file
    write_go2rtc_config
}

write_compose_file() {
    local file="$CAMERA_DIR/docker-compose.yml"
    step "Writing $file"
    cat > "$file" <<EOF
# Generated by $SELF. Do not edit by hand — 'sudo $SELF init' rewrites it.
name: $COMPOSE_PROJECT

services:
  # RTSP -> WebRTC/WHEP gateway and snapshot source for the gate cameras.
  go2rtc:
    image: alexxit/go2rtc:latest
    container_name: eagle-cement-go2rtc
    restart: unless-stopped
    env_file:
      - ./camera-access/.env
    volumes:
      - ./camera-access/go2rtc.yaml:/config/go2rtc.yaml:ro
    ports:
      # All published on 0.0.0.0 so other machines on the plant LAN can reach
      # them directly. go2rtc's API has no authentication, so the ufw rules
      # written by '$SELF firewall' are what keeps this to \$LAN_CIDR.
      - "$GO2RTC_API_PORT:1984"
      # WebRTC media: the browser connects to this one directly, over whichever
      # transport it negotiates, so both tcp and udp.
      - "$GO2RTC_WEBRTC_PORT:8555/tcp"
      - "$GO2RTC_WEBRTC_PORT:8555/udp"
      # Re-published RTSP, for VLC while commissioning.
      - "$GO2RTC_RTSP_PORT:8554"
EOF
}

write_go2rtc_config() {
    local envfile="$CAMERA_DIR/camera-access/.env"
    local conf="$CAMERA_DIR/camera-access/go2rtc.yaml"
    local addr=${GO2RTC_WEBRTC_ADDR:-$(lan_ip)}

    step "Writing $envfile"
    {
        echo "# Generated by $SELF. RTSP sources for the gate cameras."
        echo "CCTV_DOME_URL=$CCTV_DOME_URL"
        echo "CCTV_FACE_URL=$CCTV_FACE_URL"
        echo "CCTV_PLATE_URL=$CCTV_PLATE_URL"
    } > "$envfile"
    chown "$SVC_USER:$SVC_USER" "$envfile"
    chmod 600 "$envfile"          # the RTSP URLs carry the camera passwords

    step "Writing $conf (WebRTC candidate $addr:$GO2RTC_WEBRTC_PORT)"
    cat > "$conf" <<EOF
# Generated by $SELF for the Eagle Cement gate cameras. Do not edit by hand.
streams:
  # Gate Dome (PTZ / gate overview)
  gate_dome: "\${CCTV_DOME_URL}"

  # Gate Face Recognition (driver ID)
  gate_face: "\${CCTV_FACE_URL}"

  # Gate License Plate Recognition (ANPR)
  gate_plate: "\${CCTV_PLATE_URL}"

api:
  listen: ":1984"
  origin: "*"

rtsp:
  listen: ":8554"

webrtc:
  listen: ":8555"
  # The address the browser is told to send media to. A workstation on the LAN
  # cannot reach 127.0.0.1, so this has to be the address of this box.
  candidates:
    - $addr:$GO2RTC_WEBRTC_PORT
EOF
    chown "$SVC_USER:$SVC_USER" "$conf"

    if [[ -z $CCTV_DOME_URL || -z $CCTV_FACE_URL || -z $CCTV_PLATE_URL ]]; then
        warn "one or more CCTV_*_URL values are empty — those streams will not come up."
        warn "set them in /etc/eagle-cement/deploy.conf, then: sudo $SELF init"
    fi
}

# ---------------------------------------------------------------------------
# deploy
# ---------------------------------------------------------------------------

cmd_deploy() {
    need_root deploy "$@"
    select_instances "${1:-all}"
    select_components "${2:-all}"

    # The shared camera stack first, and once — it is what the instances' ANPR
    # workers connect to, and it is not per-instance work. It also leaves
    # load_instance's variables pointing at ANPR_UPLOAD_INSTANCE, so it has to
    # happen before the loop below re-loads them.
    local hcomp
    for hcomp in ${SELECTED_HOST_COMPONENTS[@]+"${SELECTED_HOST_COMPONENTS[@]}"}; do
        head1 "Deploying $hcomp (shared by both instances)"
        "deploy_$hcomp"
    done

    local inst comp
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        for comp in ${SELECTED_COMPONENTS[@]+"${SELECTED_COMPONENTS[@]}"}; do
            head1 "Deploying $comp → $INST"
            sync_source "$comp"
            "deploy_$comp"
        done
    done

    ok "Deploy finished."
    cmd_urls "${1:-all}"
}

# Refreshes <app_dir> from the source of truth, leaving build output, installed
# dependencies and secrets in place (rsync does not delete excluded paths).
sync_source() {
    local comp=$1 src dest
    dest=$(app_dir "$comp")

    if [[ $SOURCE_MODE == git ]]; then
        # The camera repo is host-level: one checkout, not one per instance.
        case "$comp" in
            camera) src="$APP_ROOT/checkout/host/$comp" ;;
            *)      src="$APP_ROOT/checkout/$INST/$comp" ;;
        esac
        fetch_checkout "$comp" "$src"
    else
        src="$SRC_ROOT/$(repo_dir "$comp")"
        [[ -d $src ]] || die "source not found: $src (set SRC_ROOT, or use SOURCE_MODE=git)"
        step "Syncing from $src"
    fi

    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$dest"
    # The build-output and runtime-state excludes are anchored with a leading
    # slash so they only match at the repo root. Unanchored, rsync matches the
    # basename at any depth, which silently dropped src/common/uploads/ and
    # broke the server build.
    # *.tsbuildinfo is incremental-build state describing a dist/ that only ever
    # existed on the developer's machine. Copied here it makes tsc believe the
    # output is current and emit nothing, so the build "succeeds" with no
    # dist/main.js. Build state must never travel between hosts.
    rsync -a --delete \
        --exclude '.git' --exclude 'node_modules' --exclude '.env' \
        --exclude '*.tsbuildinfo' --exclude '__pycache__' \
        --exclude '/dist' --exclude '/build' --exclude '/out' \
        --exclude '/target' --exclude '/.angular' \
        --exclude '/.venv' --exclude '/venv' \
        --exclude '/uploads' --exclude '/backups' --exclude '/snapshots' \
        "$src/" "$dest/"
    chown -R "$SVC_USER:$SVC_USER" "$dest"
}

fetch_checkout() {
    local comp=$1 dir=$2 url
    url=$(git_url "$comp")
    if [[ ! -d $dir/.git ]]; then
        step "Cloning $url"
        install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$(dirname "$dir")"
        as_svc git clone --quiet "$url" "$dir"
    fi
    step "Fetching $GIT_REF"
    as_svc git -C "$dir" fetch --quiet --all --prune
    as_svc git -C "$dir" checkout --quiet "$GIT_REF"
    as_svc git -C "$dir" reset --quiet --hard "origin/$GIT_REF" 2>/dev/null \
        || as_svc git -C "$dir" reset --quiet --hard "$GIT_REF"
    step "Now at $(git -C "$dir" log -1 --format='%h %s' | cut -c1-72)"
}

deploy_server() {
    local dir="$INST_DIR/server"

    # Uploaded photos must outlive deploys, so they live outside the app dir.
    if [[ ! -L $dir/uploads ]]; then
        [[ -d $dir/uploads ]] && rsync -a "$dir/uploads/" "$INST_DIR/uploads/"
        rm -rf "$dir/uploads"
        ln -sfn "$INST_DIR/uploads" "$dir/uploads"
        chown -h "$SVC_USER:$SVC_USER" "$dir/uploads"
    fi

    step "Installing dependencies (bun)"
    bun_install "$dir"

    step "Generating the Prisma client"
    as_svc bash -c "cd '$dir' && bunx prisma generate"

    step "Applying migrations to $DB_NAME"
    as_svc bash -c "cd '$dir' && bunx prisma migrate deploy"

    step "Building"
    # nest's deleteOutDir wipes dist/ but leaves tsbuildinfo behind, which then
    # describes output that no longer exists. Clear it so the build is honest.
    find "$dir" -maxdepth 2 -name '*.tsbuildinfo' -delete 2>/dev/null || true
    as_svc bash -c "cd '$dir' && bun run build"
    # A nested dist/src/main.js means a .ts file outside src/ crept into the
    # build, pushing tsc's inferred rootDir up to the project root. Say so —
    # 'no dist/main.js' alone sends people hunting for a compile error that
    # never happened, because the build itself succeeds.
    if [[ ! -f $dir/dist/main.js ]]; then
        [[ -f $dir/dist/src/main.js ]] && die \
            "the build emitted dist/src/main.js, not dist/main.js — something outside src/ is in the build; check 'include'/'exclude'/'rootDir' in tsconfig.build.json"
        die "the build produced no dist/main.js"
    fi

    step "Restarting eagle-api@$INST"
    systemctl enable --quiet --now "eagle-api@$INST" 2>/dev/null || true
    systemctl restart "eagle-api@$INST"

    if wait_for_http "http://127.0.0.1:$API_PORT/api/v1/health" 45; then
        ok "API healthy on :$API_PORT"
    else
        warn "the API did not answer /health in time — check: $SELF logs $INST server"
    fi
}

deploy_client() {
    local dir="$INST_DIR/client" out="$INST_DIR/web"

    # The API URL is compiled into the bundle, so this has to be written after
    # the source sync and before the build.
    step "Pointing the bundle at '${API_BASE_URL}' (same origin, via nginx)"
    cat > "$dir/src/environments/environment.prod.ts" <<EOF
// Generated by $SELF for the '$INST' instance.
export const environment = {
  production: true,
  apiBaseUrl: '$API_BASE_URL',
  /** Server origin (no /api/v1) used to resolve relative uploaded photo paths. */
  fileBaseUrl: '$FILE_BASE_URL',
};
EOF
    chown "$SVC_USER:$SVC_USER" "$dir/src/environments/environment.prod.ts"

    step "Installing dependencies (bun)"
    bun_install "$dir"

    step "Building the Angular bundle"
    as_svc bash -c "cd '$dir' && bun run build"

    local dist
    dist=$(find "$dir/dist" -maxdepth 2 -type d -name browser 2>/dev/null | head -1)
    [[ -n $dist ]] || dist=$(find "$dir/dist" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)
    [[ -n $dist && -f $dist/index.html ]] || die "no index.html in the Angular output"

    step "Publishing to $out"
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$out"
    rsync -a --delete "$dist/" "$out/"
    chown -R "$SVC_USER:$SVC_USER" "$out"
    chmod -R a+rX "$out"          # nginx runs as www-data and only reads

    reload_nginx
    if wait_for_http "http://127.0.0.1:$WEB_PORT/" 15; then
        ok "Client served on :$WEB_PORT"
    else
        warn "nginx did not answer on :$WEB_PORT — check: $SELF logs $INST nginx"
    fi
}

deploy_camera() {
    [[ ${CAMERA_ENABLED,,} == yes ]] \
        || die "CAMERA_ENABLED is not 'yes' — nothing to deploy"
    command -v docker >/dev/null 2>&1 \
        || die "docker is not installed — run: sudo $SELF bootstrap"

    # Host-level, so there is no instance ref to follow; the camera stack tracks
    # whatever production tracks.
    GIT_REF=$GIT_REF_PROD

    sync_source camera

    # Stop standalone eagle-camera container if present so it doesn't conflict on port 1984
    if docker inspect eagle-camera >/dev/null 2>&1; then
        step "Stopping standalone container 'eagle-camera' to release port $GO2RTC_API_PORT"
        docker stop eagle-camera >/dev/null 2>&1 || true
        docker rm eagle-camera >/dev/null 2>&1 || true
    fi

    # Written after the sync: rsync --delete would otherwise replace the
    # generated go2rtc.yaml with the repo's development copy.
    write_camera_config

    step "Pulling go2rtc image"
    compose pull --quiet go2rtc || warn "could not pull go2rtc — using the cached image"

    step "Starting the camera stack"
    compose up -d --remove-orphans

    if wait_for_http "http://127.0.0.1:$GO2RTC_API_PORT/api/streams" 30; then
        ok "go2rtc answering on :$GO2RTC_API_PORT"
        camera_stream_report
    else
        warn "go2rtc did not answer in time — check: $SELF logs camera"
    fi
}

# go2rtc reports a stream as configured whether or not the camera answers, so
# say which ones actually have a producer attached.
camera_stream_report() {
    local body
    body=$(curl -fsS --max-time 5 "http://127.0.0.1:$GO2RTC_API_PORT/api/streams" 2>/dev/null) || return 0
    local name
    while read -r name; do
        [[ -n $name ]] || continue
        if curl -fsS --max-time 8 -o /dev/null \
            "http://127.0.0.1:$GO2RTC_API_PORT/api/frame.jpeg?src=$name" 2>/dev/null
        then ok "  stream '$name' is producing frames"
        else warn "  stream '$name' is configured but produced no frame — check the RTSP URL"
        fi
    done < <(jq -r 'keys[]' <<<"$body" 2>/dev/null)
}

# Which instance's bridge service is currently up, or empty if none. Only
# meaningful because the two share a reader port and so exclude each other.
bridge_port_holder() {
    local i
    for i in "${INSTANCES[@]}"; do
        if systemctl is-active --quiet "eagle-bridge@$i" 2>/dev/null; then
            echo "$i"; return
        fi
    done
    echo ""
}

# Hands the reader to one instance: stop whoever holds the port, start this one.
cmd_bridge_switch() {
    need_root bridge-switch "$@"
    local target=${1:-}
    [[ -n $target ]] || die "usage: $SELF bridge-switch <prod|staging>"
    load_instance "$target"

    [[ -f $INST_DIR/bridge/rfid-bridge.jar ]] \
        || die "'$target' has no bridge deployed — run: sudo $SELF deploy $target bridge"

    local holder; holder=$(bridge_port_holder)
    if [[ $holder == "$target" ]]; then
        ok "'$target' already owns the reader on :$BRIDGE_PORT — nothing to do."
        return
    fi

    log "Handing the reader on :$BRIDGE_PORT to '$target'"

    local other
    for other in "${INSTANCES[@]}"; do
        [[ $other == "$target" ]] && continue
        if systemctl is-active --quiet "eagle-bridge@$other" 2>/dev/null \
           || systemctl is-enabled --quiet "eagle-bridge@$other" 2>/dev/null; then
            step "stopping eagle-bridge@$other"
            systemctl disable --now "eagle-bridge@$other" >/dev/null 2>&1 || true
        fi
    done

    # The old listener needs a moment to release the port before the new one binds.
    local waited=0
    while ss -ltn 2>/dev/null | grep -q ":$BRIDGE_PORT " && (( waited < 10 )); do
        sleep 1; (( waited++ ))
    done

    step "starting eagle-bridge@$target"
    systemctl enable --quiet --now "eagle-bridge@$target" 2>/dev/null || true
    systemctl restart "eagle-bridge@$target"
    sleep 3

    if ss -ltn 2>/dev/null | grep -q ":$BRIDGE_PORT "; then
        ok "reader $(lan_ip):$BRIDGE_PORT → $target (API :$API_PORT)"
    else
        die "'$target' did not take the port — check: $SELF logs $target bridge"
    fi

    if ! grep -q '^api\.key=..*' "$INST_DIR/bridge/bridge.properties" 2>/dev/null; then
        warn "bridge '$target' has no API key — its POSTs will be rejected with 401."
        warn "run: sudo $SELF bridge-key $target"
    fi
}

deploy_bridge() {
    local build="$INST_DIR/bridge-src" dir="$INST_DIR/bridge"

    step "Compiling rfid-bridge.jar (JDK 17)"
    as_svc bash -c "cd '$build' && bash linux/build-linux.sh" >/dev/null
    [[ -f $build/dist/rfid-bridge.jar ]] || die "build-linux.sh produced no jar"

    install -o "$SVC_USER" -g "$SVC_USER" -m 644 \
        "$build/dist/rfid-bridge.jar" "$dir/rfid-bridge.jar"

    [[ -f $dir/bridge.properties ]] || write_bridge_properties
    install -d -o "$SVC_USER" -g "$SVC_USER" -m 755 "$dir/RfidBridge" "$dir/RfidBridge/logs"

    # When both instances share a reader port the bridges cannot both listen.
    # Deploying staging must never knock production off the reader, so build and
    # configure it but leave it stopped unless it already owns the port.
    local holder
    holder=$(bridge_port_holder)
    if [[ -n $holder && $holder != "$INST" ]]; then
        systemctl stop "eagle-bridge@$INST" 2>/dev/null || true
        systemctl disable --quiet "eagle-bridge@$INST" 2>/dev/null || true
        ok "Bridge for '$INST' built and configured"
        warn "'$holder' currently owns the reader port :$BRIDGE_PORT, so '$INST' was left stopped."
        warn "to hand the reader to '$INST': sudo $SELF bridge-switch $INST"
    else
        step "Restarting eagle-bridge@$INST"
        systemctl enable --quiet --now "eagle-bridge@$INST" 2>/dev/null || true
        systemctl restart "eagle-bridge@$INST"
        sleep 3

        if ss -ltn 2>/dev/null | grep -q ":$BRIDGE_PORT "; then
            ok "Bridge listening for the reader on :$BRIDGE_PORT"
        else
            warn "nothing is listening on :$BRIDGE_PORT — check: $SELF logs $INST bridge"
        fi
    fi

    if ! grep -q '^api\.key=..*' "$dir/bridge.properties"; then
        warn "bridge '$INST' has no API key — the backend will reject its POSTs with 401."
        warn "run: sudo $SELF bridge-key $INST"
    fi

    publish_bridge_ui
}

# Prefers the committed lockfile, but does not let a lockfile that has drifted
# from package.json block a deploy.
bun_install() {
    local dir=$1
    if ! as_svc bash -c "cd '$dir' && bun install --frozen-lockfile"; then
        warn "bun.lock is out of sync with package.json — installing without --frozen-lockfile"
        as_svc bash -c "cd '$dir' && bun install"
    fi
}

wait_for_http() {
    local url=$1 tries=${2:-30} i
    for ((i = 0; i < tries; i++)); do
        curl -fsS --max-time 3 "$url" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# database operations
# ---------------------------------------------------------------------------

cmd_migrate() {
    need_root migrate "$@"
    select_instances "${1:-all}"
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        log "Applying migrations to $DB_NAME"
        as_svc bash -c "cd '$INST_DIR/server' && bunx prisma migrate deploy"
    done
}

cmd_seed() {
    need_root seed "$@"
    local inst=${1:-} kind=${2:-prod}
    [[ -n $inst ]] || die "usage: $SELF seed <prod|staging> [prod|demo]"
    load_instance "$inst"

    local script
    case "$kind" in
        prod) script=seed:prod ;;
        demo) script=seed:demo ;;
        *) die "the seed kind must be 'prod' or 'demo'" ;;
    esac
    # Without this, an undeployed instance fails as bun's opaque
    # 'Script not found "seed:demo"' rather than naming the actual problem.
    [[ -f $INST_DIR/server/package.json ]] \
        || die "'$INST' has no server deployed yet — run: sudo $SELF deploy $INST"

    if [[ $INST == prod && $kind == demo ]]; then
        confirm "Seed DEMO data into the production database ($DB_NAME)?" || die "aborted"
    fi

    log "Seeding $DB_NAME ($kind)"
    as_svc bash -c "cd '$INST_DIR/server' && bun run $script"
}

cmd_backup() {
    need_root backup "$@"
    select_instances "${1:-all}"
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        local file="$INST_DIR/backups/${DB_NAME}-$(date +%Y%m%d-%H%M%S).dump"
        log "Dumping $DB_NAME"
        PGPASSWORD=$(db_password) pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
            -Fc -f "$file" "$DB_NAME"
        chown "$SVC_USER:$SVC_USER" "$file"
        chmod 600 "$file"
        ok "$file ($(du -h "$file" | cut -f1))"
    done
}

cmd_restore() {
    need_root restore "$@"
    local inst=${1:-} file=${2:-}
    [[ -n $inst && -n $file ]] || die "usage: $SELF restore <prod|staging> <dump-file>"
    load_instance "$inst"
    [[ -f $file ]] || die "no such dump: $file"

    confirm "Overwrite everything in $DB_NAME with $(basename "$file")?" || die "aborted"
    log "Stopping eagle-api@$INST while the database is replaced"
    systemctl stop "eagle-api@$INST" || true
    PGPASSWORD=$(db_password) pg_restore -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -d "$DB_NAME" --clean --if-exists --no-owner "$file"
    systemctl start "eagle-api@$INST"
    ok "Restored into $DB_NAME"
}

cmd_psql() {
    local inst=${1:-}
    [[ -n $inst ]] || die "usage: $SELF psql <prod|staging>"
    load_instance "$inst"
    export PGPASSWORD; PGPASSWORD=$(db_password)
    exec psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" "$DB_NAME"
}

# ---------------------------------------------------------------------------
# rfid bridge helpers
# ---------------------------------------------------------------------------

cmd_bridge_key() {
    need_root bridge-key "$@"
    local inst=${1:-}
    [[ -n $inst ]] || die "usage: $SELF bridge-key <prod|staging> [name]"
    load_instance "$inst"
    local name=${2:-rfid-bridge-$INST}

    wait_for_http "http://127.0.0.1:$API_PORT/api/v1/health" 20 \
        || die "the API on :$API_PORT is not answering — start it first"

    log "Minting API key '$name' on the $INST API"
    local body key
    body=$(curl -fsS -X POST "http://127.0.0.1:$API_PORT/api/v1/api-keys" \
        -H 'Content-Type: application/json' -d "{\"name\":\"$name\"}") \
        || die "POST /api/v1/api-keys failed"
    key=$(jq -r '.key // .data.key // empty' <<<"$body")
    [[ -n $key ]] || die "no key in the response: $body"

    local propfile="$INST_DIR/bridge/bridge.properties"
    if grep -q '^api\.key=' "$propfile"; then
        sed -i "s|^api\.key=.*|api.key=$key|" "$propfile"
    else
        echo "api.key=$key" >> "$propfile"
    fi
    ok "Key written to $propfile (prefix $(cut -c1-14 <<<"$key")…)"

    systemctl restart "eagle-bridge@$INST" 2>/dev/null || true
    ok "Bridge restarted with the new key"
}

# The bridge daemon scans upward from 20080 for a free dashboard port, so which
# instance gets which port depends on start order. Read it back from the log
# rather than assuming.
detect_bridge_ui_port() {
    local inst=$1 port
    port=$(journalctl -u "eagle-bridge@$inst" -n 500 --no-pager 2>/dev/null \
        | grep -o 'Dashboard available at http://[^ ]*' | tail -1 \
        | grep -oE ':[0-9]+' | tr -d ':') || true
    if [[ -z ${port:-} ]]; then
        port=$(grep -o 'Dashboard available at http://[^ ]*' \
            "$APP_ROOT/$inst/bridge/RfidBridge/logs/bridge.log" 2>/dev/null \
            | tail -1 | grep -oE ':[0-9]+' | tr -d ':') || true
    fi
    echo "${port:-20080}"
}

# Optional LAN vhost for the bridge dashboard. Written after the service is up,
# because only then is the real dashboard port knowable.
publish_bridge_ui() {
    local link=/etc/nginx/sites-enabled/eagle-bridge-ui-$INST.conf
    local site=/etc/nginx/sites-available/eagle-bridge-ui-$INST.conf

    if [[ ${BRIDGE_UI_EXPOSE,,} != yes ]]; then
        rm -f "$link"
        reload_nginx
        return
    fi

    local upstream; upstream=$(detect_bridge_ui_port "$INST")
    step "Exposing the bridge dashboard on :$BRIDGE_UI_PORT → 127.0.0.1:$upstream"
    cat > "$site" <<EOF
# Generated by $SELF for the '$INST' bridge dashboard.
# WARNING: the dashboard's control API is unauthenticated. Anyone who can reach
# this port can stop the bridge. Only publish it on a trusted VLAN.
server {
    listen $BRIDGE_UI_PORT;
    server_name _;
    location / {
        proxy_pass http://127.0.0.1:$upstream;
        proxy_set_header Host \$host;
    }
}
EOF
    ln -sfn "$site" "$link"
    nginx -t >/dev/null 2>&1 || { nginx -t; die "nginx rejected the bridge UI config"; }
    reload_nginx
}

cmd_camera() {
    local sub=${1:-streams}
    camera_available || die "the camera stack is not enabled or docker is missing"
    case "$sub" in
        streams)
            head1 "go2rtc streams on 127.0.0.1:$GO2RTC_API_PORT"
            camera_stream_report
            printf '\n  %sWebRTC candidate handed to browsers: %s%s\n\n' "$C_DIM" \
                "$(sed -n 's/^    - //p' "$CAMERA_DIR/camera-access/go2rtc.yaml" 2>/dev/null | tail -1)" \
                "$C_RESET"
            ;;
        ps|status) compose ps ;;
        start)     need_root camera start; camera_action start; ok "camera stack started" ;;
        stop)      need_root camera stop; camera_action stop; ok "camera stack stopped" ;;
        restart)   need_root camera restart; camera_action restart; ok "camera stack restarted" ;;
        logs)      shift; compose logs --tail=200 "$@" ;;
        *)         die "usage: $SELF camera <streams|ps|status|start|stop|restart|logs>" ;;
    esac
}

cmd_bridge_ui() {
    select_instances "${1:-all}"
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        local port; port=$(detect_bridge_ui_port "$inst")
        head1 "$INST bridge dashboard"
        printf '  on the server : http://127.0.0.1:%s/\n' "$port"
        printf '  from your PC  : ssh -L %s:localhost:%s %s@%s\n' \
            "$port" "$port" "${SUDO_USER:-$USER}" "$(lan_ip)"
        printf '                  then open http://localhost:%s/\n' "$port"
        if [[ ${BRIDGE_UI_EXPOSE,,} == yes ]]; then
            printf '  on the LAN    : http://%s:%s/ %s(unauthenticated)%s\n' \
                "$(lan_ip)" "$BRIDGE_UI_PORT" "$C_YELLOW" "$C_RESET"
        fi
    done
    echo
}

# ---------------------------------------------------------------------------
# service control and reporting
# ---------------------------------------------------------------------------

unit_for() {
    case "$1" in
        server) echo "eagle-api@$2" ;;
        bridge) echo "eagle-bridge@$2" ;;
        client) echo "" ;;   # served by the shared nginx
    esac
}

# The camera stack is containers rather than a systemd unit, so start/stop/
# restart go through compose. 'start' is 'up -d' so it also works the first time,
# before the containers have been created.
camera_action() {
    case "$1" in
        start)   compose up -d ;;
        stop)    compose stop ;;
        restart) compose restart ;;
    esac
}

svc_action() {
    local action=$1
    need_root "$action" "${@:2}"
    select_instances "${2:-all}"
    select_components "${3:-all}"

    local hcomp
    for hcomp in ${SELECTED_HOST_COMPONENTS[@]+"${SELECTED_HOST_COMPONENTS[@]}"}; do
        if [[ ! -f $CAMERA_DIR/docker-compose.yml ]]; then
            step "camera stack is not deployed — skipping"
            continue
        fi
        step "docker compose $action ($hcomp)"
        camera_action "$action"
    done

    local inst comp unit
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        for comp in ${SELECTED_COMPONENTS[@]+"${SELECTED_COMPONENTS[@]}"}; do
            unit=$(unit_for "$comp" "$inst")
            if [[ -z $unit ]]; then
                step "client is served by nginx — ${action}ing nginx instead"
                [[ $action == stop ]] || reload_nginx
                continue
            fi
            step "systemctl $action $unit"
            systemctl "$action" "$unit"
        done
    done
    ok "done"
}

cmd_status() {
    select_instances "${1:-all}"
    local ip; ip=$(lan_ip)
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        head1 "$INST"
        printf '  %-8s %s\n' database "$DB_NAME @ $DB_HOST:$DB_PORT — $(db_state)"
        printf '  %-8s %s\n' api      "$(unit_state "eagle-api@$inst")  http://$ip:$API_PORT/api/v1"
        printf '  %-8s %s\n' client   "$(nginx_state)  http://$ip:$WEB_PORT/"
        printf '  %-8s %s\n' bridge   "$(unit_state "eagle-bridge@$inst")  reader → $ip:$BRIDGE_PORT $(bridge_owner_note "$inst")"
    done

    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        head1 "camera (shared)"
        printf '  %-8s %s\n' go2rtc "$(container_state eagle-cement-go2rtc)  http://$ip:$GO2RTC_API_PORT/  webrtc $ip:$GO2RTC_WEBRTC_PORT"
    fi
    echo
}

# Whether this instance's API is the one recording plates. Read from the .env
# the script generated, not from the config, so it reflects what is deployed.
anpr_worker_note() {
    local envfile="$INST_DIR/server/.env" v=
    [[ -r $envfile ]] && v=$(sed -n 's/^ANPR_CONTINUOUS_ENABLED=//p' "$envfile" | head -1)
    case "$v" in
        true)  printf '%s%-8s%s %-9s' "$C_GREEN" recording "$C_RESET" '(worker)' ;;
        false) printf '%s%-8s%s %-9s' "$C_DIM" off "$C_RESET" '(worker)' ;;
        *)     printf '%s%-8s%s %-9s' "$C_YELLOW" unknown "$C_RESET" '(worker)' ;;
    esac
}

container_state() {
    local st
    st=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) || st=missing
    case "$st" in
        running) printf '%s%-8s%s %-9s' "$C_GREEN" running "$C_RESET" '(docker)' ;;
        *)       printf '%s%-8s%s %-9s' "$C_RED" "$st" "$C_RESET" '(docker)' ;;
    esac
}

# Both bridges want the one reader port, so 'not listening' is the normal
# resting state for whichever instance does not hold it — say so, rather than
# showing what looks like a fault.
bridge_owner_note() {
    local inst=$1 holder
    holder=$(bridge_port_holder)
    if [[ $holder == "$inst" ]]; then
        printf '%s(owns the reader)%s' "$C_GREEN" "$C_RESET"
    elif [[ -n $holder ]]; then
        printf '%s(idle — %s owns the reader)%s' "$C_DIM" "$holder" "$C_RESET"
    else
        printf '%s(no bridge is holding the reader)%s' "$C_YELLOW" "$C_RESET"
    fi
}

unit_state() {
    local active enabled
    active=$(systemctl is-active "$1" 2>/dev/null) || true
    enabled=$(systemctl is-enabled "$1" 2>/dev/null) || enabled=disabled
    case "$active" in
        active) printf '%s%-8s%s %-9s' "$C_GREEN" active "$C_RESET" "($enabled)" ;;
        *)      printf '%s%-8s%s %-9s' "$C_RED" "${active:-missing}" "$C_RESET" "($enabled)" ;;
    esac
}

nginx_state() {
    if systemctl is-active --quiet nginx
    then printf '%s%-8s%s %-9s' "$C_GREEN" active "$C_RESET" '(nginx)'
    else printf '%s%-8s%s %-9s' "$C_RED" inactive "$C_RESET" '(nginx)'; fi
}

port_state() {
    if ss -ltn 2>/dev/null | grep -q ":$1 "
    then printf '%s(listening)%s' "$C_GREEN" "$C_RESET"
    else printf '%s(not listening)%s' "$C_RED" "$C_RESET"; fi
}

db_state() {
    local pass
    if ! pass=$(db_password); then
        printf '%sunknown (run with sudo)%s' "$C_YELLOW" "$C_RESET"
        return
    fi
    if PGPASSWORD=$pass psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1
    then printf '%sreachable%s' "$C_GREEN" "$C_RESET"
    else printf '%sunreachable%s' "$C_RED" "$C_RESET"; fi
}

cmd_health() {
    select_instances "${1:-all}"
    local inst rc=0
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        head1 "$INST"
        check "api    /api/v1/health on :$API_PORT" \
            curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$API_PORT/api/v1/health" || rc=1
        check "client index.html on :$WEB_PORT" \
            curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$WEB_PORT/" || rc=1
        check "db     $DB_NAME" db_probe || rc=1

        # Only one bridge can hold the reader port, so a closed port on the idle
        # instance is expected, not a failure.
        if [[ $(bridge_port_holder) != "$inst" ]]; then
            printf '  %s·%s bridge reader port :%s — idle (%s owns the reader)\n' \
                "$C_DIM" "$C_RESET" "$BRIDGE_PORT" "$(bridge_port_holder || echo none)"
        else
            check "bridge reader port :$BRIDGE_PORT" port_probe "$BRIDGE_PORT" || rc=1
        fi
    done

    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        head1 "camera (shared)"
        check "go2rtc /api/streams on :$GO2RTC_API_PORT" \
            curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:$GO2RTC_API_PORT/api/streams" || rc=1
    fi
    echo
    return $rc
}

db_probe() {
    local pass
    pass=$(db_password) || return 1
    PGPASSWORD=$pass psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" \
        -d "$DB_NAME" -tAc 'select 1' >/dev/null 2>&1
}

port_probe() { ss -ltn 2>/dev/null | grep -q ":$1 "; }

check() {
    local label=$1; shift
    if "$@" >/dev/null 2>&1; then
        printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$label"
    else
        printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$label"
        return 1
    fi
}

cmd_logs() {
    local inst=${1:-} comp=${2:-server}
    [[ -n $inst ]] || die "usage: $SELF logs <prod|staging> <server|bridge|nginx> [-f]"

    # The camera stack has no instance, so it is addressed directly:
    #   logs camera [go2rtc] [-f]
    if [[ $inst == camera ]]; then
        shift
        local svc=()
        [[ ${1:-} == go2rtc ]] && { svc=("$1"); shift; }
        [[ -f $CAMERA_DIR/docker-compose.yml ]] \
            || die "the camera stack is not deployed — run: sudo $SELF deploy all camera"
        cd "$CAMERA_DIR" || die "cannot enter $CAMERA_DIR"
        exec docker compose -p "$COMPOSE_PROJECT" logs --tail 200 \
            "$@" ${svc[@]+"${svc[@]}"}
    fi

    load_instance "$inst"
    shift 2 2>/dev/null || shift $#
    case "$comp" in
        server) exec journalctl -u "eagle-api@$inst" -n 200 "$@" ;;
        bridge) exec journalctl -u "eagle-bridge@$inst" -n 200 "$@" ;;
        nginx)  exec tail -n 200 "$@" "/var/log/nginx/eagle-cement-$inst.error.log" ;;
        *) die "the log target must be: server | bridge | nginx" ;;
    esac
}

cmd_urls() {
    select_instances "${1:-all}"
    local ip; ip=$(lan_ip)
    head1 "Reach the stack from anywhere on the LAN — this box is $ip"
    local inst
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        printf '  %s%-8s%s web %-26s api %-32s reader %s:%s\n' \
            "$C_BOLD" "$INST" "$C_RESET" \
            "http://$ip:$WEB_PORT/" "http://$ip:$API_PORT/api/v1" "$ip" "$BRIDGE_PORT"
    done
    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        printf '  %s%-8s%s go2rtc %s\n' \
            "$C_BOLD" camera "$C_RESET" \
            "http://$ip:$GO2RTC_API_PORT/"
        printf '  %s         webrtc %s:%s (tcp+udp)   rtsp rtsp://%s:%s/<stream>%s\n' \
            "$C_DIM" "$ip" "$GO2RTC_WEBRTC_PORT" "$ip" "$GO2RTC_RTSP_PORT" "$C_RESET"
        printf '  %s         go2rtc'"'"'s API is unauthenticated — keep it inside LAN_CIDR.%s\n' \
            "$C_DIM" "$C_RESET"
    fi
    local holder; holder=$(bridge_port_holder)
    printf '\n  %sOn each reader set Destination IP to %s and Destination Port to %s.%s\n' \
        "$C_DIM" "$ip" "$BRIDGE_PORT" "$C_RESET"
    printf '  %sOne reader port for both instances, so one bridge runs at a time — currently %s.%s\n' \
        "$C_DIM" "${holder:-nobody}" "$C_RESET"
    printf '  %sHand it over with: sudo %s bridge-switch <instance>%s\n\n' \
        "$C_DIM" "$SELF" "$C_RESET"
}

# ---------------------------------------------------------------------------
# firewall
# ---------------------------------------------------------------------------

cmd_firewall() {
    need_root firewall
    command -v ufw >/dev/null 2>&1 || die "ufw is not installed (apt install ufw)"
    local cidr; cidr=$(lan_cidr)
    log "Opening the LAN ports for $cidr"
    local inst p seen=()
    for inst in "${INSTANCES[@]}"; do
        load_instance "$inst"
        for p in "$WEB_PORT" "$API_PORT" "$BRIDGE_PORT"; do
            # BRIDGE_PORT is the same for both instances — one rule covers it.
            [[ " ${seen[*]} " == *" $p "* ]] && continue
            seen+=("$p")
            step "allow $cidr → tcp/$p ($INST)"
            ufw allow from "$cidr" to any port "$p" proto tcp >/dev/null
        done
        if [[ ${BRIDGE_UI_EXPOSE,,} == yes ]]; then
            step "allow $cidr → tcp/$BRIDGE_UI_PORT ($INST bridge dashboard)"
            ufw allow from "$cidr" to any port "$BRIDGE_UI_PORT" proto tcp >/dev/null
        fi
    done

    if [[ ${CAMERA_ENABLED,,} == yes ]]; then
        # The camera stack publishes every port on 0.0.0.0, so these rules are
        # what confines it to the plant LAN. go2rtc's control API is
        # unauthenticated — keep $cidr as tight as the site allows.
        for p in "$GO2RTC_API_PORT" "$GO2RTC_RTSP_PORT" "$GO2RTC_WEBRTC_PORT"; do
            step "allow $cidr → tcp/$p (camera stack)"
            ufw allow from "$cidr" to any port "$p" proto tcp >/dev/null
        done
        # WebRTC media negotiates over either transport, so udp as well.
        step "allow $cidr → udp/$GO2RTC_WEBRTC_PORT (camera WebRTC)"
        ufw allow from "$cidr" to any port "$GO2RTC_WEBRTC_PORT" proto udp >/dev/null
    fi
    ok "Rules added. Turn the firewall on with: sudo ufw enable"
}

# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

cmd_destroy() {
    need_root destroy "$@"
    [[ -n ${1:-} ]] || die "usage: $SELF destroy <prod|staging|all>"
    select_instances "$1"

    # Spell out everything that is about to go, then confirm once for the whole
    # set — asking per instance invites saying yes on autopilot.
    local inst
    warn "This permanently removes:"
    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        warn "  '$INST' — services, $INST_DIR (uploads included), database $DB_NAME"
    done
    confirm "Destroy: ${SELECTED_INSTANCES[*]}?" || die "aborted"
    confirm "Confirm again: the database and every uploaded photo will be gone." || die "aborted"

    for inst in "${SELECTED_INSTANCES[@]}"; do
        load_instance "$inst"
        step "Destroying '$INST'"
        systemctl disable --now "eagle-api@$INST" 2>/dev/null || true
        systemctl disable --now "eagle-bridge@$INST" 2>/dev/null || true
        rm -f "/etc/nginx/sites-enabled/eagle-cement-$INST.conf" \
              "/etc/nginx/sites-available/eagle-cement-$INST.conf" \
              "/etc/nginx/sites-enabled/eagle-bridge-ui-$INST.conf" \
              "/etc/nginx/sites-available/eagle-bridge-ui-$INST.conf"
        psql_admin "DROP DATABASE IF EXISTS $DB_NAME" >/dev/null
        rm -rf "$INST_DIR" "$APP_ROOT/checkout/$INST"
        ok "'$INST' destroyed."
    done
    reload_nginx

    # What is left is host-level and shared, so removing it is a separate,
    # deliberate step — see 'purge-host' in INSTALL.md §12. The camera stack in
    # particular is shared, so destroying one instance must not take it down.
    warn "The systemd units, the camera stack, the '$SVC_USER' user/role and $APP_ROOT still exist."
    warn "To remove those too: sudo $SELF purge-host"
}

# Removes what 'destroy' deliberately leaves behind: the host-level pieces
# shared by both instances. Refuses to run while an instance is still installed.
cmd_purge_host() {
    need_root purge-host "$@"

    local inst remaining=()
    for inst in "${INSTANCES[@]}"; do
        [[ -d $APP_ROOT/$inst ]] && remaining+=("$inst")
    done
    if (( ${#remaining[@]} )); then
        die "still installed: ${remaining[*]} — run '$SELF destroy all' first"
    fi

    warn "This removes the systemd units, the camera stack (containers and config),"
    warn "the '$SVC_USER' user and PostgreSQL role, $APP_ROOT (including the saved"
    warn "database password), the eaglectl symlink and the ufw rules."
    warn "Config at /etc/eagle-cement is left alone."
    confirm "Purge the host-level install?" || die "aborted"

    if [[ -f $CAMERA_DIR/docker-compose.yml ]] && command -v docker >/dev/null 2>&1; then
        step "Removing the camera stack (containers and network)"
        compose down --volumes --remove-orphans >/dev/null 2>&1 || true
    fi

    step "Removing systemd units"
    rm -f /etc/systemd/system/eagle-api@.service \
          /etc/systemd/system/eagle-bridge@.service
    systemctl daemon-reload

    step "Dropping the PostgreSQL role '$DB_USER'"
    psql_admin "DROP ROLE IF EXISTS $DB_USER" >/dev/null 2>&1 \
        || warn "could not drop role '$DB_USER' — it may still own objects"

    step "Removing the ufw rules for $(lan_cidr)"
    local cidr port
    cidr=$(lan_cidr)
    if command -v ufw >/dev/null 2>&1; then
        for inst in "${INSTANCES[@]}"; do
            load_instance "$inst"
            # Mirrors cmd_firewall, bridge dashboard included — deleting a rule
            # that was never added is a harmless no-op.
            for port in "$WEB_PORT" "$API_PORT" "$BRIDGE_PORT" "$BRIDGE_UI_PORT"; do
                ufw --force delete allow from "$cidr" to any port "$port" proto tcp \
                    >/dev/null 2>&1 || true
            done
        done
        for port in "$GO2RTC_API_PORT" "$GO2RTC_RTSP_PORT" "$GO2RTC_WEBRTC_PORT"; do
            ufw --force delete allow from "$cidr" to any port "$port" proto tcp \
                >/dev/null 2>&1 || true
        done
        ufw --force delete allow from "$cidr" to any port "$GO2RTC_WEBRTC_PORT" proto udp \
            >/dev/null 2>&1 || true
    fi

    step "Removing $APP_ROOT and the eaglectl symlink"
    rm -rf "$APP_ROOT"
    rm -f /usr/local/bin/eaglectl

    step "Removing the service user '$SVC_USER'"
    id "$SVC_USER" >/dev/null 2>&1 && userdel "$SVC_USER" 2>/dev/null || true

    ok "Host purged. PostgreSQL, nginx, Node, bun, the JDK and Docker were left installed."
}

# ---------------------------------------------------------------------------
# help and dispatch
# ---------------------------------------------------------------------------

cmd_help() {
    cat <<EOF
${C_BOLD}eagle-cement.sh $VERSION${C_RESET} — two-instance deployment for the Eagle Cement RFID stack

  ${C_BOLD}usage${C_RESET}   sudo $SELF <command> [instance] [component]

  instance    prod | staging | all          (default: all)
  component   server | client | bridge | camera | all (default: all)

              'camera' is the shared go2rtc container stack. There is one
              set of gate cameras, so it is deployed once for the host and both
              instances point at it — it is not per-instance.

${C_BOLD}setup${C_RESET}
  bootstrap                   install packages, Docker, service user and systemd units (run once)
  init [instance]             create the database, write .env, bridge.properties, nginx and camera config
  deploy [instance] [comp]    sync source, build, migrate, restart
  firewall                    open the LAN ports in ufw for \$LAN_CIDR

${C_BOLD}day to day${C_RESET}
  status [instance]           what is running, and where
  health [instance]           probe the API, web, database, reader port and cameras
  urls [instance]             LAN URLs, and the port each reader should dial
  logs <instance> <server|bridge|nginx> [-f]
  logs camera [go2rtc] [-f]
  start | stop | restart [instance] [comp]

${C_BOLD}database${C_RESET}
  migrate [instance]          prisma migrate deploy
  seed <instance> [prod|demo] load the production or demo dataset
  backup [instance]           pg_dump -Fc into <instance>/backups
  restore <instance> <file>   restore a dump over that instance's database
  psql <instance>             open a shell on that instance's database

${C_BOLD}rfid bridge${C_RESET}
  bridge-key <instance>       mint an API key and load it into bridge.properties
  bridge-ui [instance]        show the dashboard URL and the SSH tunnel command
  bridge-switch <instance>    hand the shared reader port to that instance

${C_BOLD}cameras${C_RESET}
  camera streams              list the go2rtc streams and whether each is producing frames
  camera ps                   docker compose ps for the camera stack
                              (go2rtc :$GO2RTC_API_PORT is open on the LAN)

${C_BOLD}teardown${C_RESET}
  destroy <prod|staging|all>  remove instances: services, files, uploads and database
  purge-host                  after 'destroy all': systemd units, $SVC_USER user/role, $APP_ROOT

${C_BOLD}first run${C_RESET}
  sudo $SELF bootstrap
  sudo $SELF init all
  sudo $SELF deploy all
  sudo $SELF seed prod prod
  sudo $SELF bridge-key prod && sudo $SELF bridge-key staging
  sudo $SELF status

Config: $HERE/eagle-cement.conf, then /etc/eagle-cement/deploy.conf
EOF
}

main() {
    local cmd=${1:-help}
    shift 2>/dev/null || true
    case "$cmd" in
        bootstrap)      cmd_bootstrap "$@" ;;
        init)           cmd_init "$@" ;;
        deploy)         cmd_deploy "$@" ;;
        migrate)        cmd_migrate "$@" ;;
        seed)           cmd_seed "$@" ;;
        backup)         cmd_backup "$@" ;;
        restore)        cmd_restore "$@" ;;
        psql)           cmd_psql "$@" ;;
        bridge-key)     cmd_bridge_key "$@" ;;
        bridge-ui)      cmd_bridge_ui "$@" ;;
        bridge-switch)  cmd_bridge_switch "$@" ;;
        camera)         cmd_camera "$@" ;;
        firewall)       cmd_firewall "$@" ;;
        status)         cmd_status "$@" ;;
        health)         cmd_health "$@" ;;
        urls)           cmd_urls "$@" ;;
        logs)           cmd_logs "$@" ;;
        start)          svc_action start "$@" ;;
        stop)           svc_action stop "$@" ;;
        restart)        svc_action restart "$@" ;;
        destroy)        cmd_destroy "$@" ;;
        purge-host)     cmd_purge_host "$@" ;;
        version)        echo "$VERSION" ;;
        help|-h|--help) cmd_help ;;
        *) die "unknown command '$cmd' — run '$SELF help'" ;;
    esac
}

main "$@"
