# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Headroom Bedrock Proxy — multi-stage Docker image
#
# This is a stripped-down, single-purpose image that runs the Headroom
# compression proxy hardcoded to AWS Bedrock. It accepts Anthropic-format
# /v1/messages requests, compresses them, and forwards to Bedrock via
# LiteLLM + SigV4 (boto3/botocore-crt).
#
# Build:
#   docker build -t headroom-bedrock .
#
# Run (with IAM instance profile / ECS task role — no explicit creds needed):
#   docker run -p 8787:8787 \
#     -e AWS_REGION=us-east-1 \
#     headroom-bedrock
#
# Run (with explicit credentials):
#   docker run -p 8787:8787 \
#     -e AWS_REGION=us-east-1 \
#     -e AWS_ACCESS_KEY_ID=... \
#     -e AWS_SECRET_ACCESS_KEY=... \
#     headroom-bedrock
#
# Health check:
#   curl http://localhost:8787/readyz
# ---------------------------------------------------------------------------

ARG PYTHON_VERSION=3.11
ARG PYTHON_SLIM_TAG=slim-bookworm
ARG RUST_VERSION=1.95.0
# Corporate TLS proxy (Zscaler). Override at build time if not needed:
#   docker build --build-arg HTTP_PROXY="" --build-arg HTTPS_PROXY="" ...
ARG HTTP_PROXY=""
ARG HTTPS_PROXY=""
ARG NO_PROXY="localhost,127.0.0.1,cdn.pyke.io,pyke.io,huggingface.co,hf.co"

# ---------------------------------------------------------------------------
# Stage 1: builder
# Compiles the headroom._core Rust extension via maturin and installs the
# full proxy + bedrock dependencies into /opt/headroom-venv.
#
# Platform: always build as linux/amd64. On Apple Silicon this runs under
# QEMU/Rosetta. This avoids Debian trixie arm64 pulling gcc-14-aarch64-linux-gnu
# (the ARM cross-compiler — 17 MB, times out through the corporate proxy).
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 python:${PYTHON_VERSION}-${PYTHON_SLIM_TAG} AS builder

ARG RUST_VERSION
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

# Pass proxy env vars for all subsequent RUN steps
ENV http_proxy=${HTTP_PROXY} \
    https_proxy=${HTTPS_PROXY} \
    HTTP_PROXY=${HTTP_PROXY} \
    HTTPS_PROXY=${HTTPS_PROXY} \
    NO_PROXY=${NO_PROXY} \
    no_proxy=${NO_PROXY}

# System build dependencies + corporate CA cert
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        libssl-dev \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install corporate CA so curl/rustup/pip trust the TLS-intercepting proxy
COPY cert.crt /usr/local/share/ca-certificates/corporate.crt
RUN update-ca-certificates

# Point cargo, pip, uv, and SSL at the system CA bundle (which now includes
# the corporate Zscaler cert registered above by update-ca-certificates).
ENV CARGO_HTTP_CAINFO=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    UV_NATIVE_TLS=1

# Install Rust toolchain (pinned to match rust-toolchain.toml).
# CARGO_HTTP_PROXY tells cargo/rustup to route through the corporate proxy.
RUN CARGO_HTTP_PROXY="${HTTPS_PROXY:-${HTTP_PROXY}}" \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal && \
    . "$HOME/.cargo/env" && \
    rustup component add rustfmt

ENV PATH="/root/.cargo/bin:${PATH}"

# Install uv (fast pip replacement) and maturin
RUN pip install --no-cache-dir --cert /etc/ssl/certs/ca-certificates.crt uv maturin

WORKDIR /build

# Copy only what's needed for the Rust + Python build
COPY pyproject.toml Cargo.toml Cargo.lock rust-toolchain.toml README.md ./
COPY crates/ crates/
COPY headroom/ headroom/

# Build and install headroom with the Bedrock proxy extras into an isolated venv.
# The maturin build-backend compiles _core.so and bundles it into the wheel.
# ORT_STRATEGY=load-dynamic (set above) skips the cdn.pyke.io prebuilt binary
# download; _core.so instead dlopen()s libonnxruntime at runtime from the path
# set by ORT_DYLIB_PATH.
RUN uv venv /opt/headroom-venv && \
    . /opt/headroom-venv/bin/activate && \
    maturin develop --release && \
    uv pip install ".[proxy,code,bedrock]" && \
    # Create a stable versioned symlink so ORT_DYLIB_PATH doesn't need the
    # exact patch version at image build time.
    ln -sf \
        "$(find /opt/headroom-venv -name 'libonnxruntime.so.*' | head -1)" \
        /opt/headroom-venv/lib/libonnxruntime.so

# Smoke-test the compiled extension
RUN /opt/headroom-venv/bin/python -c \
    "from headroom._core import SmartCrusher, DiffCompressor; print('_core OK')"

# ---------------------------------------------------------------------------
# Stage 2: runtime
# Minimal slim image — copies only the installed site-packages and the
# headroom source tree. No compiler, no Rust.
# ---------------------------------------------------------------------------
FROM --platform=linux/amd64 python:${PYTHON_VERSION}-${PYTHON_SLIM_TAG} AS runtime

# Runtime system dependencies (tree-sitter needs libstdc++; botocore-crt needs libssl)
RUN apt-get update && apt-get install -y --no-install-recommends \
        libstdc++6 \
        libssl3 \
        curl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy the fully-built Python environment from the builder stage
COPY --from=builder /opt/headroom-venv /opt/headroom-venv

# Use the venv's Python and headroom console script
ENV PATH="/opt/headroom-venv/bin:${PATH}" \
    # At runtime, point ort's dynamic loader at the onnxruntime shared library
    # shipped inside the Python onnxruntime wheel (stable symlink created above).
    ORT_DYLIB_PATH="/opt/headroom-venv/lib/libonnxruntime.so"

# ---------------------------------------------------------------------------
# Non-root user
# ---------------------------------------------------------------------------
RUN useradd -r -u 1000 -m headroom && \
    mkdir -p /data /home/headroom/.headroom && \
    chown -R headroom:headroom /data /home/headroom
USER headroom

# ---------------------------------------------------------------------------
# Environment — AWS Bedrock placeholders
# Override these at runtime via -e flags or IAM instance profile / task role.
# ---------------------------------------------------------------------------
ENV HEADROOM_HOST="0.0.0.0" \
    HEADROOM_PORT="8787" \
    HEADROOM_BACKEND="bedrock" \
    # AWS region — set to your Bedrock-enabled region.
    # Can also be provided via AWS_REGION (standard AWS env var).
    AWS_REGION="us-east-1" \
    # Credential placeholders — leave unset when using IAM instance profile
    # or ECS task role (recommended for production).
    AWS_ACCESS_KEY_ID="" \
    AWS_SECRET_ACCESS_KEY="" \
    AWS_SESSION_TOKEN="" \
    AWS_PROFILE=""

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://localhost:8787/readyz || exit 1

ENTRYPOINT ["headroom", "proxy"]
CMD ["--host", "0.0.0.0", "--port", "8787", "--backend", "bedrock"]
