This repo contains a single Bash script that bootstraps a **Traefik v3 reverse proxy** with **automatic HTTPS (Let's Encrypt)** and runs **Kiloview KiloLink Server Pro** (KLSP) behind it. It also fixes terminal line editing (backspace/arrows) for the interactive prompts.

> Tested on modern Linux distributions with Docker Engine and either the Docker Compose plugin (`docker compose`) or the legacy binary (`docker-compose`).

---

## What the script does

- Detects `docker compose` vs `docker-compose` and uses whichever exists.
- Ensures interactive prompts support backspace/arrow keys.
- Asks you a few values (domain, email, ports, image tag).
- Writes the following in your current directory:
  - `.env` — values entered at the prompts.
  - `docker-compose.yml` — services for **Traefik** and **KLSP**.
  - `traefik/acme.json` — Let's Encrypt certificate storage (0600 perms).
  - `traefik/dynamic/kls.yml` — Traefik file-provider route for KLSP.
  - `kilolink-server/` — persistent data directory for KLSP.
- Starts everything with Docker Compose.
- Prints the URLs for KLSP and the Traefik dashboard when done.

> KLSP runs with `network_mode: host` as required by the image. Traefik publishes **80/tcp** and **443/tcp** to the host for ACME and HTTPS.


---

## Prerequisites

1. **Linux host with sudo/root**.
2. **Docker Engine** installed and running.
3. **Docker Compose** — either the plugin (`docker compose`) or legacy (`docker-compose`).
4. **Public DNS** A/AAAA records:
   - `DOMAIN` → your server’s public IP (for example `www.example.com → 203.0.113.10`).
   - Optional dashboard: `traefik.DOMAIN` → same IP.
5. **Ports 80 and 443 open** on the server and any upstream firewall/security group.
6. If you’re using a CDN/proxy (e.g., Cloudflare), **disable the orange cloud** (no proxy) for initial issuance with the HTTP-01 challenge, or switch to DNS-01 (not configured by this script).

> The script can add your user to the `docker` group when run as root if Docker isn’t accessible for the owner user.


---

## Quick start

1. **Save the script** (e.g., `bootstrap.sh`) into an empty project folder.
2. Make it executable:
   ```bash
   chmod +x bootstrap.sh
   ```
3. Run it:
   ```bash
   ./bootstrap.sh
   ```
4. Answer the prompts. Typical example:
   - **Domain for KLSP (FQDN)**: `kls.example.com`
   - **Let's Encrypt email**: `admin@example.com`
   - **KLSP http local web access port (web_port)**: `83`
   - **Aggregation port(s) for KiloLink (klnl_port)**: `50000,50001`
   - **KLSP image tag**: `latest`
   - **Public IP or DDNS devices will reach**: press **Enter** to reuse the domain
5. Wait for containers to start. When complete you’ll see:
   - **KLSP via Traefik**: `https://kls.example.com`
   - **Traefik dashboard**: `https://traefik.kls.example.com` (replace with your domain)

> If certificate issuance stalls, check: `docker logs -f traefik`


---

## Prompt reference

| Prompt | What it sets | Notes |
|---|---|---|
| **Domain for KLSP** | `DOMAIN` | FQDN that points to this host. |
| **Let's Encrypt email** | `LE_EMAIL` | ACME notifications & rate-limit identity. |
| **KLSP http local web access port** | `WEB_PORT` | KLSP listens on this host port (defaults to `83`). |
| **Aggregation port(s) for KiloLink** | `KLNL_PORT` | Single port or comma list (e.g., `50000,50001`). |
| *(auto)* | `SERVER_PORT` / `STREAM_SERVER_PORT` | If you input **exactly two** klnl ports, the script maps them to these legacy variables for compatibility. |
| **KLSP image tag** | `KLS_TAG` | e.g., `latest` or a version like `vX.Y.Z`. |
| **Public IP or DDNS devices will reach** | `PUBLIC_IP` | Defaults to `DOMAIN`. Used for device dialing. |

All values are written to `.env` and expanded into `docker-compose.yml` and Traefik files.


---

## Files generated

```
.
├── .env
├── docker-compose.yml
├── kilolink-server/
└── traefik/
    ├── acme.json            (0600)
    └── dynamic/
        └── kls.yml
```

- **Traefik** performs HTTPS termination and routes `https://DOMAIN` to KLSP’s local web port via `host.docker.internal:WEB_PORT`.
- The **dashboard** is exposed at `https://traefik.DOMAIN` (no auth by default — see **Hardening**).


---

## Operating the stack

From the project directory:

- Start (already done by the script):  
  ```bash
  docker compose up -d
  ```
- View running containers:  
  ```bash
  docker compose ps
  ```
- Tail logs:  
  ```bash
  docker logs -f traefik
  docker logs -f klnksvr-pro
  ```
- Stop:
  ```bash
  docker compose down
  ```
- Update KLSP image (e.g., change tag):  
  1. Edit `.env` → `KLS_TAG=vX.Y.Z`
  2. `docker compose pull kls && docker compose up -d`


---

## Using a **custom SSL certificate** instead of Let’s Encrypt (optional)

If you already have a certificate/key for `DOMAIN` and want Traefik to use them:

1. Place your files in `traefik/certs/` (create the folder):  
   - `fullchain.pem` (certificate chain)  
   - `privkey.pem` (private key)
2. Create `traefik/dynamic/certs.yml` with:
   ```yaml
   tls:
     certificates:
       - certFile: /etc/traefik/certs/fullchain.pem
         keyFile: /etc/traefik/certs/privkey.pem
   ```
3. Mount the certs folder and the extra dynamic file by editing `docker-compose.yml` → `traefik` service:
   ```yaml
   volumes:
     - /var/run/docker.sock:/var/run/docker.sock:ro
     - ./traefik/acme.json:/acme/acme.json
     - ./traefik/dynamic:/etc/traefik/dynamic:ro
     - ./traefik/certs:/etc/traefik/certs:ro
   ```
4. (Optional) Comment out or remove the `--certificatesresolvers.le.acme.*` lines under `traefik.command` to avoid ACME entirely.
5. Apply changes:
   ```bash
   docker compose up -d
   ```

> Traefik prefers the certificate that matches the SNI. If a static `tls.certificates` entry matches your domain, it will serve that cert.


---

## Hardening tips

- **Protect the Traefik dashboard**: add Basic Auth middleware and/or IP allowlist. Example dynamic file `traefik/dynamic/dashboard.yml`:
  ```yaml
  http:
    middlewares:
      dash-auth:
        basicAuth:
          users:
            - "admin:$$apr1$$QX3...<htpasswd hash here>"
    routers:
      dashboard:
        rule: "Host(`traefik.${DOMAIN}`)"
        entryPoints: ["websecure"]
        service: "api@internal"
        tls:
          certResolver: le
        middlewares: ["dash-auth"]
  ```
  Generate a hash with `htpasswd -nb admin 'yourpassword'`.
- Consider enabling **HTTP/3/QUIC** by uncommenting the `443/udp` mapping in `docker-compose.yml`.
- Keep `traefik/acme.json` at permission `0600`.
- Restrict SSH and keep the system updated.


---

## Troubleshooting

- **ACME/Let’s Encrypt fails**  
  - DNS A/AAAA record doesn’t point to this host. Fix DNS and wait for propagation.  
  - Port **80/tcp** not reachable from the Internet. Open/firewall/NAT as required.  
  - CDN proxy is on (e.g., Cloudflare orange cloud). Turn off proxy or switch to DNS-01.
- **`ERROR: user is not in the 'docker' group`**  
  Follow the script’s printed instructions:  
  ```bash
  sudo usermod -aG docker <your-user>
  newgrp docker
  ```
- **Port already in use** (`80`/`443`/`WEB_PORT`)  
  Stop the conflicting service or change the port value before re-running.
- **Cannot reach KLSP UI through Traefik**  
  Confirm `WEB_PORT` is correct and that KLSP is listening locally, then check `traefik/dynamic/kls.yml` target URL.


---

## Uninstall / cleanup

From the project directory:
```bash
docker compose down -v
sudo rm -rf traefik kilolink-server docker-compose.yml .env
```

---

## FAQ

**Q: Does the script fix the backspace issue during prompts?**  
A: Yes. It restores a sane TTY and sets the erase character so backspace and arrow keys work in most shells/terminals.

**Q: Which ports must I open to the Internet?**  
A: TCP **80** and **443** for Traefik. Your **aggregation ports** (e.g., `50000,50001`) must also be reachable from your devices as required by KLSP.

**Q: Can I run behind NAT?**  
A: Yes, as long as the public IP/hostname you give to devices forwards the necessary ports to this host.

**Q: Can I keep using Let’s Encrypt after adding a custom cert?**  
A: You can keep ACME config present; Traefik will serve the static cert when it matches the SNI. You can also remove ACME entirely if you prefer.


---

## Support

- Check container logs first: `docker logs -f traefik` and `docker logs -f klnksvr-pro`.
- If you need to adjust behavior, edit `.env`, `docker-compose.yml`, or files in `traefik/dynamic/`, then `docker compose up -d`.
