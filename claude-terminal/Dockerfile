ARG BUILD_FROM
FROM ${BUILD_FROM}

# All runtime packages are baked into the image so startup never depends on
# the network (ttyd/tmux/jq were previously apk-installed on every boot).
#
# py3-aiohttp, py3-beautifulsoup4, py3-requests and py3-yaml were removed: no
# script in the add-on imports any of them, and ha-mcp runs on uv's own managed
# CPython 3.13 rather than the system interpreter, so nothing here depended on
# them. Anyone who wants them back has persist-install.
#
# nodejs, npm, yq and python3 are deliberately KEPT even though the add-on
# itself no longer needs them (Claude Code is a native musl binary). This is a
# coding terminal attached to a Home Assistant configuration directory: yq
# edits YAML, and a JS project that cannot run npm would be a confusing
# regression to save ~50MB.
RUN apk add --no-cache \
    bash \
    curl \
    git \
    github-cli \
    jq \
    nano \
    nodejs \
    npm \
    py3-pip \
    python3 \
    tmux \
    tree \
    ttyd \
    vim \
    wget \
    yq-go

# uv from PyPI: Alpine's apk uv historically could not install managed musl
# CPython builds, which ha-mcp needs (it requires Python 3.13 exactly, and no
# Alpine release ships 3.13 -- 3.23 has 3.12, 3.24 has 3.14). Left unpinned so
# builds pick up the current release; the daily canary is what catches a uv
# release that breaks managed-Python provisioning, since nothing else exercises
# that path until an add-on actually boots.
RUN pip3 install --no-cache-dir --break-system-packages uv

# Keep the npm cache out of persistent storage so it never lands in HA backups
ENV npm_config_cache=/tmp/npm-cache

# Claude Code refuses --dangerously-skip-permissions as root unless the
# environment declares itself a disposable container — which HA add-ons are
ENV IS_SANDBOX=1

# The HA base image already runs ash with pipefail; restate it so hadolint
# (which only sees this file) knows the curl|tar pipe below is guarded
SHELL ["/bin/ash", "-o", "pipefail", "-c"]

# Bundled Claude Code CLI. This copy is frozen at image build time; when
# claude_auto_update is enabled, run.sh maintains a persistent native install
# in /data that takes precedence and keeps itself current.
# Fetched as the native musl binary straight from the npm registry rather
# than via `npm install -g`: the npm package is now only a wrapper that
# installs this same binary, and running npm/Node during aarch64 cross-builds
# (QEMU on CI runners) crashes V8 with SIGILL. curl+tar emulate fine.
# Bundled Claude Code version. Empty keeps the current behaviour (resolve
# "latest" at build time). Setting an exact X.Y.Z makes the image byte-stable
# for a given source tree, which is what lets a rebuild reproduce a shipped
# image and lets a release pin away from a known-bad upstream build.
ARG CLAUDE_VERSION=""

RUN case "$(apk --print-arch)" in \
        x86_64)  claude_pkg="linux-x64-musl" ;; \
        aarch64) claude_pkg="linux-arm64-musl" ;; \
        *) echo "Unsupported architecture: $(apk --print-arch)" >&2; exit 1 ;; \
    esac \
    && claude_version="${CLAUDE_VERSION:-$(curl -fsSL https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r .version)}" \
    && echo "Bundling Claude Code ${claude_version}" \
    && curl -fsSL "https://registry.npmjs.org/@anthropic-ai/claude-code-${claude_pkg}/-/claude-code-${claude_pkg}-${claude_version}.tgz" \
        | tar -xz -C /tmp package/claude \
    && install -m 0755 /tmp/package/claude /usr/local/bin/claude \
    && rm -rf /tmp/package \
    # Fail the build if the bundled binary cannot resolve against THIS image's
    # musl. The 2.5.1 blank terminal was exactly this: present, +x, and aborting
    # on exec with "symbol not found" -- which every presence-based check passes.
    # ldd resolves relocations WITHOUT executing, so unlike `claude --version`
    # it is safe during the QEMU-emulated aarch64 cross-build (executing the Bun
    # JIT under qemu-user is the SIGILL that forced this curl+tar rewrite).
    # Note musl's ldd exits 127 rather than 1, so grep for the message.
    && { ldd /usr/local/bin/claude || true; } > /tmp/claude-ldd.txt 2>&1 \
    && if grep -q 'symbol not found' /tmp/claude-ldd.txt; then \
           echo "FATAL: bundled claude has unresolved symbols against this base image:" >&2; \
           grep 'symbol not found' /tmp/claude-ldd.txt >&2; \
           exit 1; \
       fi \
    # Record what floated, so a future breakage can be correlated with what moved
    && mkdir -p /usr/local/share/claude-terminal \
    && printf '{"claude":"%s","alpine":"%s","arch":"%s"}\n' \
        "${claude_version}" "$(cat /etc/alpine-release)" "$(apk --print-arch)" \
        > /usr/local/share/claude-terminal/build-versions.json \
    && rm -f /tmp/claude-ldd.txt

WORKDIR /config

COPY run.sh /run.sh
COPY scripts/ /opt/scripts/
RUN chmod +x /run.sh /opt/scripts/*.sh

# A HEALTHCHECK is the prerequisite for a Supervisor watchdog: without one the
# container reports STARTED the moment the process execs, so a watchdog would
# restart the add-on while it is still provisioning -- which restarts the
# provisioning, which never finishes. start-period covers the slowest realistic
# boot; provisioning itself now runs in the background, so ttyd is listening
# long before that budget expires.
# The header is REQUIRED here. ttyd runs with --auth-header X-Remote-User-Id,
# so a probe without it gets 401, curl -f fails, and the container never
# reports healthy -- the Supervisor then times out at 120s and the watchdog
# restarts it in a loop, while ttyd is in fact serving perfectly well.
#
# The value is irrelevant: --auth-header only requires the header to be
# present. That is not a bypass -- this runs inside the container, which can
# already reach everything; the header is what stops UNAUTHENTICATED callers
# arriving through ingress or from another add-on.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=3 \
    CMD curl -fsS -o /dev/null -H "X-Remote-User-Id: healthcheck" \
        http://127.0.0.1:7681/ || exit 1

# Use exec form for better signal handling
CMD ["/run.sh"]
