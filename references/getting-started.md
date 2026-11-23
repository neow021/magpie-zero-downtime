# Getting started: from an empty host to the first client

The path for someone deploying their own magpie for the first time. Deep detail lives in
SKILL.md and the other references; this page is the order to do things in.

## 0. What you need

- A Linux host (amd64 or arm64) with Docker Engine and the Compose v2 plugin, 2 GB of free
  memory and a few GB of disk. Check: `docker compose version`.
- One ingress (SKILL.md, "Choose the ingress"):
  - Cloudflare: a domain on Cloudflare with Zero Trust turned on, and an API token.
  - Tailscale: a tailnet with MagicDNS and HTTPS certificates on, and an auth key.
- At least one model account: a Claude or ChatGPT (Codex) subscription, or an API key from a
  provider magpie supports (`magpie presets` lists them).

## 1. Deploy (about 30 minutes)

Follow SKILL.md, "Deploy", steps 1 to 9. At the end you have:
- the UI URL, signed in once with `?k=<MAGPIE_WEB_KEY>`;
- the API base URL: `https://magpie-api.example.com/v1` (Cloudflare) or
  `https://magpie.<tailnet>.ts.net:8443/v1` (Tailscale);
- `./update.sh --force` proven to roll both colors.

## 2. Connect a model account

In the UI, open Providers and add one:
- **API key provider:** pick the preset, paste the key.
- **Subscription (Codex, Claude):** start the sign-in. The provider redirects the browser to
  `localhost` (Codex: `http://localhost:1455/auth/callback?...`), which fails because magpie
  runs on a server. Copy the whole URL from the address bar into the sign-in's Callback URL
  field.
- **Claude subscription:** run `docker exec magpie-$(cat /opt/magpie/primary) magpie
  claude-code install` once first.

Check from the host: `docker exec magpie-$(cat /opt/magpie/primary) magpie models` lists the
exposed model ids (`codex/gpt-…`, `claude/claude-…`, `deepseek/deepseek-…`). New models arrive
not exposed; `magpie provider models <provider> +<id>` exposes one.

## 3. Create a key for the first client

One gateway key per client, so usage can be read and revoked per client:

```
docker exec magpie-$(cat /opt/magpie/primary) magpie gateway-key add my-laptop
```

It prints the key (`sk-m…`) once. Give it a budget if the client is not yours:
`magpie gateway-key limit <id> add day --cost 5`.

## 4. Point the client at magpie

Any OpenAI-compatible client:

```
OPENAI_BASE_URL=https://magpie-api.example.com/v1
OPENAI_API_KEY=sk-m...
```

and a model id from `magpie models`. Anthropic-style clients use the same base URL without
`/v1` and the key as their API key. Agents on the magpie host itself can use
`http://127.0.0.1:3425/v1` and skip the ingress.

First call, to prove the whole path (curl sends a User-Agent, which Cloudflare requires):

```
curl -s https://magpie-api.example.com/v1/chat/completions \
  -H "Authorization: Bearer $OPENAI_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"<id from magpie models>","messages":[{"role":"user","content":"Reply with ok"}]}'
```

Hermes Agent and other clients: [operations.md](operations.md), "Pointing clients at it".

## 5. Afterwards

- See what each client spent: `magpie usage 7d`.
- Updates: run `./update.sh`, or schedule `daily-update.sh` ([updates.md](updates.md)).
- Back up before big jumps: `magpie backup` ([operations.md](operations.md), "Backups").

## When something fails

| Symptom | Likely cause |
|---|---|
| 401 on every call | missing or wrong gateway key; keys are per gateway, not per provider |
| 403 "error code: 1010" through Cloudflare | the client sends Python's default User-Agent |
| 524 through Cloudflare | a non-streaming request took over 100 s; stream it |
| Tailscale URL does not resolve | the device is not in the tailnet, or MagicDNS is off |
| a model is missing | not exposed yet, or the image is older than the model (updates.md) |
| UI asks for the key again | new browser, or an in-app browser that drops the cookie |
