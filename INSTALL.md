# Eagle Cement — on-premise installation

This directory deploys the whole RFID stack onto one Ubuntu server as **two
independent instances**, production and staging. Each instance is a full
vertical slice: its own database, its own API process, its own compiled Angular
bundle, and its own RFID bridge.

Two things are **shared** rather than duplicated, because the hardware behind
them is: the RFID reader port, and the gate cameras.

```
                    ┌──────────────── PLANT LAN ────────────────┐
                    │                                            │
   RFID reader ─────┼──► tcp/20059 ──► bridge (prod)    ─┐       │
                    │            └───► bridge (staging) ─┼───┐   │
                    │        one at a time — see §6.4     │   │   │
                    │                                    │   │   │
   Workstation ─────┼──► :4200 nginx ──► API :8000 ◄─────┘   │   │
   Workstation ─────┼──► :4201 nginx ──► API :8001 ◄─────────┘   │
                    │       │             │  │                   │
                    │       │  webrtc     │  │                   │
                    │       └── :8555 ────┼──┴─► go2rtc ──► ANPR │
                    │                     │      (shared camera  │
   Gate cameras ────┼──► rtsp/554 ────────┼───    stack, §6.5)   │
                    │                     │                      │
                    └─────────────────────┼──────────────────────┘
                                          ▼
                             PostgreSQL  eagle_cement_prod
                                         eagle_cement_staging
```

Everything except the bridge dashboard binds `0.0.0.0`, because the readers and
the office workstations reach this box over the plant network. That includes the
camera stack, whose go2rtc API is unauthenticated — the `ufw` rules from
`eaglectl firewall` are what confine it to your LAN (§6.5).

| | production | staging |
|---|---|---|
| Web UI (nginx) | `:4200` | `:4201` |
| API (NestJS) | `:8000` | `:8001` |
| Reader port (bridge) | `:20059` | `:20059` — the same port, one bridge at a time (§6.4) |
| Database | `eagle_cement_prod` | `eagle_cement_staging` |
| API service | `eagle-api@prod` | `eagle-api@staging` |
| Bridge service | `eagle-bridge@prod` | `eagle-bridge@staging` |
| Install root | `/opt/eagle-cement/prod` | `/opt/eagle-cement/staging` |
| Camera stack | `eagle-cement-camera` — one shared compose project (§6.5) | |

---

## 1. Prerequisites

### 1.1 Host

- Ubuntu 22.04 or 24.04 (Debian 12 also works), x86-64
- 6 GB RAM minimum, 8 GB comfortable — two Node builds, an Angular build, and
  the ANPR container holding two ONNX models in memory
- ~16 GB free disk: each instance carries its own `node_modules` and build
  output, and the camera stack adds ~3 GB of container images plus whatever the
  plate snapshots accumulate to
- A static LAN address, or a DHCP reservation. The readers are configured with
  this box's IP, so it must not move — and go2rtc hands that same address to
  browsers as its WebRTC candidate.
- Outbound internet on first run only, to fetch apt packages, Node, bun,
  container images and the ANPR models.
- `sudo` / root access, and `git` available to clone the repositories.

Everything else — PostgreSQL, nginx, Node.js 22, bun, JDK 17, Docker Engine with
the compose v2 plugin — is installed by `bootstrap`. Docker is skipped entirely
when `CAMERA_ENABLED=no`.

### 1.2 Ports must be free

`bootstrap` will not move an existing service out of the way. Check first:

```bash
sudo ss -lptn 'sport = :4200 or sport = :4201 or sport = :8000 or sport = :8001 or sport = :20059 or sport = :1984 or sport = :8554 or sport = :8555 or sport = :9137'
```

| Port | Used by | If taken |
|---|---|---|
| `4200`, `4201` | nginx vhosts (web UI) | change `WEB_PORT_*` in the conf |
| `8000`, `8001` | NestJS APIs | change `API_PORT_*` |
| `20059` | bridge reader listener (one port, both instances) | change `BRIDGE_PORT`, **and reconfigure the readers** |
| `5432` | PostgreSQL | reuse it — point `DB_HOST`/`DB_PORT` at the existing server |
| `1984` | go2rtc API and dashboard | change `GO2RTC_API_PORT` |
| `8554` | go2rtc RTSP republisher | change `GO2RTC_RTSP_PORT` |
| `8555` | go2rtc WebRTC, tcp **and** udp | change `GO2RTC_WEBRTC_PORT` |
| `9137` | ANPR service (`/docs`, `/detect`, `/health`) | change `ANPR_PORT` |

The camera ports only matter when `CAMERA_ENABLED=yes` (the default). All four
are published on `0.0.0.0`, so they are reachable from any machine on the plant
LAN — see §6.5 for what that means for go2rtc's unauthenticated API.

Nothing here needs port 80. If another web server (Apache, for instance) already
owns it, leave it running — `bootstrap` disables nginx's stock `default` site,
which is the only thing that would have competed for `:80`.

### 1.3 A clean PostgreSQL namespace

`init` creates a role named `eagle` and the databases `eagle_cement_prod` and
`eagle_cement_staging`. If a role called `eagle` already exists, **its password
will be reset** to the generated one. Rename `DB_USER` in the conf if that role
belongs to something else:

```bash
sudo -u postgres psql -c '\du eagle' -c '\l eagle_cement_*'
```

### 1.4 Access to the five repositories

The clone URLs are SSH (`git@github.com:Geoplan-Philippines/…`), so the account
running the clone needs a key on the GitHub org. Confirm with:

```bash
ssh -T git@github.com
```

In the default `SOURCE_MODE=local` the script builds from a working copy you
cloned yourself, so this only matters at clone time. With `SOURCE_MODE=git` the
script clones and fetches as the `eagle` service user, which then needs its own
readable deploy key.

### 1.5 Credentials and data to have on hand

Collect these before `init`. The server validates its environment with zod at
boot and calls `process.exit(1)` on the first failure, so a missing **required**
value means the API never starts — you get `Invalid environment variables:` in
`eaglectl logs <instance> server`, not a degraded feature.

Required — the API will not boot without them:

