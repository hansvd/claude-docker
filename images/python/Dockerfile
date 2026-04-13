ARG BASE_TAG=latest
FROM ghcr.io/hansvd/claude-docker-base:${BASE_TAG}

# Install Python 3 with pip and uv
RUN apt-get update && apt-get install -y \
    python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LsSf https://astral.sh/uv/install.sh | sh
