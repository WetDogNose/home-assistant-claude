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
# for actions/checkout, the Docker CLI only (the daemon is the host's), and
# procps for pgrep/ps in the job cleanup.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq procps util-linux \
        docker-cli \
        libicu76 libkrb5-3 libssl3t64 zlib1g \
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
