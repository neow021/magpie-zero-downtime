---
name: magpie-deployer-always-online
description: Deploy and update a magpie AI gateway on Docker without downtime.
---

# magpie on Docker Compose, always online

[magpie](https://github.com/yetone/magpie) is an AI model gateway: one OpenAI- and
Anthropic-compatible endpoint in front of subscription logins and API keys. This skill runs it
on a Linux host as two instances (blue and green) behind Caddy, reached through a remotely
managed Cloudflare tunnel, so updates and restarts drop neither requests nor long streams.

```
client -> Cloudflare (Access on the UI host) -> cloudflared -> Caddy (edge)
       -> magpie-<primary>   (magpie-<standby> is a hot spare on the same ./config)
```

For an update, go to [references/updates.md](references/updates.md). For gateway keys,
clients and usage, go to [references/operations.md](references/operations.md). For the
tunnel and the login in front of the UI, go to [references/cloudflare.md](references/cloudflare.md).

## Inspect first

Read-only requests end after inspection. Before deploying, check `docker compose version`,
`uname -m` (the image ships amd64 and arm64), `free -h`, `df -h /`, `docker ps -a` and
whether `/opt/magpie` already exists. Preserve an existing deployment and its `.env`; report
secrets by presence only, never by value.

Requirements:
- magpie v0.1.4526 or later. Earlier versions do not lock a shared config directory, and two
  instances writing one `./config` corrupt it. From an older single container, the first move
  to this layout is a plain recreate.
- A Cloudflare zone for two hostnames one level under the zone (`magpie.example.com` for the
  UI, `magpie-api.example.com` for the gateway). Deeper names are not covered by the free
  Universal SSL certificate.
- An API token or a `cloudflared` login that can create tunnels, DNS records and Access
  applications in that account.

## Deploy

Run every step from a script file, not from a chain of inline commands, and never print a
key. `DOCKER` below is `docker`, or `sudo -n docker` when the user is not in the docker group.

1. **Layout.** `/opt/magpie/` holds `compose.yaml`, `.env` (mode 0600), `caddy/Caddyfile.tmpl`,
   `update.sh`, `daily-update.sh`, `primary` and `config/`. Copy the files from `templates/`
   and `scripts/`, and make the scripts executable. `config/` is owned by uid 65532, the
   image's user.
2. **Secrets.** Under `umask 077`, create `.env` from `templates/env.example` only if it does
   not exist yet. Fill `MAGPIE_WEB_KEY` with `openssl rand -hex 16` and the two public URLs.
3. **First instance.** `$DOCKER compose up -d magpie-blue` and wait until
   `docker inspect -f '{{.State.Health.Status}}' magpie-blue` reads `healthy`.
4. **Health key.** `$DOCKER exec magpie-blue magpie gateway-key add edge-healthcheck
   --read-only` prints only the key. Capture it inside the script into `MAGPIE_HEALTH_KEY` in
   `.env`. A read-only key can read status and spends nothing.
5. **Edge.** Render the Caddyfile once with blue as primary:
   `sed 's/__PRIMARY__/blue/g; s/__STANDBY__/green/g' caddy/Caddyfile.tmpl > caddy/Caddyfile`,
   then `echo blue > primary`.
6. **Tunnel.** Create the tunnel, its ingress (`http://edge:3430` for the UI host,
   `http://edge:3425` for the API host), the DNS records and the Access application on the
   UI host, and put the tunnel token into `.env` as `TUNNEL_TOKEN`
   ([references/cloudflare.md](references/cloudflare.md)).
7. **Start everything.** `$DOCKER compose up -d`. cloudflared logs four
   `Registered tunnel connection` lines.
8. **Verify** from a script, with a short-lived key that expires by itself
   (`magpie gateway-key issue --ttl 5m`), captured into a variable and never printed:
   - The API host answers `GET /v1/models` with 200 with that key and 401 with a wrong one.
   - The UI host answers 302 to `<team>.cloudflareaccess.com` without a cookie.
   - `./update.sh --force` completes with `done: primary=green`, and both colors report the
     same version.
   - Test clients must send a User-Agent: Cloudflare's Browser Integrity Check answers the
     default `Python-urllib/3.x` agent with 403 "error code: 1010" before magpie sees it.
     curl, `python-requests` and the OpenAI SDK pass.
9. **Hand over the UI link.** The first visit needs `<UI URL>/?k=<MAGPIE_WEB_KEY>`. It trades
   the key for a cookie kept 400 days per browser. Send it through a private channel only, and
   ask the owner to open it in the system browser: some in-app browsers do not keep the cookie.
10. **Schedule updates** (optional): [references/updates.md](references/updates.md).

## Rules that keep it safe

- Anyone holding the UI key can change providers and read every gateway key. The UI stays
  behind an Access login, a VPN or loopback.
- Never set `MAGPIE_TRUST_PROXY=1` while the API host is public: forwarded requests then
  count as local, and local requests need no gateway key.
- Publish ports only on `127.0.0.1`. The tunnel is the public way in.
- Change the image or restart through `./update.sh`, not `docker compose up -d`: compose may
  recreate both colors at once.
- An agent whose own model runs through this magpie must start `update.sh` in the
  background and check the result in a later turn. In the foreground the update drains the
  old primary, which holds the agent's open request, which waits for the update: the drain
  runs into `MAGPIE_DRAIN` and the agent's turn is cut.

## Files

- `templates/compose.yaml`: the two colors, Caddy and cloudflared. Every value comes from `.env`.
- `templates/Caddyfile.tmpl`: `lb_policy first` with authenticated health checks.
- `templates/env.example`: every variable, all of them empty or placeholders.
- `scripts/update.sh`: zero-downtime rollout with a downgrade guard.
- `scripts/daily-update.sh`: one-line report for a scheduler.
