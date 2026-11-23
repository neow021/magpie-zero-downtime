# Running magpie day to day

Run commands in the current primary: `docker exec magpie-$(cat /opt/magpie/primary) magpie …`.
Each command also prints a `plugin: host starts` line; filter it out.

## Gateway keys: one per client

Every caller outside the container needs a gateway key, the host itself included: the
published loopback port is outside the container too.

- Create: `magpie gateway-key add <client-name>` prints only the key (`sk-m…`). Capture it in a
  script into a 0600 file or straight into the client's secret store.
- Read-only key: `--read-only`. It reads quotas and usage and uses no model (the Caddy health
  key is one).
- Limits: `magpie gateway-key limit <id> add day --cost 10` (also `--tokens`, `week`, `month`,
  `--model openai/*`). Model list: `gateway-key models <id> <provider>/<model> …`. Accounts:
  `gateway-key accounts <id> …`. Concurrency: `gateway-key concurrency <id> <n>`.
- A key that expires by itself, for tests: `magpie gateway-key issue --ttl 5m`.
- One key per client makes usage per client readable and lets you revoke one client alone.
  Keys cannot be renamed; rotate with `gateway-key rotate <id>`.

## Pointing clients at it

Two endpoints, choose by where the client runs:
- On the same host: `http://127.0.0.1:3425/v1` (the optional loopback port on Caddy). No trip
  through Cloudflare.
- Anywhere else: `https://magpie-api.example.com/v1` (Cloudflare) or
  `https://magpie.<tailnet>.ts.net:8443/v1` (Tailscale, from a device in the tailnet).

magpie serves `/v1/chat/completions`, `/v1/responses` and the Anthropic `/v1/messages` shape.
Model ids carry the provider: `codex/gpt-…`, `claude/claude-…`, `deepseek/deepseek-…`.
`magpie models` lists what is exposed.

Hermes Agent, as a named provider (host profile):

```
hermes config set providers.magpie.name magpie
hermes config set providers.magpie.api http://127.0.0.1:3425/v1
hermes config set providers.magpie.key_env MAGPIE_API_KEY
hermes config set providers.magpie.transport codex_responses   # openai_chat for deepseek, anthropic_messages for claude
hermes config set providers.magpie.default_model codex/gpt-…
hermes config set model.provider magpie
hermes config set model.default codex/gpt-…
```

Put `MAGPIE_API_KEY=` in the profile's `.env`. A profile that used an inline custom endpoint
before also needs `hermes config unset model.api_key`. Prove it with one-shot chat that calls
a tool, then check the call in `magpie usage`.

An OpenAI-compatible client that only takes a base URL and a key (`OPENAI_BASE_URL`,
`OPENAI_API_KEY`) works the same way.

## Providers and models

- `magpie providers`: accounts and "N of M models" per provider.
- `magpie accounts`, `magpie models` (with "not exposed" lists and why),
  `magpie provider refresh codex`.
- New models arrive not exposed: `magpie provider models codex +<id>`.
- "Why is model X of my subscription missing": the vendor's list is filtered by the client
  version magpie sends, so an old image hides new models. Compare `magpie --version` with the
  release notes before suspecting the account.
- Subscription sign-ins redirect the browser to `localhost` (Codex: `:1455/auth/callback`),
  which fails on a remote server. Paste the whole callback URL into the sign-in's Callback URL
  field. A Claude subscription needs `magpie claude-code install` in the container.

## Usage and cost

- `magpie usage [today|7d|30d|all]`: tokens and cost per agent, model and account.
- `magpie usage --csv --last 30m`: every request, with `caller_key_name`, `model`,
  `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`, `cost_usd`,
  `status`. Sum it with a script; report tokens next to cost.
- `cost_usd` is magpie's list-price estimate. Requests served by a subscription are not billed
  per token.

## UI access

- The first visit per browser needs `?k=<MAGPIE_WEB_KEY>`. The cookie lasts 400 days.
- Log line when a browser has no cookie: `turned away / … no cookie sent`.
- If people are turned away after a restart, check that the running container's key still
  equals `.env`: compare in a script and print only lengths and `same=yes|no`.

## Backups

`magpie backup [--no-keys] [file]` seals providers, keys, settings and usage history with a
passphrase; `magpie restore <file>` brings them back and merges usage. A tar of `config/`
(mode 600) is the quick copy before an update.
