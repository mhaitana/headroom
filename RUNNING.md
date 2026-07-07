# Running the Headroom Bedrock Proxy

This proxy sits between Claude Code and AWS Bedrock. It intercepts
`/v1/messages` requests, compresses them to reduce token usage, then
forwards to Bedrock via SigV4-signed calls. All other routes (OpenAI,
Gemini, Vertex) return 404.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account with Bedrock access | `ap-southeast-2` (au. inference profiles) by default — adjust to your region |
| `aws-sso` CLI | `brew install aws-sso-cli` or equivalent |
| Active SSO session | Your org's SSO instance and profile |
| Docker Desktop | Required — runs the proxy as a container |

> **Apple Silicon:** the image is built as `linux/amd64` and runs under
> Rosetta inside Docker Desktop. No extra configuration needed.

---

## First-time setup

### 1. Log in to AWS SSO

```bash
aws-sso login
```

This opens a browser window for SSO authentication. Complete it, then
check how long the session is valid for:

```bash
aws-sso time
```

### 2. Export credentials into your shell

AWS credentials from SSO are short-lived tokens. Export them into the
current shell so Docker Compose can inject them into the container.
Replace `<sso-profile>` with your AWS SSO profile name (the value from
`~/.config/aws-sso/config.yaml`):

```bash
eval "$(aws-sso eval --profile=<sso-profile>)"
```

Verify the export worked:

```bash
echo $AWS_ACCESS_KEY_ID   # should print a key starting with ASIA...
```

### 3. Build the image

This compiles the Rust `_core` extension and installs all Python
dependencies. Takes ~10 minutes on first run; subsequent builds use the
Docker layer cache.

```bash
cd ~/Work/headroom
docker compose -f docker-compose.bedrock.yml build
```

> **Corporate proxy note:** the build stage fetches packages directly
> (no proxy) so `apt-get` and `cargo` can reach Debian mirrors and
> crates.io. Runtime traffic (non-Bedrock) routes through
> `host.docker.internal:3128` if your environment uses a local TLS proxy.

---

## Daily start

SSO credentials expire (typically after 8–12 hours). Each session:

```bash
# 1. Log in (if session has expired — opens browser)
aws-sso login

# 2. Export fresh credentials into the shell
eval "$(aws-sso eval --profile=<sso-profile>)"

# 3. Start (or restart) the proxy
docker compose -f docker-compose.bedrock.yml up --force-recreate -d
```

Check how much time remains on the current session without re-logging in:

```bash
aws-sso time
```

Check the proxy is healthy after starting:

```bash
curl http://localhost:8787/readyz
# → {"status":"ok"}
```

---

## Stop

```bash
docker compose -f docker-compose.bedrock.yml stop
```

---

## Claude Code settings

Claude Code must be pointed at the local proxy instead of `api.anthropic.com`.
Create `.claude/settings.json` inside any project directory you want to use
with the proxy:

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "0",
    "AWS_REGION": "ap-southeast-2",
    "ANTHROPIC_BASE_URL": "http://localhost:8787",
    "ANTHROPIC_API_KEY": "headroom",
    "ANTHROPIC_MODEL": "au.anthropic.claude-opus-4-8",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "au.anthropic.claude-haiku-4-5-20251001-v1:0",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "au.anthropic.claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "au.anthropic.claude-opus-4-8"
  }
}
```

| Setting | Value | Why |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://localhost:8787` | Routes Claude Code through the proxy |
| `ANTHROPIC_API_KEY` | `headroom` | Dummy key — proxy strips it; SigV4 is used for Bedrock |
| `CLAUDE_CODE_USE_BEDROCK` | `"0"` | Disables Claude Code's native Bedrock mode; let the proxy handle routing |
| `AWS_REGION` | `ap-southeast-2` | Set to your Bedrock-enabled region |

> **Global vs project:** placing `settings.json` in `~/.claude/` applies
> it to all Claude Code sessions. Placing it in `<project>/.claude/`
> applies it only when Claude Code is launched from that directory.

### Per-project usage tracking

