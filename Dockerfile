# Longx — the runtime image.
#
# Built from a release tarball (`longx-<version>-linux-<arch>.tar.gz`, the
# self-contained release the release workflow makes natively per
# architecture: ERTS, the Go shim, the built SPA), on the same Ubuntu the
# runners build on so the ERTS's glibc matches. Nothing is compiled here.
#
#   docker build --build-arg TARBALL=longx-0.2.4-linux-x86_64.tar.gz -t longx .
#
# What the agent finds inside: git, ripgrep, fd, jq, tree, bat, fzf, curl,
# Python 3 with uv and pip, Node.js 22 with npm. It runs as the user `longx`
# (uid 1000); its home is a volume, so what it installs at user level — a
# `uv tool`, an `npm -g` (prefix ~/.local), pip/uv caches, git config, SSH
# keys — survives a new container. System packages need a derived image:
#   FROM ghcr.io/mjason/longx:latest
#   USER root
#   RUN apt-get update && apt-get install -y --no-install-recommends golang && rm -rf /var/lib/apt/lists/*
#   USER longx
FROM ubuntu:24.04

ARG TARBALL
ARG NODE_MAJOR=22

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg tini openssl \
      git git-lfs ripgrep fd-find jq tree bat fzf \
      python3 python3-venv python3-pip \
      build-essential pkg-config \
 && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
 && ln -sf /usr/bin/batcat /usr/local/bin/bat \
 # Node.js from NodeSource (Ubuntu's own is older)
 && mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update && apt-get install -y --no-install-recommends nodejs \
 # uv: Python interpreters, venvs and tools for the agent, no root needed
 && curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh \
 && rm -rf /var/lib/apt/lists/* \
 # the user the agent runs as; Ubuntu 24.04 ships an `ubuntu` user on uid 1000, replaced.
 # The braces keep `|| true` on userdel alone: bare, it caught any failure before it
 # (a mirror's 404 for libexpat1 once) and the build died later as "UID 1000 is not unique"
 && { userdel -r ubuntu 2>/dev/null || true; } \
 && useradd --uid 1000 --create-home --shell /bin/bash longx \
 && mkdir -p /data /workspace /opt/longx \
 && chown longx:longx /data /workspace /opt/longx

COPY ${TARBALL} /tmp/longx.tar.gz
RUN tar -xzf /tmp/longx.tar.gz -C /opt --strip-components=0 \
 && rm /tmp/longx.tar.gz \
 && chown -R longx:longx /opt/longx

USER longx
WORKDIR /workspace

# the data dir holds the database, the secrets (generated on first boot), the
# global knowledge, attachments and the downloaded browser
ENV HOME=/home/longx \
    LONGX_DATA_DIR=/data \
    LONGX_CONTAINER=1 \
    PORT=7788 \
    PHX_HOST=localhost \
    # `npm -g`, `uv tool install` and pip's `--user` land in the home volume
    npm_config_prefix=/home/longx/.local \
    UV_TOOL_BIN_DIR=/home/longx/.local/bin \
    PATH=/home/longx/.local/bin:/opt/longx/bin:/usr/local/bin:/usr/bin:/bin

VOLUME ["/data", "/home/longx"]
EXPOSE 7788

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -fsS http://127.0.0.1:7788/health || exit 1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/opt/longx/bin/longx", "start"]
