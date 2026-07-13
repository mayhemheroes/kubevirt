# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — kubevirt GO target (native-Go libFuzzer path). Builds
# ON TOP of the org C/C++ base (ghcr.io/mayhemheroes/base) — clang links the
# c-archive into a libFuzzer binary — adding a pinned Go toolchain under
# /opt/toolchains/go, then runs the per-repo mayhem/build.sh.
#
# WHY a Go-specific toolchain layout (SPEC §6.2 items 8/9, §6.5):
#   Go's GOPATH/GOMODCACHE default to $HOME/go. The commit build and the PATCH RL
#   re-run use DIFFERENT $HOMEs, so a cache left at the default would vanish under
#   the re-run identity. We pin GOROOT/GOPATH/GOMODCACHE at FIXED, $HOME-independent
#   paths under /opt/toolchains. kubevirt vendors all deps (vendor/ + go.work), so
#   build.sh uses -mod=vendor and the offline PATCH re-run needs no module fetch.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) -t mytag .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS

# ── Go toolchain @ a FIXED, lockable, $HOME-independent prefix ─────────────────
# Pin the Go version AND its tarball sha256 (reproducible fetch).
ARG GO_VERSION=1.26.5
ARG GO_SHA256=5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053

ENV GOROOT=/opt/toolchains/go \
    GOPATH=/opt/toolchains/go-path \
    GOMODCACHE=/opt/toolchains/go-path/pkg/mod \
    GOCACHE=/opt/toolchains/go-path/build-cache \
    GOTOOLCHAIN=local \
    GOFLAGS="-mod=vendor -buildvcs=false" \
    PATH=/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:${PATH}

USER root
# libvirt headers: kubevirt's virt-launcher/virt-handler packages (and their unit
# tests) cgo-link against libvirt (libvirt.org/go/libvirt).
RUN apt-get update && apt-get install -y --no-install-recommends libvirt-dev libnbd-dev pkg-config \
 && rm -rf /var/lib/apt/lists/*
RUN install -d /opt/toolchains/go-path \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
 && echo "${GO_SHA256}  /tmp/go.tgz" | sha256sum -c - \
 && tar -C /opt/toolchains -xzf /tmp/go.tgz && rm -f /tmp/go.tgz \
 # The commit build AND the air-gapped PATCH re-run run as `mayhem` (2000): it must
 # read the toolchain and read/write the build cache, so hand the GOPATH to 2000.
 && chown -R 2000:2000 /opt/toolchains/go-path \
 # virt-launcher/virtwrap/plugins unit tests write under the hard-coded
 # pluginSocketBaseDir (/var/run/kubevirt-plugin); the non-root `mayhem` user
 # can't create it under /var/run, so pre-create it writable.
 && install -d -o 2000 -g 2000 /var/run/kubevirt-plugin

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# Builds the libFuzzer target, the standalone reproducer, and the unit-test binaries.
RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
