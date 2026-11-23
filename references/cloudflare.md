# Cloudflare tunnel and Access for magpie

## Shape

- **Two hostnames.** The UI host sits behind an Access login. The API host has no Access
  application and is guarded by magpie's gateway keys. Agent CLIs cannot do an interactive
  Access login. One hostname serving both would put the API behind the UI's login.
- **Keep both one level under the zone** (`magpie.example.com`, `magpie-api.example.com`). The
  free Universal SSL certificate covers only the apex and first-level names.
- **A remotely managed tunnel in the compose project** (`compose.cloudflare.yaml`). The
  ingress rules live at Cloudflare, the host holds only the token in `.env`, and cloudflared
  runs as a container next to Caddy. It reaches Caddy by service name, so no host port is
  needed. Changing the ingress is an API call that applies at once, with no restart.
- A system-wide cloudflared with a local `config.yml` also works, but every change needs root
  and a restart that interrupts every hostname on that tunnel.

## Before you start

- The domain's DNS is on Cloudflare (full setup).
- Zero Trust is turned on for the account (dashboard → Zero Trust; pick a team name and the
  free plan). This first step has no API.
- An API token (My Profile → API Tokens → Create custom token) with:
  Account · Cloudflare Tunnel · Edit; Account · Access: Apps and Policies · Edit;
  Account · Access: Organizations, Identity Providers, and Groups · Edit; Zone · DNS · Edit
  (that zone only).

## Commands

Status: the same API calls were made through a Cloudflare CLI for the original deployment;
the `curl` form below is a transcription and has not been run as written. Run it from a
script file. It prints ids, never the token.

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${CF_API_TOKEN:?}" "${CF_ACCOUNT_ID:?}" "${CF_ZONE_ID:?}"
UI_HOST=magpie.example.com
API_HOST=magpie-api.example.com
OWNER_EMAIL=you@example.com
API=https://api.cloudflare.com/client/v4
cf() { curl -sS -H "Authorization: Bearer $CF_API_TOKEN" -H 'Content-Type: application/json' "$@"; }

# 1. tunnel with remote config
TUNNEL_ID=$(cf -X POST "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel" \
  -d '{"name":"magpie","config_src":"cloudflare"}' | jq -r '.result.id')
echo "tunnel: $TUNNEL_ID"

# 2. ingress: UI -> edge:3430, API -> edge:3425, everything else 404
cf -X PUT "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" -d "$(jq -n \
  --arg ui "$UI_HOST" --arg api "$API_HOST" '{config:{ingress:[
    {hostname:$ui,  service:"http://edge:3430"},
    {hostname:$api, service:"http://edge:3425"},
    {service:"http_status:404"}]}}')" | jq -c '{success, errors}'

# 3. DNS: proxied CNAMEs to the tunnel
for h in "$UI_HOST" "$API_HOST"; do
  cf -X POST "$API/zones/$CF_ZONE_ID/dns_records" -d "$(jq -n --arg n "$h" \
    --arg c "$TUNNEL_ID.cfargotunnel.com" '{type:"CNAME",name:$n,content:$c,proxied:true}')" \
    | jq -c '{success, errors}'
done

# 4. Access: one-time PIN login (skip if the account already has it), then the UI app only
cf -X POST "$API/accounts/$CF_ACCOUNT_ID/access/identity_providers" \
  -d '{"name":"One-time PIN","type":"onetimepin","config":{}}' | jq -c '{success, errors}'
cf -X POST "$API/accounts/$CF_ACCOUNT_ID/access/apps" -d "$(jq -n \
  --arg d "$UI_HOST" --arg e "$OWNER_EMAIL" '{name:"magpie UI",domain:$d,type:"self_hosted",
    session_duration:"24h",
    policies:[{name:"owner",decision:"allow",include:[{email:{email:$e}}]}]}')" \
  | jq -c '{success, errors}'

# 5. tunnel token straight into .env, never printed
umask 077
TOKEN=$(cf "$API/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/token" | jq -r '.result')
sed -i "s|^TUNNEL_TOKEN=.*|TUNNEL_TOKEN=$TOKEN|" /opt/magpie/.env
echo "token written (${#TOKEN} chars)"
```

`CF_ACCOUNT_ID` is on the account's overview page; `CF_ZONE_ID` on the zone's overview page.
A second Access identity provider of the same type fails harmlessly; read the error instead
of retrying.

## Checks

Use `curl --doh-url https://1.1.1.1/dns-query` right after creating records: the local
resolver may still cache an earlier NXDOMAIN.

- UI host without a cookie: 302 to `<team>.cloudflareaccess.com`.
- API host without a key: magpie's own 401.
- API host with a valid key: 200 on `/v1/models`.
- cloudflared's log: four `Registered tunnel connection` lines.

## Limits to know

- Cloudflare waits about 100 s for the origin. A non-streaming request that thinks longer
  fails with 524. Streaming (SSE) responses are not affected.
- magpie sees every tunnel client as the cloudflared container. Its own IP allowlist cannot
  tell clients apart, so restrict by IP at Cloudflare if needed.
- Requests carrying forwarding headers (`Cf-Connecting-IP`, `X-Forwarded-For`) count as
  remote and need a gateway key. That is the intended behaviour; do not turn on
  `MAGPIE_TRUST_PROXY`.
- Browser Integrity Check blocks the default `Python-urllib` User-Agent with 403 (1010).
- Access lets in only requests carrying its cookie. A page that loads can still have its own
  `fetch` calls blocked when its code sends `credentials: "omit"`: the plugin chat page does
  this and then retries forever ("connecting…"). Check each hop from inside out: the plugin
  service listens in each container, magpie's log shows the forwarded call, and a cookie-less
  curl of the exact path returns 302 at the edge.
- The UI's startup log prints its link with `MAGPIE_PUBLIC_URL` as the host. Build the UI
  link from the UI hostname yourself.
