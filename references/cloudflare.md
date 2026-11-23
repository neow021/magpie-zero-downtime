# Cloudflare tunnel and Access for magpie

## Shape

- **Two hostnames.** The UI host sits behind an Access login. The API host has no Access
  application and is guarded by magpie's gateway keys. Agent CLIs cannot do an interactive
  Access login. One hostname serving both would put the API behind the UI's login.
- **A remotely managed tunnel in the compose project.** The ingress rules live at Cloudflare,
  the host holds only the token in `.env`, and cloudflared runs as a container next to Caddy.
  It reaches Caddy by service name, so no host port is needed. Changing the ingress is an API
  call that applies at once, with no restart and no effect on other services.
- A system-wide cloudflared with a local `config.yml` also works, but every change needs root
  and a restart that interrupts every hostname on that tunnel.

## Steps

Shown with `cloudflared` and the API. Any client that can call the Cloudflare API works.

1. Create the tunnel with remote config:
   `POST /accounts/<account>/cfd_tunnel` with `{"name": "magpie", "config_src": "cloudflare"}`.
2. Set the ingress:
   `PUT /accounts/<account>/cfd_tunnel/<id>/configurations` with
   ```json
   {"config": {"ingress": [
     {"hostname": "magpie.example.com",     "service": "http://edge:3430"},
     {"hostname": "magpie-api.example.com", "service": "http://edge:3425"},
     {"service": "http_status:404"}
   ]}}
   ```
3. DNS: one proxied CNAME per hostname to `<id>.cfargotunnel.com`.
4. Access: an identity provider (the built-in one-time PIN is enough), then a `self_hosted`
   application for the UI host only, with an Allow policy that names the owner's email.
   Turning Zero Trust on for an account for the first time (team name, free plan) is a
   dashboard step.
5. Token: `GET /accounts/<account>/cfd_tunnel/<id>/token`, written straight into `.env` as
   `TUNNEL_TOKEN` by the script, never printed.

## Checks

Use `curl --doh-url https://1.1.1.1/dns-query` right after creating records: the local
resolver may still cache an earlier NXDOMAIN.

- UI host without a cookie: 302 to `<team>.cloudflareaccess.com`.
- API host without a key: magpie's own 401.
- API host with a valid key: 200 on `/v1/models`.

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
