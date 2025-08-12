#!/usr/bin/env bash
set -euo pipefail
umask 022

# --- make prompts keyboard-friendly (backspace, arrows) ---
if [ -t 0 ]; then
  stty sane 2>/dev/null || true
  bs="$(tput kbs 2>/dev/null || echo '^?')"
  stty erase "$bs" 2>/dev/null || stty erase '^?' 2>/dev/null || stty erase '^H' 2>/dev/null || true
fi

# --- helpers ---------------------------------------------------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: $1 not found." >&2; exit 1; }; }
need docker

# Prefer modern plugin; fall back to legacy docker-compose
if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "ERROR: Docker Compose not found (neither 'docker compose' nor 'docker-compose')." >&2
  exit 1
fi

PROJECT_DIR="$(pwd -P)"
ENV_FILE="${PROJECT_DIR}/.env"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

OWNER_USER="${SUDO_USER:-$(id -un)}"
OWNER_GROUP="$(id -gn "$OWNER_USER" 2>/dev/null || echo "$OWNER_USER")"

echo "=== Traefik + KLSP bootstrap ==="
echo "Project dir: ${PROJECT_DIR}"
echo "Files will be owned by: ${OWNER_USER}:${OWNER_GROUP}"
echo

# --- inputs -----------------------------------------------------------------
read -e -p "Domain for KLSP (FQDN, e.g. www.domain.com): " DOMAIN
while [[ -z "${DOMAIN}" ]]; do read -e -p "Domain cannot be empty. Enter domain: " DOMAIN; done

read -e -p "Let's Encrypt email (for renewal notices): " LE_EMAIL
while [[ -z "${LE_EMAIL}" ]]; do read -e -p "Email cannot be empty. Enter email: " LE_EMAIL; done

# Web UI port (served by Traefik as HTTPS externally)
WEB_PORT_IN=""
read -e -p "KLSP http local web access port (web_port): " -i "83" WEB_PORT_IN
WEB_PORT="${WEB_PORT_IN:-83}"
if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || (( WEB_PORT < 1 || WEB_PORT > 65535 )); then
  echo "ERROR: web_port must be 1..65535." >&2; exit 1
fi

