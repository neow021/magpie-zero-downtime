# Tailscale-only ingress for magpie

Nothing is published on the internet: only devices in the tailnet reach magpie, over HTTPS
with a certificate Tailscale issues for the `*.ts.net` name. Blue/green and Caddy stay the
same; only the outer entry changes.

Status: written from Tailscale's documented container and `serve` behaviour. The
Cloudflare variant of this layout runs in production; this variant has not been deployed
end to end yet. Run step 8 of SKILL.md before relying on it.

## Before you start (tailnet admin console)

1. **DNS:** MagicDNS on, and **HTTPS Certificates** enabled. Without them `serve` has no
   certificate for the `ts.net` name.
2. **A tag for the node**, e.g. `tag:magpie`, owned by the admin, and an ACL that lets in only
   the devices that should use it. Keep the UI port tighter than the API port if others call
   the API. With grants:

   ```json
   {
     "tagOwners": { "tag:magpie": ["autogroup:admin"] },
     "grants": [
       { "src": ["autogroup:admin"],  "dst": ["tag:magpie"], "ip": ["tcp:443", "tcp:8443"] },
       { "src": ["group:ai-clients"], "dst": ["tag:magpie"], "ip": ["tcp:8443"] }
     ]
   }
   ```

   Adapt it to the tailnet's existing policy file (it may still use `acls` instead of
   `grants`); add rules, do not replace the file.

## Variant A: Tailscale container (recommended)

The compose project brings its own Tailscale node, the same way the Cloudflare variant brings
its own cloudflared. The host does not need Tailscale.

1. **Auth key:** Settings → Keys → Generate auth key: not reusable, not ephemeral, tagged
   `tag:magpie`. A tagged node's key expiry is off by default, so it does not drop out after
   180 days. The key is used once; afterwards the login lives in `tailscale/state/`.
2. **Files:** `templates/compose.tailscale.yaml` next to `compose.yaml`, and
   `templates/tailscale-serve.json` as `tailscale/serve.json`. The container replaces
   `${TS_CERT_DOMAIN}` in it with its own `ts.net` name.
3. **.env:**

   ```
   COMPOSE_FILE=compose.yaml:compose.tailscale.yaml
   TS_HOSTNAME=magpie
   TS_AUTHKEY=<the key, written by the script>
   MAGPIE_WEB_URL=https://magpie.<tailnet>.ts.net
   MAGPIE_PUBLIC_URL=https://magpie.<tailnet>.ts.net:8443
   ```

   The tailnet name is shown in the admin console under DNS (e.g. `tail1234.ts.net`).
4. `$DOCKER compose up -d`. The node appears in the admin console as `magpie`. If the name is
   taken, Tailscale appends `-1`: use the name it shows in both URLs.
5. **Treat `tailscale/state/` as a secret** (it holds the node key): mode 0700, excluded from
   any backup that leaves the host.

The container runs in userspace mode (`TS_USERSPACE=true`): it needs no `/dev/net/tun` and no
extra capabilities, and `serve` still proxies to `edge` over the compose network.

## Variant B: the host's own Tailscale

When the host already runs Tailscale, skip the container. Caddy already publishes both ports
on the host's loopback (`MAGPIE_LOCAL_UI_PORT`, `MAGPIE_LOCAL_API_PORT`).

1. `.env`: `COMPOSE_FILE=compose.yaml`, and the URLs with the host's tailnet name:
   `https://<host>.<tailnet>.ts.net` and `https://<host>.<tailnet>.ts.net:8443`.
2. Check what the host already serves, so these do not replace an existing entry:
   `tailscale serve status`.
3. After `$DOCKER compose up -d`:

   ```
   sudo tailscale serve --bg --https=443  http://127.0.0.1:3430
   sudo tailscale serve --bg --https=8443 http://127.0.0.1:3425
   ```

   `--bg` keeps the configuration across reboots. `tailscale serve reset` removes it.
4. The ACL then targets the host (its tag or its address), not a separate `tag:magpie` node.

## Checks

From a device in the tailnet:
- `curl -s -o /dev/null -w '%{http_code}\n' https://magpie.<tailnet>.ts.net:8443/v1/models`:
  401 without a key, 200 with one.
- The UI URL loads the sign-in page; `<UI URL>/?k=<MAGPIE_WEB_KEY>` signs in.

From outside the tailnet the names do not resolve and the ports do not answer.

## What changes compared with Cloudflare

- No public entry and no login page to probe. There is also no Access login: the tailnet ACL
  and `MAGPIE_WEB_KEY` are what guard the UI, so keep the UI port to the owner's devices.
- No 100 s limit on non-streaming responses.
- Every client must be in the tailnet: agents on other servers need Tailscale installed, a
  phone needs the Tailscale app connected.
- Requests reach magpie through `serve` and Caddy; Caddy adds forwarding headers, so magpie
  treats them as remote and requires a gateway key. Keep `MAGPIE_TRUST_PROXY` off here too.
- Tailscale Funnel would publish the node on the internet; it is not part of this layout.
