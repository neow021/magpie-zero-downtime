#!/usr/bin/env bash
# Zero-downtime magpie update (blue/green behind Caddy). Run from the deployment directory copy.
#   ./update.sh                    pull the image in compose.yaml; if it changed, roll it out
#   ./update.sh --force            roll out even when the image did not change (restart without downtime)
#   ./update.sh --allow-downgrade  roll out even when the pulled version is older than the running one
#   ./update.sh --no-pull          use the image the local tag already points at (with --force:
#                                  recreate both colors from the current compose.yaml, no downtime)
# Steps: recreate the standby on the new image -> wait healthy -> make it primary (graceful Caddy
# reload) -> recreate the old primary, which drains requests in flight for up to MAGPIE_DRAIN.
# The primary's color is kept in ./primary. Exit 3 = refused a downgrade (nothing changed).
# DOCKER defaults to `docker`; set DOCKER="sudo -n docker" when the user is not in the docker group.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
FORCE=""; ALLOW_DOWNGRADE=""; NO_PULL=""
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1 ;;
    --no-pull) NO_PULL=1 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done
read -r -a D <<< "${DOCKER:-docker}"
dk() { "${D[@]}" "$@"; }
dc() { "${D[@]}" compose "$@"; }
ver_of_image() { dk run --rm --entrypoint /magpie "$1" --version 2>/dev/null | grep -o -E 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; }
ver_of_container() { dk exec "$1" magpie --version 2>/dev/null | grep -o -E 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1; }

P=$(cat primary 2>/dev/null || echo blue)
S=$([ "$P" = blue ] && echo green || echo blue)

health_key() { grep '^MAGPIE_HEALTH_KEY=' .env | cut -d= -f2-; }

wait_healthy() {  # $1 = color; Docker health + the gateway's GET / through the compose network
  local c="magpie-$1" st code i
  for i in $(seq 1 90); do
    st=$(dk inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo none)
    if [ "$st" = healthy ]; then
      code=$(dk exec magpie-edge wget -S -q -O /dev/null -T 3 \
        --header "Authorization: Bearer $(health_key)" "http://$c:3425/" 2>&1 | grep -o -E 'HTTP/1.1 [0-9]+' | head -1 || true)
      [ "$code" = "HTTP/1.1 200" ] && { echo "  $c healthy after ~$((i*2))s"; return 0; }
    fi
    sleep 2
  done
  echo "  $c NOT healthy (state=$st); stopping here, traffic stays on the other color" >&2
  return 1
}

set_primary() {  # $1 primary, $2 standby
  sed "s/__PRIMARY__/$1/g; s/__STANDBY__/$2/g" caddy/Caddyfile.tmpl > caddy/Caddyfile.next
  # rewrite in place (same inode) so the bind-mounted file Caddy sees changes
  cat caddy/Caddyfile.next > caddy/Caddyfile && rm -f caddy/Caddyfile.next
  dk exec magpie-edge caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
  echo "$1" > primary
  echo "  Caddy: primary=$1 standby=$2"
}

ref=$(dc config --images 2>/dev/null | grep '/magpie:' | head -1)
echo "image: $ref"
[ -n "$NO_PULL" ] || dc pull -q magpie-blue magpie-green
new=$(dk image inspect -f '{{.Id}}' "$ref")
cur_p=$(dk inspect -f '{{.Image}}' "magpie-$P" 2>/dev/null || echo none)
cur_s=$(dk inspect -f '{{.Image}}' "magpie-$S" 2>/dev/null || echo none)
if [ -z "$FORCE" ] && [ "$cur_p" = "$new" ] && [ "$cur_s" = "$new" ]; then
  echo "both colors already run this image; nothing to do (use --force to restart anyway)"
  exit 0
fi
new_v=$(ver_of_image "$ref"); run_v=$(ver_of_container "magpie-$P")
echo "version: running $run_v, pulled $new_v"
if [ -n "$new_v" ] && [ -n "$run_v" ] && [ "$new_v" != "$run_v" ] && [ -z "$ALLOW_DOWNGRADE" ] \
   && [ "$(printf '%s\n%s\n' "$run_v" "$new_v" | sort -V | head -1)" = "$new_v" ]; then
  echo "refusing to downgrade $run_v -> $new_v (use --allow-downgrade); nothing changed"
  # point the local tag back at the running image, so a plain `docker compose up -d` can't downgrade
  dk tag "$cur_p" "$ref"
  exit 3
fi

echo "1/3 recreate standby magpie-$S"
dc up -d --no-deps --force-recreate "magpie-$S" 2>&1 | grep -v -E '^\s*$' | tail -2
wait_healthy "$S"

echo "2/3 move traffic to magpie-$S"
set_primary "$S" "$P"
sleep 3

echo "3/3 recreate old primary magpie-$P (drains requests in flight, up to MAGPIE_DRAIN)"
t0=$(date +%s)
dc up -d --no-deps --force-recreate "magpie-$P" 2>&1 | grep -v -E '^\s*$' | tail -2
echo "  old magpie-$P stopped after $(( $(date +%s) - t0 ))s"
wait_healthy "$P"

for c in blue green; do
  printf '  magpie-%s: ' "$c"; dk exec "magpie-$c" magpie --version 2>/dev/null | head -1
done
echo "done: primary=$(cat primary)"