| Value | Needed for |
|---|---|
| `RESEND_API_KEY` | the Resend client |
| `RESEND_FROM_EMAIL` | sender; must be `user@host.tld` or `Name <user@host.tld>` |
| `RESEND_EAGLE_CEMENT_TEMPLATE_ID` | the transaction alert template |
| `OCR_SPACE_API_KEY` | plate OCR |

Optional — sensible defaults, set them when you want the feature:

| Value | Default | Effect when unset |
|---|---|---|
| `TRANSACTION_ALERT_RECIPIENTS` | empty | auto-alerting on non-`VERIFIED` transactions is disabled |
| `RESEND_VERIFY_TEMPLATE_ID` | unset | verification email has no template |
| `LAN_CIDR` | derived from this box's subnet | may pick the wrong interface on a multi-homed host |
| `CCTV_DOME_URL`, `CCTV_FACE_URL`, `CCTV_PLATE_URL` | empty | go2rtc starts, but those streams have no source — the live views and the plate worker stay blank |
| `GO2RTC_WEBRTC_ADDR` | this box's LAN address | only set it when browsers reach this box through a different address |

The three `CCTV_*_URL` values are the camera RTSP URLs, password included, in
the form `rtsp://user:pass@host:554/Streaming/Channels/101` for Hikvision
(`101` is the HD main stream, `102` the substream). Have them before `init` if
the cameras are already on the network; the generated `.env` holding them is
mode 600. Nothing else about the camera stack needs credentials.

`DATABASE_URL` and `JWT_SECRET` are also required, but the script generates
both — you do not supply them.

The production seed also expects the truck list CSV at
`rfid-based-authorization-server/docs/`. Confirm it is present before
`seed prod prod`, or the seed aborts:

```bash
ls rfid-based-authorization-server/docs/*.csv
```

## 2. Get the code onto the server

The five repositories must sit side by side, with `deploy/` alongside them:

```
eagle-cement/
├── deploy/                              ← this directory
├── rfid-based-authorization-server/     ← NestJS API + Prisma
├── rfid-based-authorization-client/     ← Angular UI
├── rfid-bridge/                         ← Java bridge (reader → API)
├── camera-access/                       ← go2rtc config for the gate cameras
└── anpr-service/                        ← plate detection + OCR (FastAPI)
```

```bash
mkdir -p ~/eagle-cement && cd ~/eagle-cement
git clone git@github.com:Geoplan-Philippines/rfid-based-authorization-server.git
git clone git@github.com:Geoplan-Philippines/rfid-based-authorization-client.git
git clone git@github.com:Geoplan-Philippines/rfid-bridge.git
git clone git@github.com:Geoplan-Philippines/camera-access.git
git clone git@github.com:Geoplan-Philippines/anpr-service.git
# plus the deploy/ directory containing eagle-cement.sh
```

The `docker-compose.yml` in the repository root is a **development** convenience
for running the camera stack from a working copy. The deployment generates its
own compose file at `/opt/eagle-cement/camera/docker-compose.yml` — with the
right ports, the loopback bindings and the real paths — so the root file is
neither read nor copied by `eaglectl`.

## 3. Configure

Defaults are baked into the script, so this step is optional on a first trial.
For a real install, copy the sample and edit it:

Run this from `deploy/` (the directory holding `eagle-cement.sh`):

```bash
cd deploy
sudo install -d -m 755 /etc/eagle-cement
sudo cp eagle-cement.conf.example /etc/eagle-cement/deploy.conf
sudo chmod 600 /etc/eagle-cement/deploy.conf
sudo nano /etc/eagle-cement/deploy.conf
```

At minimum, set:

- `SRC_ROOT` — the directory holding the five repos
- `RESEND_API_KEY`, `RESEND_FROM_EMAIL`, `RESEND_EAGLE_CEMENT_TEMPLATE_ID`,
  `OCR_SPACE_API_KEY` — all four are required; the API refuses to boot without
  them (see §1.5)
- `LAN_CIDR` — pin the reader VLAN instead of letting it be derived
- `CCTV_DOME_URL`, `CCTV_FACE_URL`, `CCTV_PLATE_URL` — the camera RTSP URLs, or
  `CAMERA_ENABLED=no` if the cameras are not in yet

To have staging track a different branch than production, set
`SOURCE_MODE=git` and `GIT_REF_STAGING=develop`. In `local` mode both instances
build from the same working copy, which is fine for a single-box install but
means staging and production always run the same code.

## 4. Install

```bash
cd deploy                            # if you are not already there
sudo ./eagle-cement.sh bootstrap     # packages, Docker, service user, systemd units
sudo ./eagle-cement.sh init all      # databases, .env, bridge.properties, nginx, camera config
sudo ./eagle-cement.sh deploy all    # sync, build, migrate, start everything
```

`bootstrap` also links the script to `/usr/local/bin/eaglectl`, so afterwards you
can just run `sudo eaglectl <command>` from anywhere.

The first `deploy` takes 15–30 minutes: it installs dependencies and builds two
NestJS apps, two Angular bundles, the bridge jar and the ANPR container image
(which pulls PyTorch and onnxruntime), then downloads the ANPR models on first
container start. Later deploys are much faster — `node_modules`, the docker
layer cache and the `anpr-model-cache` volume all survive.

`deploy all` does the shared camera stack first and once, then loops over the
instances. To rebuild only the cameras, `sudo eaglectl deploy all camera`.

Then load the initial data and mint the bridge credentials:

```bash
sudo eaglectl seed prod prod         # real reference data (roles, admin user)
sudo eaglectl seed staging demo      # demo dataset for staging

sudo eaglectl bridge-key prod
sudo eaglectl bridge-key staging

sudo eaglectl status
sudo eaglectl health
```

The production seed creates `admin@eaglecement.com` / `EagleCement@2026`.
**Sign in and change it immediately**, then archive the account once a real
super-admin exists.

Finally, open the LAN ports:

```bash
sudo eaglectl firewall
sudo ufw enable      # only if you actually want the firewall on
```

## 5. Point the hardware at it

`eaglectl urls` prints exactly what to type into each device:

