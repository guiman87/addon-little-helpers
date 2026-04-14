ARG BUILD_FROM
FROM $BUILD_FROM

ARG BUILD_ARCH=amd64

# Required for git and npm to work in HA container environment
ENV HOME=/root

# Install system packages
RUN apk add --no-cache \
    bash \
    curl \
    git \
    jq \
    nodejs \
    npm \
    openssh-client \
    python3 \
    tar \
    wget

# Install gh CLI — static binary from GitHub releases
RUN ARCH=$([ "$BUILD_ARCH" = "aarch64" ] && echo "arm64" || \
           [ "$BUILD_ARCH" = "armv7" ] && echo "arm" || \
           [ "$BUILD_ARCH" = "armhf" ] && echo "arm" || \
           echo "amd64") && \
    GH_VERSION="2.45.0" && \
    wget -qO /tmp/gh.tar.gz \
      "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    mv /tmp/gh_${GH_VERSION}_linux_${ARCH}/bin/gh /usr/local/bin/gh && \
    chmod +x /usr/local/bin/gh && \
    rm -rf /tmp/gh*

# Install Claude Code and Google Workspace CLI via npm
RUN npm install -g \
    @anthropic-ai/claude-code \
    @googleworkspace/cli

# Copy addon scripts
COPY run.sh /run.sh
COPY sync.sh /sync.sh
RUN chmod +x /run.sh /sync.sh

CMD ["/run.sh"]