To track token savings per project in the dashboard, add a
`.claude/settings.local.json` alongside `settings.json` with a
project-scoped base URL:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:8787/p/<your-project-name>"
  }
}
```

The `/p/<name>` path tells the proxy which project the requests belong to.
Savings for each project appear separately in the dashboard at
`http://localhost:8787/dashboard`.

> **`settings.local.json` vs `settings.json`:** `settings.local.json` is
> gitignored by Claude Code and takes precedence over `settings.json` for
> any keys it defines. Use it for the project-scoped URL so the base URL
> override stays off version control.

---

## Verifying it works

```bash
# 1. Health check
curl http://localhost:8787/readyz
# → {"status":"ok"}

# 2. Confirm non-Bedrock routes are blocked
curl -s http://localhost:8787/v1/chat/completions | jq .
# → {"error": "This proxy is configured for AWS Bedrock only. Use /v1/messages."}

# 3. Live Bedrock request
curl -s http://localhost:8787/v1/messages \
  -H "Content-Type: application/json" \
  -H "x-api-key: headroom" \
  -d '{
    "model": "au.anthropic.claude-sonnet-4-6",
    "max_tokens": 64,
    "messages": [{"role": "user", "content": "Say hello"}]
  }' | jq .content[0].text
```

---

## Savings dashboard

The proxy tracks token savings and serves a dashboard at:

```
http://localhost:8787/dashboard
```

Stats and history are also available as JSON:

```bash
curl -s http://localhost:8787/stats | jq .
curl -s http://localhost:8787/stats-history | jq .
```

---

## Reset proxy data

Clears the savings dashboard, CCR store, and logs without rebuilding:

```bash
docker compose -f docker-compose.bedrock.yml stop

# Clear savings / CCR state
> ~/.headroom/proxy_savings.json
> ~/.headroom/savings_events.jsonl
> ~/.headroom/ccr_store.db
> ~/.headroom/ccr_store.db-shm
> ~/.headroom/ccr_store.db-wal

# Clear logs
> ~/.headroom/logs/proxy.log
> ~/.headroom/logs/proxy.log.1

# Restart
eval "$(aws-sso eval --profile=<sso-profile>)"
docker compose -f docker-compose.bedrock.yml up --force-recreate -d
```

---

## Troubleshooting

### `ExpiredTokenException` / 403 from Bedrock

SSO session has expired. Re-run the login + eval steps:

```bash
aws-sso login
eval "$(aws-sso eval --profile=<sso-profile>)"
docker compose -f docker-compose.bedrock.yml up --force-recreate -d
```

Check remaining session time without re-logging in: `aws-sso time`

### Requests still going to `api.anthropic.com`

Check that both of these are set in your project's `.claude/settings.json`:

- `ANTHROPIC_BASE_URL=http://localhost:8787` — routes requests through the proxy
- `CLAUDE_CODE_USE_BEDROCK=0` — **required**; without this Claude Code's native
  Bedrock mode is active and it calls Bedrock directly, bypassing `ANTHROPIC_BASE_URL`
  entirely

Also confirm you launched Claude Code from the directory containing the
`.claude/settings.json` (or that it's in `~/.claude/settings.json` for
global effect).

### `ResourceNotFoundException` — model not found

Use a fully qualified `au.` inference profile ID, e.g.:
`au.anthropic.claude-sonnet-4-6`

The proxy defaults to `ap-southeast-2`. If you're in a different region,
set `HEADROOM_REGION` and `AWS_REGION` to match in `docker-compose.bedrock.yml`.

### Docker build fails — `apt-get` can't reach Debian mirrors

The build stage runs without a proxy so `apt-get` goes direct. If you're
on a network that blocks direct outbound HTTP, temporarily disable the
corporate proxy or use a hotspot for the build step.

### `/readyz` returns unhealthy or hangs

The compose file sets `HEADROOM_SKIP_UPSTREAM_CHECK=1` so the proxy does
not attempt to reach `api.anthropic.com` on startup. If you've overridden
this, unset it — Bedrock deployments don't need the Anthropic health probe.

### `AWS_ACCESS_KEY_ID` is empty in the container

The credentials are injected from the host shell at `docker compose up`
time. If you start the container without running `eval "$(aws-sso eval ...)"` 
first, the env vars will be empty. Always run the `eval` step in the same
terminal session before `docker compose up`.