```
prod     web http://10.10.0.137:4200/   api http://10.10.0.137:8000/api/v1   reader 10.10.0.137:20059
staging  web http://10.10.0.137:4201/   api http://10.10.0.137:8001/api/v1   reader 10.10.0.137:20059
camera   go2rtc http://10.10.0.137:1984/    anpr http://10.10.0.137:9137/docs
         webrtc 10.10.0.137:8555 (tcp+udp)   rtsp rtsp://10.10.0.137:8554/<stream>
         go2rtc's API is unauthenticated — keep it inside LAN_CIDR.

Both instances share reader port 20059, so only one bridge runs at a time
— currently prod. Switch with: sudo eagle-cement.sh bridge-switch <instance>
```

On each RFID reader set:

- **Destination IP** → this server's LAN address
- **Destination Port** → `20059`

The reader dials in as a TCP client; the bridge listens and accepts.

**The bridge always listens on `20059`, in both instances.** The reader port is
a property of the hardware, not of the deployment — there is one physical reader
dialling one `IP:port`, and the only thing that changes between prod and staging
is the backend URL the bridge posts to. So the reader is configured once and
never touched again.

The trade-off is that the two bridges are mutually exclusive — one TCP port,
one process — so exactly one runs at any moment. §6.4 covers handing it over.

To confirm a reader is talking to the box:

```bash
sudo eaglectl logs prod bridge -f
```

With `log.raw=true` you will see every byte chunk arrive. Production defaults to
`log.raw=false`; staging leaves it on for commissioning.

### The cameras

The cameras are not configured to point at this box — it dials them. Each
`CCTV_*_URL` in the conf is an RTSP URL the box opens as a client, so on the
camera side you only need:

- a static address (or DHCP reservation) matching the URL
- an account whose password is what the URL carries
- the main stream on channel `101`, the substream on `102` (Hikvision)

After `init` and `deploy all camera`, confirm each stream is actually producing
frames — a stream that is merely *configured* looks identical in `status`:

```bash
sudo eaglectl camera streams
```

```
go2rtc streams on 127.0.0.1:1984
  ✓ stream 'gate_dome' is producing frames
  ✓ stream 'gate_face' is producing frames
  ✓ stream 'gate_plate' is producing frames

  WebRTC candidate handed to browsers: 10.10.0.137:8555
```

If the candidate address is wrong for the workstations, set
`GO2RTC_WEBRTC_ADDR` and re-run `init`. A wrong candidate is the classic
"everything is green but the video never starts" fault: the browser negotiates
successfully and then sends media to an address it cannot reach.

## 6. Day-to-day operation

```bash
sudo eaglectl status                 # what is running, and where
sudo eaglectl health                 # probe API, web, database, reader port, cameras
sudo eaglectl urls                   # LAN addresses for hardware and browsers

sudo eaglectl logs prod server -f    # API log
sudo eaglectl logs prod bridge -f    # bridge log
sudo eaglectl logs prod nginx        # nginx error log
sudo eaglectl logs camera -f         # both camera containers
sudo eaglectl logs camera anpr-service -f   # just the plate detector

sudo eaglectl restart staging        # everything in one instance
sudo eaglectl restart prod server    # just the API
sudo eaglectl restart all camera     # the shared camera stack
```

### Shipping a change

Pull first, then deploy. In the default `SOURCE_MODE=local` the script builds
from your working copy and **never pulls for you** — `deploy` rsyncs whatever is
in `SRC_ROOT` at that moment, committed or not:

```bash
cd "$SRC_ROOT"                                        # the dir holding the repos
git -C rfid-based-authorization-server pull
git -C rfid-based-authorization-client pull

cd deploy
sudo ./eagle-cement.sh deploy staging   # build and release to staging only
# ...verify on http://<ip>:4201/ ...
sudo ./eagle-cement.sh deploy prod      # then production
```

With `SOURCE_MODE=git` the script does the fetching itself — it clones into
`/opt/eagle-cement/checkout/<instance>` and hard-resets to `GIT_REF`, so you skip
the `git pull` lines and just run `deploy`.

You do **not** re-run `bootstrap` or `init` for a code change. `bootstrap` is
once per host; `init` only when configuration changes (ports, credentials, the
LAN address) — see "When you also need `init`" below.

Narrow it to one component when that is all that changed:

```bash
sudo eaglectl deploy prod client     # Angular only — no API restart
sudo eaglectl deploy prod server     # API + migrations
sudo eaglectl deploy prod bridge     # rebuild and restart the bridge
```

`deploy` always runs `prisma migrate deploy` before restarting the API, so
schema changes are applied in order.

What a `deploy` does and does not touch:

| | |
|---|---|
| Rebuilt every time | `node_modules`, the Prisma client, `dist/`, the Angular bundle, the bridge jar |
| Applied every time | pending Prisma migrations |
| Preserved | `.env`, `bridge.properties` (and its API key), `uploads/`, `backups/` |
| Never re-run | the seeds — your data is not touched |

#### When you also need `init`

`deploy` deliberately does not overwrite `.env`, so a code change that
introduces a **new environment variable** will not pick it up. Add the value to
`/etc/eagle-cement/deploy.conf`, then:

```bash
sudo eaglectl init prod && sudo eaglectl deploy prod server
```

If the variable is genuinely new to the project, `write_server_env` in
`eagle-cement.sh` also needs a line emitting it — the generated `.env` only
contains the keys that function knows about. The API validates its environment
at boot and exits on the first missing required key, so this shows up
immediately in `eaglectl logs prod server`, not as a subtle runtime bug.

Same for a changed server IP (`CORS_ALLOWED_ORIGINS` is baked at `init` time) or
changed ports.

### Database

```bash
sudo eaglectl backup all                       # pg_dump -Fc into <instance>/backups
sudo eaglectl backup prod

sudo eaglectl restore staging /opt/eagle-cement/prod/backups/eagle_cement_prod-20260806-101500.dump
sudo eaglectl psql prod                        # psql shell on that database
sudo eaglectl migrate prod                     # migrations without a rebuild
```

Copying a production dump into staging is the fastest way to reproduce a
production problem with real data.

A nightly backup is worth adding:

