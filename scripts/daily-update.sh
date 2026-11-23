#!/usr/bin/env bash
# Scheduled update for magpie, meant for any scheduler that posts a command's stdout
# (a Hermes no-agent cron job, a systemd timer with a notifier, plain cron + mail).
# Always prints exactly one short report and exits 0, so the report is the only message.
# Full output is appended to logs/daily-update.log next to this script.
# DOCKER defaults to `docker`; set DOCKER="sudo -n docker" when the user is not in the docker group.
set -uo pipefail
DIR="$(dirname "$(readlink -f "$0")")"
cd "$DIR" || { echo "magpie update: cannot enter $DIR"; exit 0; }
mkdir -p logs
LOG="$DIR/logs/daily-update.log"
echo "=== $(date -u '+%Y-%m-%d %H:%M UTC')" >> "$LOG"
read -r -a D <<< "${DOCKER:-docker}"
dk() { "${D[@]}" "$@"; }

ver_of_image() { dk run --rm --entrypoint /magpie "$1" --version 2>/dev/null | grep -o -E 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
ver_of_container() { dk exec "$1" magpie --version 2>/dev/null | grep -o -E 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

P=$(cat primary 2>/dev/null || echo blue)
ref=$(dk compose config --images 2>>"$LOG" | grep '/magpie:' | head -1)
cur=$(ver_of_container "magpie-$P")
tag=${ref##*:}

if ! dk pull -q "$ref" >>"$LOG" 2>&1; then
  echo "magpie update ($tag): image pull failed; nothing changed, running ${cur:-unknown} (primary $P). Log: $LOG"
  exit 0
fi
new=$(ver_of_image "$ref")
echo "running=$cur pulled=$new ref=$ref" >> "$LOG"

if [ -z "$new" ] || [ -z "$cur" ]; then
  echo "magpie update ($tag): could not read versions (running=${cur:-?}, pulled=${new:-?}); skipped, nothing changed. Log: $LOG"
  exit 0
fi
if [ "$new" = "$cur" ]; then
  echo "magpie update ($tag): no new version today, running $cur (primary $P)."
  exit 0
fi
if [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | head -1)" = "$new" ]; then
  # point the local tag back at the running image, so a plain `docker compose up -d` can't downgrade
  dk tag "$(dk inspect -f '{{.Image}}' "magpie-$P")" "$ref" >>"$LOG" 2>&1
  echo "magpie update ($tag): the $tag channel is at $new, older than the running $cur; skipped, nothing changed."
  exit 0
fi

t0=$(date +%s)
./update.sh >> "$LOG" 2>&1
rc=$?
secs=$(( $(date +%s) - t0 ))
P2=$(cat primary 2>/dev/null || echo "?")
vb=$(ver_of_container magpie-blue); vg=$(ver_of_container magpie-green)
if [ $rc -eq 0 ] && [ "$vb" = "$new" ] && [ "$vg" = "$new" ]; then
  echo "magpie update ($tag): $cur -> $new without downtime in ${secs}s (primary $P2)."
else
  echo "magpie update ($tag): update to $new failed (exit $rc, ${secs}s). Primary is $P2; blue=${vb:-stopped} green=${vg:-stopped}. Log: $LOG"
  echo "Last lines:"
  tail -4 "$LOG" | cut -c1-160
fi
exit 0
