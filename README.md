# magpie deployer, always online

Run the [magpie](https://github.com/yetone/magpie) AI gateway on a Linux host with Docker
Compose so that updates and restarts drop neither requests nor long streams: two magpie
instances on one config directory, Caddy choosing the healthy one, a remotely managed
Cloudflare tunnel in front, and an Access login on the web UI.

Start with the [skill](SKILL.md). It is written for an agent and works as a checklist for a
person. Updates and scheduled updates: [references/updates.md](references/updates.md). Gateway
keys, clients, usage: [references/operations.md](references/operations.md). Tunnel and Access:
[references/cloudflare.md](references/cloudflare.md).

## Layout

```
SKILL.md                    deploy procedure and safety rules
templates/compose.yaml      magpie-blue, magpie-green, Caddy (edge), cloudflared
templates/Caddyfile.tmpl    primary/standby with authenticated health checks
templates/env.example       every variable, empty
scripts/update.sh           zero-downtime rollout with a downgrade guard
scripts/daily-update.sh     one-line report for a scheduler
references/                 updates, operations, Cloudflare
```

## Verification

Exercised on Linux ARM64 with magpie v0.1.4526, Docker Compose v2 and Caddy 2. During a
rollout a 23k-token stream of about 57 s finished complete while the old primary waited 46 s
for it; 121 probes at 0.5 s intervals in the same window saw no 502 and no timeout. The
scheduled script was run by a Hermes Agent no-agent cron job and reported the
"channel older than running" case. The Cloudflare steps were run against one account with a
free Zero Trust plan.

Deployment records (which host runs it, its hostnames and keys) belong in the operator's own
private notes, not in this repository.
