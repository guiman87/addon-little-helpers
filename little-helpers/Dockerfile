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
    tmux \
    wget

# lrzsz (rz/sz for Zmodem uploads) lives in Alpine community, not main.
# Detect the running Alpine version; fall back to edge/community if needed.
RUN ALPINE_VER=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2) && \
    apk add --no-cache lrzsz \
        --repository "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community/" 2>/dev/null || \
    apk add --no-cache lrzsz \
        --repository "https://dl-cdn.alpinelinux.org/alpine/edge/community/" 2>/dev/null || \
    echo "WARNING: lrzsz unavailable — rz/sz will not work on this build"

# Install ttyd for web terminal (static binary — not in Alpine apk repos)
RUN ARCH=$([ "$BUILD_ARCH" = "aarch64" ] && echo "aarch64" || \
           [ "$BUILD_ARCH" = "armv7" ]  && echo "armhf"   || \
           [ "$BUILD_ARCH" = "armhf" ]  && echo "armhf"   || \
           echo "x86_64") && \
    wget -qO /usr/local/bin/ttyd \
      "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ARCH}" && \
    chmod +x /usr/local/bin/ttyd

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

# Build mobile-friendly index.html:
# Boot ttyd briefly on a temp port, fetch its default index.html (so asset
# references with webpack-generated hashes are preserved), inject our
# mobile toolbar fragment, and save to /terminal/mobile-index.html.
COPY terminal/ /terminal/
RUN set -e; \
    TMP_PORT=17681; \
    ttyd -p $TMP_PORT sleep 60 > /tmp/ttyd-build.log 2>&1 & \
    TTYD_PID=$!; \
    for i in 1 2 3 4 5 6 7 8 9 10; do \
        sleep 0.5; \
        if curl -sf "http://127.0.0.1:$TMP_PORT/" -o /tmp/ttyd-default.html; then break; fi; \
    done; \
    kill $TTYD_PID 2>/dev/null || true; \
    wait $TTYD_PID 2>/dev/null || true; \
    test -s /tmp/ttyd-default.html || (echo "Failed to fetch ttyd default index"; cat /tmp/ttyd-build.log; exit 1); \
    python3 -c "\
html = open('/tmp/ttyd-default.html').read();\
tb = open('/terminal/toolbar.html').read();\
assert '<body>' in html, 'no <body> tag in ttyd index';\
out = html.replace('<body>', '<body>\n' + tb, 1);\
open('/terminal/mobile-index.html', 'w').write(out)"; \
    test -s /terminal/mobile-index.html; \
    rm -f /tmp/ttyd-default.html /tmp/ttyd-build.log

# Copy addon scripts
COPY run.sh /run.sh
COPY sync.sh /sync.sh
RUN chmod +x /run.sh /sync.sh

CMD ["/run.sh"]
