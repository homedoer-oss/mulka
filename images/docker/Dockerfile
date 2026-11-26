# AOSP build environment for Mulka images (Android 14, API 34).
# Package list: https://source.android.com/docs/setup/start/requirements (Ubuntu 22.04).
# The container user gets the host user's UID/GID so the bind-mounted source tree stays owned by them.
FROM ubuntu:22.04

ARG UID=1000
ARG GID=1000
ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
        git-core gnupg flex bison build-essential zip unzip curl zlib1g-dev libc6-dev-i386 \
        x11proto-core-dev libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc \
        fontconfig python3 python-is-python3 rsync ca-certificates procps file bc \
    && rm -rf /var/lib/apt/lists/*

# repo: Google's official launcher; it fetches the matching repo version itself on `repo init`.
RUN curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o /usr/local/bin/repo \
    && chmod 0755 /usr/local/bin/repo

# repo init refuses to run without a git identity; this one lives only inside the image.
RUN git config --system user.name "Mulka build" \
    && git config --system user.email "build@localhost" \
    && git config --system color.ui false

RUN groupadd -g "${GID}" builder 2>/dev/null || true \
    && useradd -m -u "${UID}" -g "${GID}" -s /bin/bash builder
USER builder
ENV USER=builder HOME=/home/builder
WORKDIR /aosp
