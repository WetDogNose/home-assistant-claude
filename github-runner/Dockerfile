ARG BUILD_FROM
# hadolint ignore=DL3006
FROM ${BUILD_FROM}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runner version and checksum come from the release notes of actions/runner.
# The runner self-updates into /data/runner afterwards, so this only sets the
# version a fresh install starts from.
ARG RUNNER_VERSION=2.338.2
ARG RUNNER_SHA256=baebf204307bac6193480852732f0aba2ae97b6c5597c244f4d5558390147c40

# Runtime libraries the .NET runner needs (ICU, Kerberos, OpenSSL, zlib), git
# for actions/checkout, and procps for pgrep in the job cleanup.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git gnupg jq procps util-linux \
        libicu74 libkrb5-3 libssl3t64 zlib1g \
    && rm -rf /var/lib/apt/lists/*

# The Docker CLI only; the daemon is the host's. Ubuntu packages the CLI only
# inside docker.io (with dockerd and containerd), so take docker-ce-cli from
# Docker's signed repository, after checking the key's fingerprint.
ARG DOCKER_KEY_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
# hadolint ignore=DL3008
RUN install -d -m 0755 /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && gpg --show-keys --with-colons /etc/apt/keyrings/docker.asc \
        | awk -F: '$1 == "fpr" { print $10; exit }' | grep -qx "${DOCKER_KEY_FPR}" \
    && . /etc/os-release \
    && echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/actions-runner \
    && curl -fsSL -o /tmp/runner.tgz \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  /tmp/runner.tgz" | sha256sum -c - \
    && tar -xzf /tmp/runner.tgz -C /opt/actions-runner \
    && rm /tmp/runner.tgz

COPY rootfs/ /
RUN chmod +x /opt/addon/*.sh /usr/local/bin/docker

CMD ["/opt/addon/run.sh"]
