FROM ubuntu:24.04

# Install system utilities
RUN apt-get update && apt-get install -y \
    curl git build-essential jq unzip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs

# Install Claude Code CLI
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && cp /root/.local/bin/claude /usr/local/bin/claude \
    && rm -rf /root/.local/bin/claude

# Install Playwright browsers under a fixed system-wide path so the cache
# doesn't depend on $HOME (which differs between root at build time and the
# runtime UID) and is found by @playwright/mcp at runtime without re-downloading.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright

# Refresh apt lists (cleared in the earlier RUN) so playwright's --with-deps
# can resolve packages, then install OS deps for chromium.
RUN apt-get update && \
    npx -y playwright@latest install-deps chromium && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Download the chromium browser binary into /ms-playwright.
RUN npx -y playwright@latest install chromium

# Expose the chromium binary at a stable path. Layout varies by Playwright
# version: full chromium ships `chrome` under chromium-XXXX/chrome-linux*/, the
# newer Chrome-for-Testing headless shell ships `headless_shell` (or
# `chrome-headless-shell`) under chromium_headless_shell-XXXX/. Search for any
# of those, prefer full chrome, fall back to the headless shell binary.
RUN set -eux; \
    chromium_bin=""; \
    for name in chrome headless_shell chrome-headless-shell; do \
        candidate="$(find /ms-playwright -maxdepth 5 -type f -executable -name "$name" 2>/dev/null | sort -V | tail -n1)"; \
        if [ -n "${candidate}" ] && [ -x "${candidate}" ]; then \
            chromium_bin="${candidate}"; \
            break; \
        fi; \
    done; \
    if [ -z "${chromium_bin}" ]; then \
        echo "ERROR: no chromium-family binary found under /ms-playwright"; \
        ls -laR /ms-playwright 2>&1 || true; \
        exit 1; \
    fi; \
    echo "Symlinking ${chromium_bin} -> /usr/local/bin/chromium"; \
    ln -sf "${chromium_bin}" /usr/local/bin/chromium

ENV CHROME_BIN=/usr/local/bin/chromium

# Create agent user with UID 1000
# Noble images ship with an 'ubuntu' user at UID 1000 - remove it first
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash agent

# Set HOME so plugins install to the same location used at runtime
ENV HOME=/home/agent

# Plugins are no longer installed at image build time: the `~/.agent-home`
# bind-mount in `bin/claude-docker` shadows `/home/agent/.claude/` at runtime,
# so anything baked in here is unreachable. Plugins now sync into the
# container at startup from the host's `~/.claude/settings.json`
# (see `lib/entrypoint.sh`). The MCP add stays here for new agent-home
# bootstraps.
RUN claude mcp add playwright npx '@playwright/mcp@latest'

# Install entrypoint script. Hooks are generated at runtime into
# $HOME/.claude-docker-hooks so they are writable regardless of the UID
# the container is started with.
COPY lib/entrypoint.sh /opt/claude-docker/entrypoint.sh
RUN chmod 755 /opt/claude-docker/entrypoint.sh