```bash
sudo crontab -e
# 0 1 * * *  /usr/local/bin/eaglectl backup all >> /var/log/eagle-backup.log 2>&1
```

Nothing prunes old dumps — add a `find … -mtime +30 -delete` if disk is tight.

### 6.4 Handing the reader to staging, and back

The bridge listens on `20059` in both instances, so exactly one runs at a time.
To point the live reader at staging:

```bash
sudo eaglectl bridge-switch staging
```

It stops whichever bridge holds the port, waits for the port to be released,
starts the target, and confirms it took the port. Going back is the same command
with `prod`. Nothing on the reader changes — it keeps dialling the same
`IP:20059`, and whichever bridge is up receives the frames and posts them to
its own API.

`status` shows who owns it:

```
prod
  bridge   active   (enabled)   reader → 10.10.0.137:20059 (owns the reader)
staging
  bridge   inactive (disabled)  reader → 10.10.0.137:20059 (idle — prod owns the reader)
```

An idle bridge is the normal resting state for whichever instance does not hold
the reader, so `health` reports it as `idle`, not as a failure.

Two things worth knowing:

- **`deploy` never takes the reader away from a running instance.** Deploying
  staging's bridge builds and configures it, then leaves it stopped if
  production currently owns the port, telling you to run `bridge-switch`.
- **Transactions follow the bridge.** While staging holds the reader, real gate
  traffic lands in `eagle_cement_staging` and production records nothing. Switch
  back as soon as you are done testing.

`BRIDGE_PORT` is a single setting, not one per instance, because it describes
the reader rather than the deployment. The bridge's `bridge.properties` differs
between prod and staging in exactly one line:

```properties
listen.port=20059                                              # identical
backend.url=http://127.0.0.1:8000/api/v1/transactions/rfid-reads   # prod
backend.url=http://127.0.0.1:8001/api/v1/transactions/rfid-reads   # staging
```

### The bridge dashboard

The bridge ships a small web dashboard, but it binds to loopback only and its
control endpoints are unauthenticated, so it is **not** published to the LAN by
default. Reach it over SSH:

```bash
sudo eaglectl bridge-ui              # prints the port and the exact command
ssh -L 20080:localhost:20080 you@<server-ip>
# then open http://localhost:20080/
```

The daemon picks the first free port from 20080 upward, so which instance gets
20080 and which gets 20081 depends on start order — that is why `bridge-ui`
reads the actual port back from the log instead of assuming it. If you must
expose it on the LAN, set `BRIDGE_UI_EXPOSE=yes` plus the `BRIDGE_UI_PORT_*`
values and redeploy the bridge. Only do this on a trusted VLAN: anyone who can
reach that port can stop the bridge.

### 6.5 The shared camera stack

The cameras are shared for the same reason the reader port is: there is one set
of them. `go2rtc` and the ANPR service run as a single docker compose project,
`eagle-cement-camera`, deployed once per host — not once per instance — and both
APIs reach it over loopback.

```bash
sudo eaglectl deploy all camera      # sync, rebuild the image, restart
sudo eaglectl camera ps              # docker compose ps
sudo eaglectl camera streams         # which streams are producing frames
sudo eaglectl logs camera -f
sudo eaglectl restart all camera
```

**All four camera ports are on the LAN.** From any workstation on the plant
network:

| URL | What |
|---|---|
| `http://<server-ip>:1984/` | go2rtc's own dashboard — stream list, live preview, logs |
| `http://<server-ip>:9137/docs` | the ANPR service's OpenAPI page; `POST /detect` a JPEG and get the plate back |
| `rtsp://<server-ip>:8554/gate_plate` | open the republished stream in VLC |
| `<server-ip>:8555` tcp+udp | WebRTC media — the browser connects here directly |

The two APIs on this box still reach the stack over `127.0.0.1` (`GO2RTC_API_URL`
and `ANPR_SERVICE_URL` in each generated `.env`) — same listener, shortest path.

**go2rtc's API has no authentication.** Anyone who can reach `:1984` can add,
remove or repoint a stream, and the camera RTSP URLs — passwords included — are
visible there. The `ufw` rules are the only thing limiting that, so this matters:

```bash
sudo eaglectl firewall     # allows LAN_CIDR → 1984, 8554, 8555 (tcp+udp), 9137
sudo ufw enable            # the rules do nothing until the firewall is on
sudo ufw status numbered
```

Set `LAN_CIDR` to the narrowest subnet that still contains the workstations that
need it, rather than letting it be derived. To take these off the LAN later,
change the `ports:` lines in `write_compose_file` back to `127.0.0.1:<port>:…`
and re-run `init` — nothing in the APIs depends on them being externally
reachable.

**Only one instance should be recording.** Both APIs can *view* the cameras, but
the continuous plate worker — the one that reads the gate whether or not anyone
has the page open — is the camera's equivalent of `bridge-switch`. It is on for
production and off for staging:

```
ANPR_CONTINUOUS_PROD=true
ANPR_CONTINUOUS_STAGING=false
```

`status` shows which instance is recording:

```
prod
  anpr     recording (worker)   stream 'gate_plate' every 1500ms
staging
  anpr     off       (worker)   stream 'gate_plate' every 1500ms

camera (shared)
  go2rtc   running  (docker)   http://10.10.0.137:1984/  webrtc 10.10.0.137:8555
  anpr     running  (docker)   http://10.10.0.137:9137/docs
```

To hand recording to staging, flip both values and re-run
`init` — it rewrites each instance's `.env` — then restart the APIs. Unlike
`bridge-switch` nothing enforces exclusivity here, because nothing physically
prevents both from polling; leaving both on means the same truck is recorded
twice, in two databases.

Deploying the camera stack is independent of the instances: it never restarts an
API, and `destroy <instance>` leaves it running. It is removed only by
`purge-host` or the uninstaller.

## 7. What gets created on the server

