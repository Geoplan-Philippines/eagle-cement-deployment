#!/usr/bin/env bash
#
# eagle-cement-uninstall.sh — remove the entire Eagle Cement stack in one command.
#
# Deliberately standalone. This is the script you reach for when the install is
# half-broken, so it never calls eagle-cement.sh and never assumes a service,
# database, file or user still exists. Every step is idempotent: run it twice
# and the second run is a no-op.
#
# It removes, for both instances:
#   · the eagle-api@ and eagle-bridge@ services, and their systemd unit templates
#   · the nginx vhosts (web and bridge dashboard)
#   · the eagle_cement_prod / eagle_cement_staging databases
#   · the 'eagle' PostgreSQL role and the 'eagle' system user
#   · /opt/eagle-cement — application files, uploads, local backups, build caches
#   · the ufw rules it opened, and /usr/local/bin/eaglectl
#
# and, for the shared camera stack:
#   · the eagle-cement-camera compose project: the go2rtc and ANPR containers,
#     the eagle-cement-anpr image, the ONNX model cache volume and every saved
#     plate snapshot
#
# It leaves alone, on purpose:
#   · PostgreSQL, nginx, Node.js, bun, the JDK and Docker — shared system packages
#   · /etc/eagle-cement/deploy.conf — holds your API keys; use --purge-config
#   · your source repositories
#
# Usage: sudo ./eagle-cement-uninstall.sh [--yes] [--purge-config] [--dry-run]
#
set -euo pipefail
umask 022

SELF="$(basename "${BASH_SOURCE[0]}")"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# defaults — kept in step with eagle-cement.sh, overridable by the same conf
# ---------------------------------------------------------------------------

APP_ROOT=/opt/eagle-cement
SVC_USER=eagle
DB_USER=eagle
DB_NAME_PROD=eagle_cement_prod
DB_NAME_STAGING=eagle_cement_staging
WEB_PORT_PROD=4200
WEB_PORT_STAGING=4201
API_PORT_PROD=8000
API_PORT_STAGING=8001
BRIDGE_PORT=20059
BRIDGE_UI_PORT_PROD=20090
BRIDGE_UI_PORT_STAGING=20091
GO2RTC_WEBRTC_PORT=8555
LAN_CIDR=

# Overridable so the removal path can be exercised against a scratch tree
# instead of the real /etc/nginx.
NGINX_DIR=${NGINX_DIR:-/etc/nginx}
SYSTEMD_DIR=${SYSTEMD_DIR:-/etc/systemd/system}

for _f in "$HERE/eagle-cement.conf" /etc/eagle-cement/deploy.conf; do
    if [[ -f $_f && -r $_f ]]; then
        # shellcheck disable=SC1090
        source "$_f"
    fi
done

INSTANCES=(prod staging)
CAMERA_DIR="$APP_ROOT/camera"
COMPOSE_PROJECT=eagle-cement-camera

ASSUME_YES=0
PURGE_CONFIG=0
DRY_RUN=0

while (( $# )); do
    case "$1" in
        --yes|-y)       ASSUME_YES=1 ;;
        --purge-config) PURGE_CONFIG=1 ;;
        --dry-run|-n)   DRY_RUN=1 ;;
        -h|--help)
            sed -n '3,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 1 ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# output
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'
else
    C_RESET=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=; C_BOLD=
fi

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
step() { printf '%s  ·%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
ok()   { printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s  !%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s  ✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

# Every mutating call goes through this. In --dry-run it is only printed.
#
# It never propagates a failure. An uninstaller that stops at the first problem
# is worse than useless: it leaves the box in a half-removed state that is
# harder to reason about than what it started with. Failures are counted and
# reported together at the end, and the run continues.
FAILURES=()
run() {
    if (( DRY_RUN )); then
        printf '%s      would run:%s %s\n' "$C_DIM" "$C_RESET" "$*"
        return 0
    fi
    if ! "$@" 2>/dev/null; then
        FAILURES+=("$*")
        printf '%s      failed:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
    fi
    return 0
}

[[ $EUID -eq 0 ]] || die "this needs root. Re-run with: sudo ./$SELF $*"

instance_db() {
    case "$1" in
        prod)    echo "$DB_NAME_PROD" ;;
        staging) echo "$DB_NAME_STAGING" ;;
    esac
}

