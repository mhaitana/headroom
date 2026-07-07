# Running the Headroom Bedrock Proxy

This proxy sits between Claude Code and AWS Bedrock. It intercepts
`/v1/messages` requests, compresses them to reduce token usage, then
forwards to Bedrock via SigV4-signed calls. All other routes (OpenAI,
Gemini, Vertex) return 404.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| AWS account with Bedrock access | `ap-southeast-2` (au. inference profiles) by default |
| `aws-sso` CLI | `brew install aws-sso-cli` |
| Active SSO session | `dg-productivity-prod:claude-common` |
| Docker Desktop | Required for options 1 & 2 |
| Python 3.11+ + Rust 1.95+ | Required for option 3 (local) |

---

## Option 1 — Docker Compose (recommended)

The `docker-compose.bedrock.yml` file handles the full build-and-run
lifecycle. AWS credentials are injected from your host shell so the
macOS SSO credential chain works without baking keys into the image.

### First-time setup

```bash
cd ~/Work/headroom

# 1. Authenticate with SSO and export credentials into the shell
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)"

# 2. Build the image (compiles the Rust _core extension — ~5–10 min first run)
docker compose -f docker-compose.bedrock.yml build
```

### Daily start

Temporary SSO credentials expire. Repeat this command each session:

```bash
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)" && \
  docker compose -f docker-compose.bedrock.yml up --force-recreate -d
```

Or without the `-d` flag to keep logs in the foreground:

```bash
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)" && \
  docker compose -f docker-compose.bedrock.yml up --force-recreate
```

### Stop

```bash
docker compose -f docker-compose.bedrock.yml stop
```

### Reset proxy data (logs, savings dashboard, CCR store)

```bash
docker compose -f docker-compose.bedrock.yml stop
> ~/.headroom/proxy_savings.json
> ~/.headroom/savings_events.jsonl
> ~/.headroom/ccr_store.db
> ~/.headroom/ccr_store.db-shm
> ~/.headroom/ccr_store.db-wal
> ~/.headroom/logs/proxy.log
> ~/.headroom/logs/proxy.log.1
# then restart with the daily start command above
```

---

## Option 2 — Docker build + run (manual)

Use this when you want full control over the image tag or runtime flags.

```bash
cd ~/Work/headroom

# Build
docker build -t headroom-bedrock .

# Run — injecting live SSO credentials from the host shell
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)"

docker run --rm -p 8787:8787 \
  -e AWS_REGION=ap-southeast-2 \
  -e HEADROOM_REGION=ap-southeast-2 \
  -e HEADROOM_BEDROCK_REGION=ap-southeast-2 \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  -e AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
  headroom-bedrock
```

> **Note:** `HEADROOM_REGION` and `HEADROOM_BEDROCK_REGION` must match
> `AWS_REGION`. The proxy CLI reads `HEADROOM_REGION` for its region
> default — without it the region falls back to `us-west-2` and models
> resolve to `us.` inference profiles instead of `au.`.

---

## Option 3 — Run locally (no Docker)

Requires Rust 1.95+ (for building `_core`) and Python 3.11+.

```bash
cd ~/Work/headroom

# Install with Bedrock proxy extras (builds the Rust extension via maturin)
pip install -e ".[proxy,code,bedrock]"

# Authenticate
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)"

# Run
HEADROOM_REGION=ap-southeast-2 \
HEADROOM_BEDROCK_REGION=ap-southeast-2 \
headroom proxy --host 0.0.0.0 --port 8787
```

---

## .env file

The `.env` file in the repo root is read automatically by Docker Compose.
It sets storage backend, DynamoDB config, and the Bedrock AWS profile.
The file is **not** committed with credentials — it is a template.

Key variables to set for the Bedrock proxy:

```bash
# ~/.headroom storage (default) or DynamoDB for shared/multi-user deploys
HEADROOM_STORAGE_BACKEND=file

# AWS profile for Bedrock — used by docker-compose.bedrock.yml
AWS_REGION=ap-southeast-2
AWS_PROFILE=dg-productivity-prod:claude-common

# These are set by the compose file so Claude Code clients
# know where to send requests
ANTHROPIC_BASE_URL=http://localhost:8787
ANTHROPIC_API_KEY=headroom

# Model aliases (mapped to au. Bedrock inference profiles)
ANTHROPIC_MODEL=opusplan
ANTHROPIC_DEFAULT_HAIKU_MODEL=au.anthropic.claude-haiku-4-5-20251001-v1:0
ANTHROPIC_DEFAULT_SONNET_MODEL=au.anthropic.claude-sonnet-4-6
ANTHROPIC_DEFAULT_OPUS_MODEL=au.anthropic.claude-opus-4-8
```

