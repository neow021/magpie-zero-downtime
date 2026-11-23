# Updating magpie without downtime

## Why blue/green

`docker compose up -d` stops the old container before it starts the new one. During those
seconds the tunnel answers 502, and streams still running past the SIGTERM grace are cut. For
an LLM gateway the cut streams are the bigger loss: one agent turn can stream for minutes,
agent CLIs retry a short gap, and nothing retries a cut stream.

| Level | How | Cost |
|---|---|---|
| 0 | plain recreate (also what Watchtower-style updaters do) | a gap of seconds, long streams cut |
| 1 | wait for zero requests in flight, then recreate | only the short gap remains |
| 2 | this layout: a second instance on the same data, health-checked proxy, long drain | needs magpie v0.1.4526+ |

Level 2 rests on two magpie features: two instances may share `/config` (a
`gateway.serving.lock` appears in `config/magpie/`), and SIGTERM drains for `MAGPIE_DRAIN`
seconds (default 7 outside Kubernetes). Raise compose `stop_grace_period` with it, or Docker
kills the drain.

## Running an update

```
cd /opt/magpie && ./update.sh
```

1. Pulls the image named in `compose.yaml`. When both colors already run it, it stops.
2. Refuses a downgrade (exit 3) and points the local tag back at the running image, so a
   later plain `docker compose up -d` cannot downgrade either. `--allow-downgrade` overrides.
3. Recreates the standby, waits until Docker reports it healthy and the gateway answers 200
   with the health key, reloads Caddy with the standby as primary, then recreates the old
   primary, which finishes its streams first (up to `MAGPIE_DRAIN`).

If the new instance never turns healthy, the script stops at step 1 and traffic stays on the
old one. A new version that starts but has a functional bug still goes live: a channel tag only
promises that upstream CI passed.

`./update.sh --force` restarts both colors without downtime. With `--no-pull` it also
re-creates them from an edited `compose.yaml` (new environment, new image ref already pulled).

Measured on the original deployment (Linux ARM64): a 23k-token stream (about 57 s) ran across
the whole rollout; the old primary waited 46 s for it before exiting, and the stream ended
complete. Probes every 0.5 s during the rollout (121 requests) saw no 502 and no timeout.

## Channels and versions

Image `ghcr.io/yetone/magpie`, tags:
- `latest`: several releases a day.
- `daily`: meant as once a day after CI. It can sit still for days while versioned tags keep
  coming.
- `stable`: weekly. It can hide new models: the Codex model list is filtered by the client
  version magpie sends, so an older image shows fewer models.
- `0.1.NNNN`: one per release, for pinning.

Current version of a channel: `curl -s 'https://usemagpie.ai/api/latest?channel=daily' | jq -r .version`.

A stalled channel looks healthy: with the downgrade guard, every scheduled run reports
"channel older than running, skipped" and nothing ever updates. When that message repeats,
compare the channel with the running version and with `latest`, then either follow `latest`
or pin a version (`MAGPIE_IMAGE=ghcr.io/yetone/magpie:0.1.NNNN` in `.env`) and move back to the
channel once it catches up.

Registry check without pulling (anonymous ghcr), from a script file:

```
TOK=$(curl -s 'https://ghcr.io/token?scope=repository:yetone/magpie:pull' | jq -r .token)
curl -sI -H "Authorization: Bearer $TOK" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  https://ghcr.io/v2/yetone/magpie/manifests/<tag>
```

200 or 404 tells whether a version tag exists. Equal `docker-content-digest` values tell which
version `daily` or `latest` points at. `tags/list` returns at most 1000 tags in lexical order,
so the newest versions never show up there: probe candidate version tags in a loop instead.

## What an update can change for clients

Newer versions expose only the newest model of each family, so an update can swap the exposed
set by itself. Save `magpie models` before an update, diff the lines after it, and tell client
owners which model ids they must change. `magpie provider models codex +<id>` exposes an older
model again.

Read the release notes between the two versions before a big jump
(`gh api 'repos/yetone/magpie/releases?per_page=60'`, grep the bodies for
`breaking|deprecat|removed|rename|migrat`).

## Scheduled updates

`scripts/daily-update.sh` pulls, compares versions, runs `update.sh` when there is something
newer and prints exactly one line, so any scheduler that forwards stdout can report it:

- `magpie update (daily): no new version today, running v0.1.NNNN (primary blue).`
- `... the daily channel is at vA, older than the running vB; skipped, nothing changed.`
- `... vA -> vB without downtime in 84s (primary green).`
- On failure: which color serves now, both versions, and the last lines of the log.

It always exits 0. The full output goes to `logs/daily-update.log`. Schedule it about 30
minutes after the channel normally publishes (`daily` lands around 20:00 UTC).

Examples:
- **Hermes Agent** no-agent cron job (runs a script, posts its stdout, spends no model tokens):
  put a launcher in `$HERMES_HOME/scripts/magpie-daily-update.sh` containing
  `exec /opt/magpie/daily-update.sh`, then create a job with `script:
  magpie-daily-update.sh`, `no_agent: true`, the schedule and the chat to deliver to. It runs
  only while the Hermes gateway runs.
- **systemd timer**: a oneshot service that runs the script and pipes the line to a notifier.

## Rollback

`update.sh` keeps no extra copy of the image. Before a risky jump, tag the running image
(`docker tag <image id> ghcr.io/yetone/magpie:rollback-<version>`) and tar `config/` (then
`chmod 600` the tar: `sudo tar` ignores the caller's umask). To roll back, set `MAGPIE_IMAGE`
to the rollback tag and run `./update.sh --allow-downgrade --no-pull`.
