---
name: magpie-zero-downtime
description: Deploy and update a magpie AI gateway on Docker without downtime.
---

# magpie on Docker Compose with zero-downtime updates

[magpie](https://github.com/yetone/magpie) is an AI model gateway: one OpenAI- and
Anthropic-compatible endpoint in front of subscription logins and API keys. This skill runs it
on a Linux host as two instances (blue and green) behind Caddy, so updates and restarts drop
neither requests nor long streams. Clients reach it through a Cloudflare tunnel or only
through a Tailscale tailnet; the owner picks one.

```
client -> ingress (Cloudflare tunnel | Tailscale) -> Caddy (edge)
       -> magpie-<primary>   (magpie-<standby> is a hot spare on the same ./config)
```

- First deployment, from Docker to a working client: this file, then
  [references/getting-started.md](references/getting-started.md).
- Ingress details: [references/cloudflare.md](references/cloudflare.md),
  [references/tailscale.md](references/tailscale.md).
- Updates and scheduled updates: [references/updates.md](references/updates.md).
- Gateway keys, clients, usage, backups: [references/operations.md](references/operations.md).

## Inspect first

Read-only requests end after inspection. Before deploying, check `docker compose version`
(v2), `uname -m` (the image ships amd64 and arm64), `free -h`, `df -h /`, `docker ps -a` and
whether `/opt/magpie` already exists. Preserve an existing deployment and its `.env`; report
secrets by presence only, never by value. The container names are fixed (`magpie-blue`,
`magpie-green`, `magpie-edge`), so one host runs one deployment.

magpie must be v0.1.4526 or later. Earlier versions do not lock a shared config directory, and
two instances writing one `./config` corrupt it. Check a channel before deploying:
`curl -s 'https://usemagpie.ai/api/latest?channel=daily' | jq -r .version`. Moving an older
single container to this layout starts with a plain recreate.

## Choose the ingress

| | Cloudflare tunnel | Tailscale container | Host `tailscale serve` |
|---|---|---|---|
| Who can reach it | anyone on the internet, UI behind an Access login | devices in the tailnet | devices in the tailnet |
| Addresses | `https://magpie.example.com` (UI), `https://magpie-api.example.com` (API) | `https://magpie.<tailnet>.ts.net` (UI), `…:8443` (API) | the host's name, same two ports |
| Needs | a domain on Cloudflare, Zero Trust on, an API token | a Tailscale auth key | Tailscale already on the host |
| Clients | anything with internet | each client in the tailnet | each client in the tailnet |
| Request time limit | about 100 s for non-streaming responses | none | none |
| Compose overlay (`COMPOSE_FILE` in `.env`) | `compose.yaml:compose.cloudflare.yaml` | `compose.yaml:compose.tailscale.yaml` | `compose.yaml` |

Pick Cloudflare when clients run outside any tailnet (hosted CI, colleagues' machines, a phone
without the Tailscale app). Pick Tailscale when every client can join the tailnet and nothing
should face the internet. The container variant works on any host; the host variant is the
shortcut when the host already runs Tailscale.

## Deploy

Run every step from a script file, not from a chain of inline commands, and never print a
key. `DOCKER` below is `docker`, or `sudo -n docker` when the user is not in the docker group.

1. **Layout.** Create `/opt/magpie/` and copy into it: `templates/compose.yaml`, the chosen
   overlay, `templates/Caddyfile.tmpl` as `caddy/Caddyfile.tmpl`, `scripts/update.sh` and
   `scripts/daily-update.sh` (executable). Create `config/` owned by uid 65532, the image's user.
   Tailscale container only: also `tailscale/state/` and `templates/tailscale-serve.json` as
   `tailscale/serve.json`.
2. **Secrets.** Under `umask 077`, create `.env` from `templates/env.example` only if it does
   not exist yet. Keep one `COMPOSE_FILE` line, fill `MAGPIE_WEB_KEY` with
   `openssl rand -hex 16` and the two URLs of the chosen ingress.
3. **First instance.** `$DOCKER compose up -d magpie-blue` and wait until
   `$DOCKER inspect -f '{{.State.Health.Status}}' magpie-blue` reads `healthy`.
4. **Health key.** `$DOCKER exec magpie-blue magpie gateway-key add edge-healthcheck
   --read-only` prints the key (`sk-m…`) after a `plugin: host starts` line. Keep only the
   `sk-m` token (`grep -oE 'sk-m[A-Za-z0-9_-]+'`) and write it into `.env` as
   `MAGPIE_HEALTH_KEY`. A read-only key reads status and spends nothing.
5. **Edge.** Render the Caddyfile once with blue as primary:
   `sed 's/__PRIMARY__/blue/g; s/__STANDBY__/green/g' caddy/Caddyfile.tmpl > caddy/Caddyfile`,
   then `echo blue > primary`.
6. **Ingress.**
   - Cloudflare: create the tunnel, its ingress, DNS and the Access application, and write
     `TUNNEL_TOKEN` ([references/cloudflare.md](references/cloudflare.md)).
   - Tailscale container: create a tagged auth key and the ACL, and write `TS_AUTHKEY`
     ([references/tailscale.md](references/tailscale.md)).
   - Host `tailscale serve`: run the two `tailscale serve` commands after step 7
     ([references/tailscale.md](references/tailscale.md)).
7. **Start everything.** `$DOCKER compose up -d`. cloudflared logs four
   `Registered tunnel connection` lines; the Tailscale container shows up in the admin console
   under `TS_HOSTNAME`.
8. **Verify** from a script, with a short-lived key that expires by itself
   (`magpie gateway-key issue --ttl 5m`), captured into a variable and never printed:
   - The API URL answers `GET /v1/models` with 200 with that key and 401 with a wrong one.
   - Cloudflare: the UI host answers 302 to `<team>.cloudflareaccess.com` without a cookie.
     Tailscale: the UI URL answers from a tailnet device and times out from outside it.
   - `./update.sh --force` completes with `done: primary=green`, and both colors report the
     same version.
   - Through Cloudflare, test clients must send a User-Agent: Browser Integrity Check answers
     the default `Python-urllib/3.x` agent with 403 "error code: 1010" before magpie sees it.
9. **Hand over the UI link.** The first visit needs `<UI URL>/?k=<MAGPIE_WEB_KEY>`. It trades
   the key for a cookie kept 400 days per browser. Send it through a private channel only, and
   ask the owner to open it in the system browser: some in-app browsers do not keep the cookie.
10. **Connect accounts and the first client**:
    [references/getting-started.md](references/getting-started.md).
11. **Schedule updates** (optional): [references/updates.md](references/updates.md).

## Rules that keep it safe

- Anyone holding the UI key can change providers and read every gateway key. The UI stays
  behind an Access login or inside the tailnet, and the tailnet ACL lets in only the owner's
  devices on the UI port.
- Never set `MAGPIE_TRUST_PROXY=1`: requests through any proxy would then count as local, and
  local requests need no gateway key.
- Publish ports only on `127.0.0.1`. The ingress is the only way in from outside the host.
- Change the image or restart through `./update.sh`, not `docker compose up -d`: compose may
  recreate both colors at once.
- An agent whose own model runs through this magpie must start `update.sh` in the
  background and check the result in a later turn. In the foreground the update drains the
  old primary, which holds the agent's open request, which waits for the update: the drain
  runs into `MAGPIE_DRAIN` and the agent's turn is cut.

## Files

- `templates/compose.yaml`: the two colors and Caddy. Every value comes from `.env`.
- `templates/compose.cloudflare.yaml`, `templates/compose.tailscale.yaml`: ingress overlays.
- `templates/tailscale-serve.json`: what the Tailscale container serves on 443 and 8443.
- `templates/Caddyfile.tmpl`: `lb_policy first` with authenticated health checks.
- `templates/env.example`: every variable, all of them empty or placeholders.
- `scripts/update.sh`: zero-downtime rollout with a downgrade guard.
- `scripts/daily-update.sh`: one-line report for a scheduler.
