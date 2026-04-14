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

# Install Playwright browsers and OS dependencies
RUN apt-get clean && npx playwright install --with-deps chromium

# Create agent user with UID 1000
# Noble images ship with an 'ubuntu' user at UID 1000 - remove it first
RUN userdel -r ubuntu 2>/dev/null || true && \
    useradd -m -u 1000 -s /bin/bash agent

# Set HOME so plugins install to the same location used at runtime
ENV HOME=/home/agent

# Add the official marketplace and install plugins
RUN claude plugin marketplace add anthropics/claude-plugins-official && \
    claude plugin install feature-dev@claude-plugins-official && \
    claude plugin install superpowers@claude-plugins-official && \
    claude plugin install commit-commands@claude-plugins-official && \
    claude plugin install code-review@claude-plugins-official && \
    claude plugin install frontend-design@claude-plugins-official && \
    claude plugin install security-guidance@claude-plugins-official && \
    claude plugin install context7@claude-plugins-official && \
    claude mcp add playwright npx '@playwright/mcp@latest'

# Install entrypoint script. Hooks are generated at runtime into
# $HOME/.claude-docker-hooks so they are writable regardless of the UID
# the container is started with.
COPY lib/entrypoint.sh /opt/claude-docker/entrypoint.sh
RUN chmod 755 /opt/claude-docker/entrypoint.sh