```
/opt/eagle-cement/
├── .db-password                  generated PostgreSQL password (mode 600)
├── .home/                        HOME for the service user, holds build caches
├── prod/
│   ├── server/                   API source + node_modules + dist
│   │   ├── .env                  generated config (mode 600)
│   │   └── uploads -> ../uploads symlink, so photos survive deploys
│   ├── client/                   Angular source + node_modules + dist
│   ├── web/                      the built bundle — nginx document root
│   ├── bridge-src/               bridge source, where the jar is compiled
│   ├── bridge/
│   │   ├── rfid-bridge.jar
│   │   ├── bridge.properties     generated config (mode 600)
│   │   └── RfidBridge/logs/      bridge.log
│   ├── uploads/                  truck/driver photos and plate crops
│   └── backups/                  pg_dump output
├── staging/                      identical layout
└── camera/                       shared — not per instance
    ├── docker-compose.yml        generated compose project
    ├── camera-access/
    │   ├── .env                  RTSP URLs, camera passwords (mode 600)
    │   └── go2rtc.yaml           generated, incl. the WebRTC candidate
    └── anpr-service/
        ├── .env                  generated config (mode 600)
        ├── Dockerfile, app/      synced source, the image build context
        └── snapshots/            wide frames + plate crops, bind-mounted
```

System-level files:

| Path | What |
|---|---|
| `/etc/systemd/system/eagle-api@.service` | API template unit |
| `/etc/systemd/system/eagle-bridge@.service` | bridge template unit |
| `/etc/nginx/sites-available/eagle-cement-{prod,staging}.conf` | web vhosts |
| `/etc/eagle-cement/deploy.conf` | your configuration |
| `/usr/local/bin/eaglectl` | symlink to the script |