# ---------------------------------------------------------------------------
# survey — show what is actually here before asking to remove it
# ---------------------------------------------------------------------------

log "Surveying the Eagle Cement install on $(hostname)"

FOUND=0
note_found() { FOUND=1; printf '%s      found:%s %s\n' "$C_DIM" "$C_RESET" "$*"; }

for inst in "${INSTANCES[@]}"; do
    for unit in "eagle-api@$inst" "eagle-bridge@$inst"; do
        systemctl list-unit-files "$unit.service" >/dev/null 2>&1 \
            && systemctl is-enabled --quiet "$unit" 2>/dev/null \
            && note_found "service $unit (enabled)"
    done
    [[ -d $APP_ROOT/$inst ]] && note_found "directory $APP_ROOT/$inst"
done

if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
    for inst in "${INSTANCES[@]}"; do
        db=$(instance_db "$inst")
        [[ $(runuser -u postgres -- psql -tAc \
                "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null) == 1 ]] \
            && note_found "database $db"
    done
    [[ $(runuser -u postgres -- psql -tAc \
            "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null) == 1 ]] \
        && note_found "PostgreSQL role $DB_USER"
else
    warn "PostgreSQL is not running — databases and roles cannot be removed."
    warn "Start it and re-run if you need them gone: systemctl start postgresql"
fi

if command -v docker >/dev/null 2>&1; then
    for c in eagle-cement-go2rtc eagle-cement-anpr; do
        docker inspect "$c" >/dev/null 2>&1 && note_found "container $c"
    done
    [[ -d $CAMERA_DIR ]] && note_found "camera stack in $CAMERA_DIR (plate snapshots included)"
fi

id "$SVC_USER" >/dev/null 2>&1 && note_found "system user $SVC_USER"
[[ -e $SYSTEMD_DIR/eagle-api@.service ]] && note_found "systemd unit templates"
[[ -e /usr/local/bin/eaglectl ]] && note_found "/usr/local/bin/eaglectl"
compgen -G "$NGINX_DIR/sites-available/eagle-*" >/dev/null && note_found "nginx vhosts"

if (( ! FOUND )); then
    ok "Nothing to remove — the stack is not installed here."
    exit 0
fi

# ---------------------------------------------------------------------------
# confirm
# ---------------------------------------------------------------------------

printf '\n'
warn "This permanently deletes the databases, every uploaded photo, and all"
warn "local backups under $APP_ROOT. It cannot be undone."
(( PURGE_CONFIG )) && warn "--purge-config: /etc/eagle-cement will go too (contains your API keys)."

if (( DRY_RUN )); then
    printf '\n'
    log "Dry run — nothing will be changed."
elif (( ! ASSUME_YES )); then
    printf '\n%sType DELETE to confirm:%s ' "$C_BOLD" "$C_RESET"
    read -r answer </dev/tty || answer=
    [[ $answer == DELETE ]] || die "aborted — nothing was changed"
fi

printf '\n'

# ---------------------------------------------------------------------------
# 1. services and containers
# ---------------------------------------------------------------------------

log "Stopping services"
for inst in "${INSTANCES[@]}"; do
    for unit in "eagle-api@$inst" "eagle-bridge@$inst"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null \
           || systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            step "disabling $unit"
            run systemctl disable --now "$unit"
        fi
    done
done

# The camera stack. 'compose down' needs the generated compose file, which is
# under APP_ROOT and therefore about to be deleted — so it has to happen here,
# before section 5 removes the tree. If the file is already gone (a half-removed
# install, which is exactly when this script gets used), fall back to removing
# the containers by name so nothing is left running against a deleted config.
if command -v docker >/dev/null 2>&1; then
    log "Removing the camera stack"
    if [[ -f $CAMERA_DIR/docker-compose.yml ]]; then
        step "docker compose down (containers, network and model cache)"
        run bash -c "cd '$CAMERA_DIR' && docker compose -p '$COMPOSE_PROJECT' down --volumes --remove-orphans"
    else
        for c in eagle-cement-go2rtc eagle-cement-anpr; do
            if docker inspect "$c" >/dev/null 2>&1; then
                step "removing container $c"
                run docker rm -f "$c"
            fi
        done
        run docker volume rm -f "${COMPOSE_PROJECT}_anpr-model-cache"
    fi
    if docker image inspect eagle-cement-anpr:latest >/dev/null 2>&1; then
        step "removing image eagle-cement-anpr:latest"
        run docker image rm -f eagle-cement-anpr:latest
    fi
fi

# ---------------------------------------------------------------------------
# 2. nginx
# ---------------------------------------------------------------------------

log "Removing nginx configuration"
shopt -s nullglob
for site in "$NGINX_DIR"/sites-enabled/eagle-* "$NGINX_DIR"/sites-available/eagle-*; do
    step "removing $(basename "$site")"
    run rm -f "$site"
done
shopt -u nullglob

if systemctl is-active --quiet nginx 2>/dev/null; then
    # If our vhosts were the only reason nginx was running, a reload is still
    # correct — nginx keeps serving whatever else is configured. run() never
    # returns non-zero, so the reload/restart fallback is sequenced by hand;
    # only failing at both is worth reporting.
    if (( DRY_RUN )); then
        printf '%s      would run:%s systemctl reload nginx\n' "$C_DIM" "$C_RESET"
    elif ! systemctl reload nginx 2>/dev/null && ! systemctl restart nginx 2>/dev/null; then
        FAILURES+=("systemctl reload/restart nginx")
        warn "nginx would not reload — check: nginx -t"
    fi
fi

# ---------------------------------------------------------------------------
# 3. databases and role
# ---------------------------------------------------------------------------

if command -v psql >/dev/null 2>&1 && systemctl is-active --quiet postgresql 2>/dev/null; then
    log "Dropping databases"
    for inst in "${INSTANCES[@]}"; do
        db=$(instance_db "$inst")
        if [[ $(runuser -u postgres -- psql -tAc \
                "SELECT 1 FROM pg_database WHERE datname='$db'" 2>/dev/null) == 1 ]]; then
            step "dropping $db"
            # A lingering API connection makes DROP DATABASE fail; close them first.
            run runuser -u postgres -- psql -tAc \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
                 WHERE datname='$db' AND pid <> pg_backend_pid()" >/dev/null 2>&1 || true
            run runuser -u postgres -- psql -tAc \
                "DROP DATABASE IF EXISTS $db" >/dev/null 2>&1 \
                || warn "could not drop $db"
        fi
    done

    if [[ $(runuser -u postgres -- psql -tAc \
            "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" 2>/dev/null) == 1 ]]; then
        step "dropping role $DB_USER"
        run runuser -u postgres -- psql -tAc \
            "DROP ROLE IF EXISTS $DB_USER" >/dev/null 2>&1 \
            || warn "could not drop role '$DB_USER' — it may still own objects elsewhere"
    fi
fi

# ---------------------------------------------------------------------------
# 4. firewall
# ---------------------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
    log "Removing the ufw rules"
    cidr=$LAN_CIDR
    if [[ -z $cidr ]]; then
        ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        iface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}')
        cidr=$(ip -4 -o route show scope link dev "$iface" 2>/dev/null \
            | awk '$1 ~ /\// {print $1; exit}')
        cidr=${cidr:-${ip:-127.0.0.1}/32}
    fi
    step "for $cidr"
    for port in "$WEB_PORT_PROD" "$API_PORT_PROD" "$BRIDGE_UI_PORT_PROD" \
                "$WEB_PORT_STAGING" "$API_PORT_STAGING" "$BRIDGE_UI_PORT_STAGING" \
                "$BRIDGE_PORT" "$GO2RTC_WEBRTC_PORT"; do
        run ufw --force delete allow from "$cidr" to any port "$port" proto tcp \
            >/dev/null 2>&1 || true
    done
    # WebRTC media negotiates over either transport, so 'firewall' opened both.
    run ufw --force delete allow from "$cidr" to any port "$GO2RTC_WEBRTC_PORT" proto udp \
        >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# 5. systemd units, files, user
# ---------------------------------------------------------------------------

log "Removing systemd unit templates"
run rm -f "$SYSTEMD_DIR/eagle-api@.service" \
          "$SYSTEMD_DIR/eagle-bridge@.service"
run systemctl daemon-reload
# Cosmetic tidy-up of any lingering failed units; nothing depends on it, and it
# is not worth reporting as an incomplete step.
(( DRY_RUN )) || systemctl reset-failed 2>/dev/null || true

log "Removing files"
step "$APP_ROOT"
run rm -rf "$APP_ROOT"
step "/usr/local/bin/eaglectl"
run rm -f /usr/local/bin/eaglectl

if (( PURGE_CONFIG )); then
    step "/etc/eagle-cement"
    run rm -rf /etc/eagle-cement
fi

if id "$SVC_USER" >/dev/null 2>&1; then
    log "Removing the service user '$SVC_USER'"
    # pkill exits 1 when nothing matched, which is the normal case here — the
    # services were stopped above. Only a real error (>1) is worth reporting,
    # so this deliberately does not go through run().
    if (( ! DRY_RUN )); then
        rc=0; pkill -u "$SVC_USER" 2>/dev/null || rc=$?
        if (( rc > 1 )); then
            FAILURES+=("pkill -u $SVC_USER (exit $rc)")
        elif (( rc == 0 )); then
            sleep 1   # give the killed processes a moment to exit
        fi
    else
        printf '%s      would run:%s pkill -u %s\n' "$C_DIM" "$C_RESET" "$SVC_USER"
    fi
    # run() reports its own failures; a leftover user almost always means a
    # process is still alive as it.
    run userdel "$SVC_USER"
fi

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

printf '\n'
if (( DRY_RUN )); then
    ok "Dry run complete — nothing was changed."
    exit 0
fi

log "Verifying"
LEFT=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        printf '%s  ✗%s still present: %s\n' "$C_RED" "$C_RESET" "$1"; LEFT=1
    else
        printf '%s  ✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"
    fi
}
check "no $APP_ROOT"            "[[ -e $APP_ROOT ]]"
check "no systemd units"        "[[ -e $SYSTEMD_DIR/eagle-api@.service ]]"
check "no eaglectl symlink"     "[[ -e /usr/local/bin/eaglectl ]]"
check "no nginx vhosts"         "compgen -G '$NGINX_DIR/sites-available/eagle-*'"
check "no '$SVC_USER' user"     "id $SVC_USER"
# Checked separately: 'docker inspect a b' also fails when only one is missing,
# which would report a surviving container as gone.
command -v docker >/dev/null 2>&1 \
    && check "no camera containers" \
       "docker inspect eagle-cement-go2rtc || docker inspect eagle-cement-anpr"

printf '\n'
if (( ${#FAILURES[@]} )); then
    warn "${#FAILURES[@]} step(s) could not be completed:"
    for f in "${FAILURES[@]}"; do warn "    $f"; done
fi
if (( LEFT || ${#FAILURES[@]} )); then
    warn "Removal was incomplete — re-run to retry, it is safe to repeat."
else
    ok "Eagle Cement removed."
fi
printf '%s      PostgreSQL, nginx, Node, bun, the JDK and Docker were left installed.%s\n' \
    "$C_DIM" "$C_RESET"
(( PURGE_CONFIG )) || [[ ! -e /etc/eagle-cement ]] \
    || printf '%s      /etc/eagle-cement kept (holds API keys) — remove with --purge-config.%s\n' \
        "$C_DIM" "$C_RESET"
