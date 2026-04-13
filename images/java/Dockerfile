ARG BASE_TAG=latest
FROM ghcr.io/hansvd/claude-docker-base:${BASE_TAG}

# Install Eclipse Temurin JDK 24
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(. /etc/os-release && echo $VERSION_CODENAME) main" \
    > /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && apt-get install -y temurin-24-jdk && \
    rm -rf /var/lib/apt/lists/*

ENV JAVA_HOME=/usr/lib/jvm/temurin-24-jdk-amd64