Both services run as the unprivileged `eagle` system user under systemd
hardening (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`), writing
only inside their own instance directory. They start on boot and restart on
failure.

The camera stack is the exception: it is containers, not systemd units, managed
by Docker under the `eagle-cement-camera` compose project. Both containers carry
`restart: unless-stopped`, so they come back on boot and after a crash the same
way. Docker also owns one named volume, `eagle-cement-camera_anpr-model-cache`,
holding the downloaded ONNX weights so a rebuild does not re-fetch them.

## 8. How the pieces talk

- **Browser → nginx → API.** The Angular bundle is compiled with
  `apiBaseUrl: '/api/v1'`, so every request is same-origin against whichever
  host the operator typed. nginx proxies `/api/` and `/uploads/` to the API on
  loopback. No CORS, and no hostname baked into the bundle — the same build
  works from `localhost`, the LAN IP, or a hostname.
- **Reader → bridge → API.** The reader opens a TCP connection to the bridge's
  listen port. The bridge de-duplicates a tag's continuous reads into one
  presence session (`session.gap.ms`, default 120 s) and POSTs once per session
  to `/api/v1/transactions/rfid-reads` on loopback, authenticating with the
  `x-api-key` minted by `eaglectl bridge-key`.
- **API → PostgreSQL** over loopback, one database per instance, using the
  shared `eagle` role.
- **Cameras → go2rtc → API → browser.** go2rtc dials each camera's RTSP URL and
  republishes it. The browser asks its own API for a WHEP offer
  (`POST /api/v1/cctv/whep`); the API relays that to go2rtc on `127.0.0.1:1984`
  and hands the answer back. From then on media flows browser-to-go2rtc directly
  over `:8555`. Signalling therefore goes through the authenticated API even
  though `:1984` is also open on the LAN.
- **API → ANPR.** For a plate reading the API pulls a JPEG frame from go2rtc
  (`/api/frame.jpeg?src=gate_plate`) and POSTs it to the ANPR service on
  `127.0.0.1:9137`, which returns the plate text and writes the crop and wide
  frame under `camera/anpr-service/snapshots/`. This happens both on demand, for
  the live preview, and on a timer in the continuous worker (§6.5). The ANPR
  service's own push-to-backend path exists but is off (`UPLOAD_ENABLED=false`):
  the API pulls rather than the service pushing, so there is one direction of
  travel and no second credential to manage.

## 9. Troubleshooting

**`deploy` fails on `bun install`.** The lockfile has drifted from
`package.json`; the script retries without `--frozen-lockfile` and warns. Commit
the refreshed `bun.lock` when convenient.

**`deploy` says the build produced no `dist/main.js`,** but `nest build` printed
no error. The build ran; the output did not land where everything expects it.
Two distinct causes, both fixed but worth recognising:

- *Stale incremental state.* `tsconfig.build.tsbuildinfo` records what tsc
  already emitted. It is machine-local, and nest's `deleteOutDir` wipes `dist/`
  without clearing it — so a copy carried over from a developer's machine
  convinces tsc the output is current and it emits **nothing**. `deploy` now
  excludes `*.tsbuildinfo` from the sync and deletes any it finds before
  building. If you hit this by hand, `rm -f *.tsbuildinfo && rm -rf dist` and
  rebuild.
- *Nested output.* `nest build` infers its output root from the common ancestor
  of every file in the program, so a single `.ts` outside `src/` (a Prisma seed,
  `prisma.config.ts`) pushes the entrypoint to `dist/src/main.js`.
  `tsconfig.build.json` pins `rootDir: "./src"` and `include: ["src/**/*"]` to
  prevent it. The seeds under `prisma/` are run directly by bun and are not
  meant to be compiled.

**`seed` reports `Script not found`.** That instance has no server deployed yet,
so there is no `package.json` to read the script from — `deploy` it first. Note
that `deploy all` stops at the first failure, so a broken production build
leaves staging untouched.

**API will not start.** `sudo eaglectl logs prod server`. The server validates
its environment at boot and exits with `Invalid environment variables:` listing
the offending keys. Fix `/etc/eagle-cement/deploy.conf`, then
`sudo eaglectl init prod && sudo eaglectl restart prod server`.

**Web page loads but every request 502s.** nginx is up and the API is not.
`sudo eaglectl health prod` will show it; check the API log.

**Reader connects but nothing appears in the UI.** In order:
1. `sudo eaglectl logs prod bridge -f` — are frames arriving at all? If not, the
   reader's destination IP/port is wrong or the firewall is blocking it.
2. Frames arrive but no transaction: look for `401` in the bridge log. The API
   key is missing or revoked — re-run `sudo eaglectl bridge-key prod`.
3. Reads arrive but no *new* transactions: that is `session.gap.ms` doing its
   job. The same tag sitting in the field stays one transaction for 120 s.

**A tag is read once and never again.** `session.gap.ms=120000` means the truck
must leave the field for two minutes before a fresh transaction opens. Lower
`BRIDGE_SESSION_GAP_MS` and re-run `init` if the lane cycles faster than that.

**Port already in use.** `sudo ss -ltnp | grep <port>`. Change the port in the
config, re-run `init`, and redeploy.

**A camera stream is configured but produces no frames.**
`sudo eaglectl camera streams` marks it. Almost always the RTSP URL: wrong
password, wrong channel, or the camera is unreachable from this box. Check the
URL by hand before touching anything else —

```bash
sudo grep CCTV_ /opt/eagle-cement/camera/camera-access/.env
ffprobe -rtsp_transport tcp 'rtsp://user:pass@host:554/Streaming/Channels/101'
```

then fix `CCTV_*_URL` in the conf, `sudo eaglectl init`, and
`sudo eaglectl restart all camera`. Note that a password containing `@` or `/`
must be percent-encoded in the URL.

**The live view connects but the video never appears.** The WebRTC candidate is
an address the browser cannot reach. `sudo eaglectl camera streams` prints the
candidate go2rtc is handing out; it must be an address the workstation can route
to. Set `GO2RTC_WEBRTC_ADDR`, re-run `init`, restart the camera stack. Also
confirm `:8555` is open on **udp** as well as tcp — `sudo eaglectl firewall`
adds both, but a hand-written rule often covers only tcp.

**A camera URL works from another machine but not from the server.** Check it
the other way round too: go2rtc's dashboard at `http://<server-ip>:1984/` shows
each stream's live state and its error, which is usually faster than reading
logs. If that page itself is refused from a workstation, `ufw` is blocking it —
`sudo ufw status numbered` and confirm `LAN_CIDR` covers that machine.

**The ANPR service never becomes healthy on first deploy.** It downloads its
detector and OCR models on first start, which is slow on a plant link;
`deploy` waits up to three minutes. `sudo eaglectl logs camera anpr-service -f`
shows the download. Once cached in the `anpr-model-cache` volume, later starts
take seconds.

**The same truck is recorded twice.** Both instances have the continuous plate
worker enabled. One camera, one recorder — see §6.5.

**`deploy … camera` fails with a docker permission or socket error.** The
compose project runs as root from the script, so this normally means the daemon
is not up: `systemctl status docker`. If Docker was installed by hand without
the compose v2 plugin, `docker compose version` fails and `bootstrap` says so.

**Start over on one instance.** `sudo eaglectl destroy staging` removes its
services, files and database — production is untouched. Then `init` and `deploy`
it again. See §12 for the full range of removal options.

## 10. Known limitations and things to fix

- **`POST /api/v1/api-keys` is unauthenticated.** The auth guard is commented
  out in `api-keys.controller.ts`, which is how `eaglectl bridge-key` can mint a
  key without logging in. Anyone who can reach the API can mint a device
  credential. Re-enable the guard before this box is reachable from an untrusted
  network — `bridge-key` will then need a token, or you paste a key into
  `bridge.properties` by hand.
- **The camera stack is shared but not interlocked.** `bridge-switch` enforces
  that exactly one bridge holds the reader. Nothing equivalent exists for the
  continuous plate worker: setting `ANPR_CONTINUOUS_*` on for both instances
  will happily record the same truck into both databases (§6.5).
- **go2rtc's API has `origin: "*"`, no authentication, and is on the LAN.**
  Anyone who can reach `:1984` can list the streams — camera passwords included,
  they are in the RTSP URLs — and add, remove or repoint one. The ANPR service
  on `:9137` is likewise unauthenticated. `ufw` scoped to `LAN_CIDR` is the only
  control on this, so run `eaglectl firewall` **and** `ufw enable`, and treat
  the plant VLAN as trusted or narrow `LAN_CIDR` until it is.
- **The camera passwords sit in two places.** `/etc/eagle-cement/deploy.conf`
  and the generated `/opt/eagle-cement/camera/camera-access/.env`, both mode
  600. Rotating a camera password means editing the conf and re-running `init`.
- **The ANPR service holds its models in one process.** A single container with
  one worker, so plate requests serialise. That is ample for one gate; a second
  lane needs a second replica and a way to route to it.
- **No TLS.** Traffic is plain HTTP on the plant LAN — including the WebRTC
  signalling, though the media itself is DTLS-encrypted by WebRTC regardless. If
  the UI ever needs to be reachable beyond that network, put a certificate on
  the nginx vhosts and change `WEB_PORT` to 443.
- **Backups are local.** Dumps land on the same disk as the database. Copy them
  off the box on a schedule.
- **`CORS_ALLOWED_ORIGINS` records the LAN IP at `init` time.** If the server's
  address changes, re-run `init` and restart the API. The UI itself does not
  care — it is same-origin.

## 11. Command Reference & Operational Playbooks

### 11.1 Master Command Syntax

```bash
sudo eaglectl <command> [instance] [component]
# or:
sudo ./eagle-cement.sh <command> [instance] [component]
```

* **`instance`**: `prod` | `staging` | `all` *(default: `all`)*
* **`component`**: `server` | `client` | `bridge` | `camera` | `all` *(default: `all`)*

---

### 11.2 Command Matrix

| Category | Command | Description | Example |
| :--- | :--- | :--- | :--- |
| **System** | `bootstrap` | Install dependencies (Postgres, Nginx, Node, Bun, Docker, JDK) | `sudo eaglectl bootstrap` |
| | `init [inst]` | Generate DB, `.env`, nginx sites, camera and bridge configs | `sudo eaglectl init all` |
| | `deploy [inst] [comp]` | Sync source, build bundles, run migrations, reload services | `sudo eaglectl deploy prod server` |
| | `firewall` | Configure UFW firewall rules for plant LAN CIDR | `sudo eaglectl firewall` |
| | `version` | Print script version | `sudo eaglectl version` |
| **Monitoring** | `status [inst]` | Check status of API, client, DB, bridge ownership, and cameras | `sudo eaglectl status` |
| | `health [inst]` | Probe HTTP endpoints, DB connectivity, and active reader ports | `sudo eaglectl health` |
| | `urls [inst]` | Display all LAN URLs, Web UI, API, and reader dial-in ports | `sudo eaglectl urls` |
| **Service Control** | `start [inst] [comp]` | Start systemd services or camera stack | `sudo eaglectl start prod` |
| | `stop [inst] [comp]` | Stop systemd services or camera stack | `sudo eaglectl stop staging` |
| | `restart [inst] [comp]`| Restart systemd services or camera stack | `sudo eaglectl restart all` |
| **Logs** | `logs <inst> <server\|bridge\|nginx> [-f]` | Tail service logs | `sudo eaglectl logs prod server -f` |
| | `logs camera [go2rtc\|anpr-service] [-f]` | Follow camera container logs | `sudo eaglectl logs camera -f` |
| **Database** | `migrate [inst]` | Run Prisma migrations (`prisma migrate deploy`) | `sudo eaglectl migrate prod` |
| | `seed <inst> [prod\|demo]` | Load baseline production or demo dataset | `sudo eaglectl seed prod prod` |
| | `backup [inst]` | Generate `pg_dump` in `/opt/eagle-cement/<inst>/backups/` | `sudo eaglectl backup prod` |
| | `restore <inst> <file>` | Restore a PostgreSQL dump over target instance database | `sudo eaglectl restore staging /path/to/dump.sql` |
| | `psql <inst>` | Open an interactive `psql` shell into target database | `sudo eaglectl psql prod` |
| **RFID Bridge** | `bridge-switch <inst>` | **Hand the physical reader port (20059) to target instance** | `sudo eaglectl bridge-switch prod` |
| | `bridge-key <inst>` | Generate an API key and inject into `bridge.properties` | `sudo eaglectl bridge-key prod` |
| | `bridge-ui [inst]` | Print bridge web dashboard URL and SSH tunnel command | `sudo eaglectl bridge-ui` |
| **Camera Gateway** | `camera streams` | Verify live frame production on all go2rtc camera feeds | `sudo eaglectl camera streams` |
| | `camera ps` | List camera Docker container statuses (`go2rtc` & `anpr`) | `sudo eaglectl camera ps` |
| | `camera restart` | Restart the go2rtc & ANPR container stack | `sudo eaglectl camera restart` |
| | `camera logs [-f]` | Tail camera container logs | `sudo eaglectl camera logs -f` |
| **Teardown** | `destroy <inst\|all>` | Remove instances (services, code, DB, uploads) | `sudo eaglectl destroy staging` |
| | `purge-host` | Remove template units, service user, `/opt/eagle-cement` | `sudo eaglectl purge-host` |

---

### 11.3 Key Operational Playbooks

#### 🔄 Playbook A: Switching Hardware from Staging to Production
When you are ready to cut live plant operations over to **Production**:

1. **Switch the Physical RFID Reader**:
   ```bash
   sudo eaglectl bridge-switch prod
   ```
   *(Stops staging bridge on port 20059 and starts prod bridge; verify with `sudo eaglectl status`)*

2. **Ensure Continuous ANPR Recording is on Prod**:
   In your `/etc/eagle-cement/deploy.conf` (or `eagle-cement.conf`):
   ```bash
   ANPR_CONTINUOUS_PROD=true
   ANPR_CONTINUOUS_STAGING=false
   ```
   Then apply and reload the APIs:
   ```bash
   sudo eaglectl init all
   sudo eaglectl restart all server
   ```

3. **Verify Everything is Active**:
   ```bash
   sudo eaglectl status
   sudo eaglectl camera streams
   ```

---

#### 🔄 Playbook B: Switching Hardware from Production to Staging (Testing Mode)
When testing new RFID readers, bridges, or plate reading features without affecting production:

1. **Hand the Reader Port to Staging**:
   ```bash
   sudo eaglectl bridge-switch staging
   ```

2. **Direct ANPR Recording to Staging (Optional)**:
   In `/etc/eagle-cement/deploy.conf`:
   ```bash
   ANPR_CONTINUOUS_PROD=false
   ANPR_CONTINUOUS_STAGING=true
   ```
   Apply and restart:
   ```bash
   sudo eaglectl init all
   sudo eaglectl restart all server
   ```

3. **Switch Back to Production When Testing Finishes**:
   ```bash
   sudo eaglectl bridge-switch prod
   ```

---

#### 🚀 Playbook C: Deploying Code Changes

* **Deploying Backend API only**:
  ```bash
  sudo eaglectl deploy prod server
  ```
* **Deploying Frontend Web UI only**:
  ```bash
  sudo eaglectl deploy prod client
  ```
* **Deploying Camera & ANPR stack only**:
  ```bash
  sudo eaglectl deploy all camera
  ```
* **Deploying Everything to Staging first, then Prod**:
  ```bash
  # Step 1: Deploy & test on staging
  sudo eaglectl deploy staging all
  sudo eaglectl health staging

  # Step 2: Deploy to prod
  sudo eaglectl deploy prod all
  sudo eaglectl health prod
  ```

---

#### 🛠️ Playbook D: Troubleshooting & Diagnostics

* **View live backend logs**:
  ```bash
  sudo eaglectl logs prod server -f
  ```
* **View live RFID bridge logs**:
  ```bash
  sudo eaglectl logs prod bridge -f
  ```
* **View camera stream health**:
  ```bash
  sudo eaglectl camera streams
  ```
* **Database manual query**:
  ```bash
  sudo eaglectl psql prod
  # Inside psql: \dt, SELECT count(*) FROM transactions;
  ```
* **Take an ad-hoc database backup**:
  ```bash
  sudo eaglectl backup prod
  # Backup file is saved in /opt/eagle-cement/prod/backups/
  ```

## 12. Removing the installation

### 12.0 Delete everything, one command

```bash
sudo ./eagle-cement-uninstall.sh
```

Removes the whole stack — both instances' services, files, uploads, local
backups and databases, plus the systemd units, the `eagle` user and PostgreSQL
role, the nginx vhosts, the ufw rules and `/usr/local/bin/eaglectl`. The shared
camera stack goes too: both containers, the `eagle-cement-anpr` image, the model
cache volume and every saved plate snapshot.

It surveys the box first and prints what it found, then asks you to type
`DELETE`. See exactly what it would do, changing nothing:

```bash
sudo ./eagle-cement-uninstall.sh --dry-run
```

| Flag | Effect |
|---|---|
| `--dry-run`, `-n` | print every action, change nothing |
| `--yes`, `-y` | skip the typed confirmation (for scripted rebuilds) |
| `--purge-config` | also delete `/etc/eagle-cement`, which holds your API keys |

It is deliberately standalone — it never calls `eagle-cement.sh` and assumes
nothing still exists, so it works on a half-broken install. Every step is
idempotent and non-fatal: a step that cannot complete is reported at the end
rather than aborting the run and leaving the box half-removed. Re-running is
safe, and is the way to retry.

It does **not** remove PostgreSQL, nginx, Node.js, bun, the JDK or Docker itself
— those are shared system packages. §12.4 covers those.

### 12.0.1 Removing less than everything

The `eaglectl` subcommands give finer control. Each level is a superset of the
one before it, so go only as far down as you need.

| Goal | Command |
|---|---|
| Rebuild one instance, keep the other | `sudo eaglectl destroy <instance>` |
| Remove both instances, keep the host prepared | `sudo eaglectl destroy all` |
| Remove everything the script installed | `sudo ./eagle-cement-uninstall.sh` |

`destroy` asks for confirmation twice and prints exactly what it will remove.
Nothing here can be undone.

### 12.1 Back up first

`destroy` drops the database and deletes the uploaded photos. If either might
still be wanted, take a copy **off this machine** before you start — the dumps
written by `backup` live under `/opt/eagle-cement/<instance>/backups/`, which
`destroy` deletes along with everything else.

```bash
sudo eaglectl backup all
sudo cp -a /opt/eagle-cement/prod/backups   ~/eagle-prod-backups
sudo cp -a /opt/eagle-cement/prod/uploads   ~/eagle-prod-uploads
sudo cp -a /opt/eagle-cement/prod/server/.env ~/eagle-prod-env   # API keys, JWT secret
# then copy those somewhere off the box (scp, external disk, …)
```

### 12.2 Remove one instance

```bash
sudo eaglectl destroy staging
```

Stops and disables `eagle-api@staging` and `eagle-bridge@staging`, removes the
nginx vhosts (and the bridge UI vhost, if enabled), drops
`eagle_cement_staging`, and deletes `/opt/eagle-cement/staging` — uploads and
local backups included. Production keeps running throughout; nginx is reloaded,
not restarted. The shared camera stack is untouched and keeps running, since
production is still using it.

To bring it back:

```bash
sudo eaglectl init staging && sudo eaglectl deploy staging
sudo eaglectl seed staging demo
sudo eaglectl bridge-key staging
```

### 12.3 Remove both instances

```bash
sudo eaglectl destroy all
```

Same work, for prod and staging. You are asked to confirm once for the whole
set, after it lists every service, directory and database involved.

This deliberately stops short of the host-level pieces, so the box stays ready
for a fresh `init` + `deploy`. Still present afterwards:

- the systemd template units
- the `eagle` service user and the `eagle` PostgreSQL role
- `/opt/eagle-cement/` — notably `.db-password` and the build caches in `.home/`
- the camera stack, still running: it is host-level, and `destroy` is per-instance
- `/usr/local/bin/eaglectl`, `/etc/eagle-cement/deploy.conf`, and the ufw rules

### 12.4 Remove the host-level install too

```bash
sudo eaglectl purge-host
```

Only runs once no instance directory is left, so `destroy all` must come first.
It removes the two systemd template units, tears down the camera stack
(containers, the `eagle-cement-anpr` image and the model-cache volume), drops
the `eagle` PostgreSQL role, deletes the ufw rules it added, removes
`/opt/eagle-cement` and the `eaglectl` symlink, and deletes the `eagle` system
user.

This is the point where the camera stack goes — it survives `destroy all`,
because it is host-level, not part of either instance.

It leaves alone, on purpose:

- **PostgreSQL, nginx, Node.js, bun, the JDK and Docker.** Shared system
  packages — something else on this box may depend on them.
- **`/etc/eagle-cement/deploy.conf`.** Holds your API keys; keep it if you plan
  to reinstall, and shred it if you do not.
- **The nginx `default` site**, which `bootstrap` disabled. Re-enable it with
  `ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/` if you
  want nginx serving `:80` again.
- **The source repositories** in your working directory. Delete them yourself.

To finish removing every trace:

```bash
sudo rm -rf /etc/eagle-cement           # contains API keys
sudo apt-get purge -y nginx nginx-common postgresql postgresql-contrib \
                      nodejs openjdk-17-jdk-headless
sudo apt-get autoremove -y
sudo rm -rf /opt/bun /usr/local/bin/bun /usr/local/bin/bunx
sudo rm -f /etc/apt/sources.list.d/nodesource.list

# Docker, if this box was only ever running the camera stack
sudo apt-get purge -y docker-ce docker-ce-cli containerd.io \
                      docker-buildx-plugin docker-compose-plugin
sudo rm -rf /var/lib/docker
sudo rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
```

Removing `/var/lib/docker` destroys **every** container, image and volume on
this host. Check what else is there first: `sudo docker ps -a && sudo docker
volume ls`.

Purging `postgresql` destroys **every** database on this host, not just the
Eagle Cement ones. Check what else lives there first:

```bash
sudo -u postgres psql -c '\l'
```

### 12.5 Verifying it is gone

```bash
systemctl list-units 'eagle-*' --all      # expect: no units
ls /opt/eagle-cement 2>&1                 # expect: No such file or directory
sudo -u postgres psql -c '\l' | grep eagle # expect: no rows
ls /etc/nginx/sites-enabled/               # expect: no eagle-* entries
sudo docker ps -a | grep eagle-cement      # expect: no containers
sudo docker volume ls | grep eagle-cement  # expect: no volumes
sudo ss -lptn | grep -E ':(4200|4201|8000|8001|20059|1984|8554|8555|9137)'  # expect: nothing
```
