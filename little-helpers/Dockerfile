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

# Install ttyd — static binary from GitHub releases (no runtime deps)
RUN TTYD_VERSION="1.7.7" && \
    ARCH=$([ "$BUILD_ARCH" = "aarch64" ] && echo "aarch64" || \
           [ "$BUILD_ARCH" = "armv7" ] && echo "armhf" || \
           [ "$BUILD_ARCH" = "armhf" ] && echo "armhf" || \
           echo "x86_64") && \
    wget -qO /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ARCH}" && \
    chmod +x /usr/local/bin/ttyd

# Install Claude Code and Google Workspace CLI via npm
RUN npm install -g \
    @anthropic-ai/claude-code \
    @googleworkspace/cli

# Copy addon scripts
COPY run.sh /run.sh
COPY sync.sh /sync.sh
RUN chmod +x /run.sh /sync.sh

# ttyd listens on this port (must match ingress_port in config.yaml)
EXPOSE 8099

CMD ["/run.sh"]
