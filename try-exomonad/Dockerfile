# ==========================================================================
# Stage 1: Build exomonad binary
# ==========================================================================
FROM rust:1.88-bookworm AS builder

RUN apt-get update && apt-get install -y \
    pkg-config \
    libssl-dev \
    libcurl4-openssl-dev \
    protobuf-compiler \
    cmake \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

COPY Cargo.toml Cargo.lock ./
COPY rust/ rust/
COPY vendor/ vendor/

RUN cargo build --release -p exomonad

# ==========================================================================
# Stage 2: Runtime
# ==========================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Core system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    ca-certificates \
    bash \
    libssl3t64 \
    libcurl4t64 \
    jq \
    && rm -rf /var/lib/apt/lists/*

# gh CLI (GitHub's official apt repository)
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Zellij (must match zellij-utils = "0.43" in Cargo.toml)
RUN curl -fsSL https://github.com/zellij-org/zellij/releases/download/v0.43.1/zellij-x86_64-unknown-linux-musl.tar.gz \
    | tar xz -C /usr/local/bin

# Node.js 22 LTS (needed for Gemini CLI)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Gemini CLI (npm — no native installer yet)
RUN npm install -g @google/gemini-cli

# --------------------------------------------------------------------------
# Non-root user (Claude Code refuses to run as root)
# Ubuntu 24.04 ships a 'ubuntu' user at UID 1000. We need UID 1000 so
# bind-mounted host files (~/.claude, ~/.gemini) are readable.
# --------------------------------------------------------------------------
RUN userdel -r ubuntu 2>/dev/null; useradd -m -s /bin/bash -u 1000 exo
RUN mkdir -p /home/exo/.config/zellij/plugins /tmp/runtime \
    && chown -R exo:exo /home/exo /tmp/runtime

# --------------------------------------------------------------------------
# exomonad binary from builder
# --------------------------------------------------------------------------
COPY --from=builder /build/target/release/exomonad /usr/local/bin/exomonad

# Pre-built WASM artifacts (platform-independent, copied from host by run.sh)
COPY try-exomonad/artifacts/wasm-guest-devswarm.wasm /opt/exomonad/wasm/

# Bootstrap script
COPY try-exomonad/bootstrap.sh /usr/local/bin/exomonad-bootstrap
RUN chmod +x /usr/local/bin/exomonad-bootstrap

# --------------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------------
RUN mkdir -p /workspace && chown exo:exo /workspace

USER exo
ENV SHELL=/bin/bash
ENV HOME=/home/exo
ENV XDG_RUNTIME_DIR=/tmp/runtime
ENV TERM=xterm-256color

# Claude Code (native installer — npm package is deprecated)
# Installs to ~/.local/bin/claude (outside ~/.claude/), so the full
# ~/.claude/ bind mount from run.sh doesn't clobber the binary.
RUN curl -fsSL https://claude.ai/install.sh | bash
ENV PATH="/home/exo/.local/bin:${PATH}"

WORKDIR /workspace
CMD ["bash"]