> **AWS credentials are NOT stored in `.env`** — they are injected at
> runtime from the host shell via `aws-sso eval`. The compose file
> references `${AWS_ACCESS_KEY_ID}` etc. which must be present in the
> shell environment when you run `docker compose up`.

---

## Claude Code settings

Claude Code must be pointed at the local proxy instead of `api.anthropic.com`.
The settings file at `~/Work/temp/.claude/settings.json` is already
configured. To apply the same setup to any other project directory,
create `.claude/settings.json` inside that directory:

```json
{
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "0",
    "AWS_REGION": "ap-southeast-2",
    "AWS_PROFILE": "dg-productivity-prod:claude-common",
    "ANTHROPIC_BASE_URL": "http://localhost:8787",
    "ANTHROPIC_API_KEY": "headroom",
    "ANTHROPIC_MODEL": "opusplan",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "au.anthropic.claude-haiku-4-5-20251001-v1:0",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "au.anthropic.claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "au.anthropic.claude-opus-4-8"
  },
  "model": "opusplan"
}
```

Key settings explained:

| Setting | Value | Why |
|---|---|---|
| `ANTHROPIC_BASE_URL` | `http://localhost:8787` | Routes Claude Code through the proxy instead of Anthropic directly |
| `ANTHROPIC_API_KEY` | `headroom` | Dummy key — the proxy strips it before forwarding to Bedrock (SigV4 is used instead) |
| `CLAUDE_CODE_USE_BEDROCK` | `"0"` | Disables Claude Code's native Bedrock mode; let the proxy handle routing |
| `ANTHROPIC_MODEL` | `opusplan` | Alias resolved by Bedrock to the au. Opus inference profile |

> **Global vs project settings:** placing `settings.json` in
> `~/.claude/` applies it globally to all Claude Code sessions.
> Placing it in `<project>/.claude/` applies it only when Claude Code
> is launched from that directory.

---

## Verifying it works

```bash
# 1. Health check
curl http://localhost:8787/readyz
# → {"status":"ok"}

# 2. Confirm non-Bedrock routes are closed
curl -s http://localhost:8787/v1/chat/completions | jq .
# → {"error": "This proxy is configured for AWS Bedrock only..."}

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

## Troubleshooting

**`ExpiredTokenException` / 403 from Bedrock**
SSO session has expired. Re-run:
```bash
eval "$(aws-sso eval --profile=dg-productivity-prod:claude-common)"
docker compose -f docker-compose.bedrock.yml up --force-recreate -d
```

**Requests still going to `api.anthropic.com`**
Check that `ANTHROPIC_BASE_URL=http://localhost:8787` is set in your
Claude Code settings and that `CLAUDE_CODE_USE_BEDROCK=0` is set (the
native Bedrock mode bypasses the proxy URL).

**`ResourceNotFoundException` — model not found**
Use a fully qualified `au.` inference profile ARN, e.g.:
`au.anthropic.claude-sonnet-4-6`
The proxy defaults to `ap-southeast-2`; if you're in a different region
set `HEADROOM_REGION` to match.

**Proxy starts but `/readyz` hangs**
The upstream health check probes `api.anthropic.com` by default. The
compose file sets `HEADROOM_SKIP_UPSTREAM_CHECK=1` to skip this. If
running locally, add that env var:
```bash
HEADROOM_SKIP_UPSTREAM_CHECK=1 headroom proxy --host 0.0.0.0 --port 8787
```

**Docker build fails on `_core` compilation**
The Rust build needs network access (crates.io). If you're behind a
corporate proxy, pass the proxy args at build time:
```bash
docker build \
  --build-arg HTTP_PROXY=http://localhost:3128 \
  --build-arg HTTPS_PROXY=http://localhost:3128 \
  -t headroom-bedrock .
```
(The `docker-compose.bedrock.yml` already handles this automatically.)
