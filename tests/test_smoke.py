"""Minimal smoke tests for the Bedrock-only compression proxy.

These tests verify that:
1. The proxy server module imports without errors.
2. The proxy always uses the "bedrock" backend, regardless of env vars.
3. The FastAPI app mounts correctly and /readyz returns 200.
4. Non-Bedrock routes return 404.

Run with:
    pytest tests/test_smoke.py -v
"""

import os

import pytest


def test_proxy_server_imports():
    """The proxy server module should import without errors after the strip-down."""
    from headroom.proxy import server  # noqa: F401

    assert hasattr(server, "create_app_from_env")
    assert hasattr(server, "run_server")


def test_create_app_from_env_forces_bedrock(monkeypatch):
    """create_app_from_env should always produce a 'bedrock' config."""
    # Attempt to override backend via env — should be ignored
    monkeypatch.setenv("HEADROOM_BACKEND", "anthropic")
    monkeypatch.setenv("AWS_REGION", "us-east-1")

    from headroom.proxy.server import create_app_from_env

    app = create_app_from_env()
    # The proxy config is attached to the app's state
    config = app.state.config
    assert config.backend == "bedrock", (
        f"Expected backend='bedrock', got '{config.backend}'. "
        "The proxy must be hardcoded to Bedrock."
    )


def test_bedrock_region_fallback(monkeypatch):
    """Region should be read from AWS_REGION env if HEADROOM_BEDROCK_REGION is unset."""
    monkeypatch.delenv("HEADROOM_BEDROCK_REGION", raising=False)
    monkeypatch.setenv("AWS_REGION", "ap-southeast-2")

    from headroom.proxy.server import create_app_from_env

    app = create_app_from_env()
    config = app.state.config
    assert config.bedrock_region == "ap-southeast-2"


@pytest.mark.asyncio
async def test_readyz_returns_200():
    """GET /readyz should return HTTP 200."""
    from httpx import AsyncClient, ASGITransport

    from headroom.proxy.server import create_app_from_env

    app = create_app_from_env()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.get("/readyz")
    assert resp.status_code == 200


@pytest.mark.asyncio
async def test_openai_chat_completions_returns_404():
    """POST /v1/chat/completions must return 404 (non-Bedrock route closed)."""
    from httpx import AsyncClient, ASGITransport

    from headroom.proxy.server import create_app_from_env

    app = create_app_from_env()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post("/v1/chat/completions", json={"model": "gpt-4o", "messages": []})
    assert resp.status_code == 404
    body = resp.json()
    assert "bedrock" in body.get("error", "").lower()


@pytest.mark.asyncio
async def test_gemini_generate_content_returns_404():
    """POST /v1beta/models/{model}:generateContent must return 404."""
    from httpx import AsyncClient, ASGITransport

    from headroom.proxy.server import create_app_from_env

    app = create_app_from_env()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        resp = await client.post(
            "/v1beta/models/gemini-pro:generateContent",
            json={"contents": [{"parts": [{"text": "hello"}]}]},
        )
    assert resp.status_code == 404