# Aggregation ports: single port or comma-separated list (no spaces)
KLNL_PORT_IN=""
read -e -p "Aggregation port(s) for KiloLink (klnl_port) (no spaces): " -i "50000,50001" KLNL_PORT_IN
# trim spaces around commas
KLNL_PORT="$(echo "$KLNL_PORT_IN" | tr -d '[:space:]')"
IFS=',' read -ra KLNL_ARR <<< "$KLNL_PORT"
if ((${#KLNL_ARR[@]} == 0)); then
  echo "ERROR: klnl_port cannot be empty." >&2; exit 1
fi
for p in "${KLNL_ARR[@]}"; do
  if ! [[ "$p" =~ ^[0-9]+$ ]] || (( p < 1 || p > 65535 )); then
    echo "ERROR: invalid port '$p' in klnl_port; use integers 1..65535, comma-separated." >&2
    exit 1
  fi
done

# Optional legacy mappings if exactly 2 ports provided
SERVER_PORT=""
STREAM_SERVER_PORT=""
if ((${#KLNL_ARR[@]} == 2)); then
  SERVER_PORT="${KLNL_ARR[0]}"
  STREAM_SERVER_PORT="${KLNL_ARR[1]}"
fi

# Image tag
KLS_TAG_IN=""
read -e -p "KLSP image tag (e.g. latest or vX.Y.Z): " -i "latest" KLS_TAG_IN
KLS_TAG="${KLS_TAG_IN:-latest}"

# Public IP/DDNS that devices dial (on-prem may be local IP)
PUBLIC_IP_IN=""
read -e -p "Public IP or DDNS devices will reach (press Enter to use domain): " -i "${DOMAIN}" PUBLIC_IP_IN
PUBLIC_IP="${PUBLIC_IP_IN:-$DOMAIN}"

cat <<INFO

Using:
  DOMAIN=${DOMAIN}
  LE_EMAIL=${LE_EMAIL}
  web_port=${WEB_PORT}
  klnl_port=${KLNL_PORT}
  $( [[ -n "$SERVER_PORT" ]] && echo "server_port=${SERVER_PORT}" )
  $( [[ -n "$STREAM_SERVER_PORT" ]] && echo "stream_server_port=${STREAM_SERVER_PORT}" )
  KLS_TAG=${KLS_TAG}
  PUBLIC_IP=${PUBLIC_IP}

INFO

# --- files & folders --------------------------------------------------------
mkdir -p "${PROJECT_DIR}/traefik/dynamic" "${PROJECT_DIR}/kilolink-server"
[[ -f "${PROJECT_DIR}/traefik/acme.json" ]] || touch "${PROJECT_DIR}/traefik/acme.json"
chmod 600 "${PROJECT_DIR}/traefik/acme.json" || true

# .env for Compose (used for label expansion)
{
  echo "DOMAIN=${DOMAIN}"
  echo "LE_EMAIL=${LE_EMAIL}"
  echo "KLS_TAG=${KLS_TAG}"
  echo "WEB_PORT=${WEB_PORT}"
  echo "KLNL_PORT=${KLNL_PORT}"
  echo "PUBLIC_IP=${PUBLIC_IP}"
  echo "SERVER_PORT=${SERVER_PORT}"
  echo "STREAM_SERVER_PORT=${STREAM_SERVER_PORT}"
} > "${ENV_FILE}"
chmod 644 "${ENV_FILE}"

# docker-compose.yml (no 'version:' to avoid warning)
cat > "${COMPOSE_FILE}" <<'YAML'
services:
  traefik:
    image: traefik:v3.1
    container_name: traefik
    restart: unless-stopped
    command:
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.file.directory=/etc/traefik/dynamic
      - --providers.file.watch=true
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entryPoint.to=websecure
      - --entrypoints.web.http.redirections.entryPoint.scheme=https
      - --certificatesresolvers.le.acme.email=${LE_EMAIL}
      - --certificatesresolvers.le.acme.storage=/acme/acme.json
      - --certificatesresolvers.le.acme.httpchallenge=true
      - --certificatesresolvers.le.acme.httpchallenge.entrypoint=web
      - --api.dashboard=true
    ports:
      - "80:80"
      - "443:443"
      # - "443:443/udp"  # enable for HTTP/3 if desired
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/acme.json:/acme/acme.json
      - ./traefik/dynamic:/etc/traefik/dynamic:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    labels:
      - traefik.enable=true
      - traefik.http.routers.dashboard.rule=Host(`traefik.${DOMAIN}`)
      - traefik.http.routers.dashboard.entrypoints=websecure
      - traefik.http.routers.dashboard.tls.certresolver=le
      - traefik.http.routers.dashboard.service=api@internal

  kls:
    image: kiloview/klnk-pro:${KLS_TAG}
    container_name: klnksvr-pro
    restart: unless-stopped
    network_mode: host
    privileged: true
    command: ["/bin/bash", "/start_server.sh"]   # required by the image
    environment:
      - web_port=${WEB_PORT}
      - klnl_port=${KLNL_PORT}              # single or comma-separated list
      - server_port=${SERVER_PORT}          # only if two ports given (may be empty)
      - stream_server_ip=${PUBLIC_IP}
      - stream_server_port=${STREAM_SERVER_PORT}  # only if two ports given (may be empty)
    volumes:
      - /var/run/avahi-daemon:/var/run/avahi-daemon
      - /var/run/dbus:/var/run/dbus
      - ./kilolink-server:/data
YAML

# Traefik dynamic route (file provider does NOT expand env)
cat > "${PROJECT_DIR}/traefik/dynamic/kls.yml" <<EOF
http:
  routers:
    kls:
      rule: "Host(\`${DOMAIN}\`)"
      entryPoints: ["websecure"]
      service: kls
      tls:
        certResolver: le
  services:
    kls:
      loadBalancer:
        passHostHeader: true
        servers:
          - url: "http://host.docker.internal:${WEB_PORT}"
EOF

# Ownership (only when root) + traversal so compose can read .env
if [[ "${EUID}" -eq 0 ]]; then
  chown -R "${OWNER_USER}:${OWNER_GROUP}" \
    "${PROJECT_DIR}" "${ENV_FILE}" "${COMPOSE_FILE}" \
    "${PROJECT_DIR}/traefik" "${PROJECT_DIR}/kilolink-server"
fi
chmod 755 "${PROJECT_DIR}"

# Ensure OWNER_USER can use Docker
can_docker_as_user() {
  if [[ "${EUID}" -eq 0 ]]; then
    sudo -u "${OWNER_USER}" -H bash -lc 'docker info >/dev/null 2>&1'
  else
    docker info >/dev/null 2>&1
  fi
}

if ! can_docker_as_user; then
  if [[ "${EUID}" -eq 0 ]]; then
    echo "User ${OWNER_USER} cannot access Docker. Adding to 'docker' group..."
    groupadd -f docker
    usermod -aG docker "${OWNER_USER}"
    echo
    echo "➡ Added ${OWNER_USER} to 'docker' group."
    echo "Please run:  newgrp docker"
    echo "Then re-run this script so the new group membership applies."
    exit 1
  else
    echo "ERROR: ${OWNER_USER} is not in the 'docker' group and cannot access Docker."
    echo "Run the following, then re-run this script:"
    echo "  sudo usermod -aG docker ${OWNER_USER}"
    echo "  newgrp docker"
    exit 1
  fi
fi

# Bring up (explicit project dir + env file so labels expand right)
RUN_COMPOSE="${COMPOSE_CMD} --project-directory '${PROJECT_DIR}' \
  --env-file '${ENV_FILE}' -f '${COMPOSE_FILE}' up -d"

if [[ "${EUID}" -eq 0 && -n "${SUDO_USER:-}" ]]; then
  echo "Running compose as ${OWNER_USER} in ${PROJECT_DIR}..."
  sudo -u "${OWNER_USER}" -H bash -lc "cd '${PROJECT_DIR}' && ${RUN_COMPOSE}"
else
  bash -lc "cd '${PROJECT_DIR}' && ${RUN_COMPOSE}"
fi

echo
echo "✅ Done."
echo "• KLSP via Traefik: https://${DOMAIN}"
echo "• Traefik dashboard: https://traefik.${DOMAIN}"
echo
echo "If cert issuance stalls, check: docker logs -f traefik"
