# magpie zero-downtime

Run the [magpie](https://github.com/yetone/magpie) AI gateway on a Linux host with Docker
Compose so that updates and restarts drop neither requests nor long streams: two magpie
instances on one config directory (blue/green), and Caddy sending traffic to the healthy one.
Clients reach it either through a Cloudflare tunnel (public hostnames, an Access login on
the UI) or only through a Tailscale tailnet (nothing on the internet).

Start with the [skill](SKILL.md). It is written for an agent and works as a checklist for a
person. First deployment end to end: [references/getting-started.md](references/getting-started.md).

## Layout

```
SKILL.md                            ingress choice, deploy procedure, safety rules
templates/compose.yaml              magpie-blue, magpie-green, Caddy (edge)
templates/compose.cloudflare.yaml   ingress overlay: cloudflared
templates/compose.tailscale.yaml    ingress overlay: a Tailscale node
templates/tailscale-serve.json      HTTPS 443 -> UI, 8443 -> API on the Tailscale node
templates/Caddyfile.tmpl            primary/standby with authenticated health checks
templates/env.example               every variable, empty
scripts/update.sh                   zero-downtime rollout with a downgrade guard
scripts/daily-update.sh             one-line report for a scheduler
references/getting-started.md       empty host -> first client
references/cloudflare.md            tunnel, DNS, Access (copyable commands)
references/tailscale.md             tailnet-only ingress, container or host
references/updates.md               channels, rollouts, scheduling, rollback
references/operations.md            keys, clients, models, usage, backups
```

## Verification

What has run, and what has not:
- **Ran in production** (Linux ARM64, magpie v0.1.4526, Docker Compose v2, Caddy 2, Cloudflare
  ingress): during a rollout a 23k-token stream of about 57 s finished complete while the old
  primary waited 46 s for it; 121 probes at 0.5 s intervals in the same window saw no 502 and
  no timeout. `daily-update.sh` ran from a Hermes Agent no-agent cron job.
- **Checked statically:** the compose files with each overlay (`docker compose config`), the
  rendered Caddyfile (`caddy validate`), both scripts (`bash -n`).
- **Not run yet:** a deployment from scratch by following SKILL.md, the `curl` commands in
  `references/cloudflare.md`, and both Tailscale variants.

Deployment records (which host runs it, its hostnames and keys) belong in the operator's own
private notes, not in this repository.
