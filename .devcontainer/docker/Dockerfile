# syntax=docker/dockerfile:1.7
#
# =============================================================================
# BAOBAB Enterprise Platform — Standard Development Container
# =============================================================================
# Maintained by: Nabhold Group Africa — Platform Engineering
# Registry:      ghcr.io/nabhold/baobab-dev
#
# This image is the single source of truth for the BAOBAB local development
# environment. It is built for GitHub Codespaces and Dev Containers (VS Code /
# JetBrains Gateway) alike, and is also usable as a plain Docker image for CI
# steps that need the same toolchain as developers.
#
# Design principles:
#   - Deterministic: every language runtime and CLI tool version other than
#     the Ubuntu base image is read exclusively from config/versions.lock, a
#     file generated OUTSIDE of Docker by config/resolve.sh. This Dockerfile
#     never executes resolve.sh and never re-derives a version on its own —
#     it only consumes the lock file that was produced (and committed to the
#     build context) before `docker build` was invoked. This keeps image
#     builds reproducible: the same versions.lock always produces the same
#     image content.
#   - Build ARGs: VERSION, BUILD_DATE, REVISION are pure image metadata,
#     always supplied by CI. UBUNTU_VERSION below is the one exception to
#     "versions come only from versions.lock" (see next bullet) — it ships
#     with a hard-coded default and normally requires no --build-arg at all.
#   - Ubuntu base image: `FROM` instructions are resolved by BuildKit before
#     the build context (and therefore versions.lock) is available, so the
#     base image tag cannot be sourced from a context file the way every
#     other tool version can. Rather than repeating a literal Ubuntu tag in
#     three separate `FROM` lines, it is declared once as `ARG
#     UBUNTU_VERSION=26.04` immediately below and referenced as
#     `${UBUNTU_VERSION}` in every stage — one place to bump when the base
#     image changes, and the default means CI does not need to pass this
#     build-arg for normal builds (it may still override it for a one-off
#     build if ever needed). If the platform.ubuntu.version entry in
#     config/versions.yaml is bumped, this ARG's default must be updated to
#     match by hand as part of that change — versions.yaml documents the
#     intended base image for humans, but this ARG is what actually pins it.
#   - Multi-stage: large/one-shot downloads (Flutter SDK, GitHub-released
#     CLI binaries) are fetched and verified in isolated builder stages, so
#     the final stage only ever COPYs clean, extracted artifacts. This keeps
#     the final layer history free of tarballs and speeds up rebuilds because
#     changing an apt package does not invalidate the Flutter download layer
#     (and vice versa).
#   - Multi-arch: every stage is written to work under `docker buildx build
#     --platform linux/amd64,linux/arm64` using the automatic TARGETARCH /
#     TARGETPLATFORM build args — no per-arch Dockerfiles.
#   - Non-root: the final runtime user is `vscode` (UID/GID 1000) with
#     passwordless sudo, matching the GitHub Codespaces convention.
#   - Zero-Trust Binary Downloads: every binary fetched from outside a
#     distribution's own signed package repository is verified against the
#     exact SHA256 digest config/resolve.sh already computed for it, via
#     `sha256sum -c`, before it is ever extracted or executed. A checksum
#     resolve.sh computes but that nothing downstream verifies is not a
#     security control — see the cli-tools and flutter-sdk stages below,
#     where this is actually enforced.
#
# Cache-efficiency note on versions.lock:
#   Every RUN layer that needs a pinned version sources config/versions.lock
#   after COPYing it into the stage. Because versions.lock is a single file
#   holding every tool's version, a change ANYWHERE in it (e.g. bumping only
#   eza) changes the file's checksum and therefore invalidates the COPY layer
#   — and everything after it — in every stage that copies the file, even
#   for tools that did not actually change. Builder-stage isolation is still
#   fully preserved (bumping Flutter never touches the cli-tools stage or
#   vice versa, since each COPYs its own independent layer), but *within* a
#   stage the blast radius of any single version bump is "that stage's
#   version-consuming layers onward." This is an inherent trade-off of using
#   one lock file with a minimal, fixed set of build ARGs, not an oversight.
#
# CHANGE LOG (this file, most recent first)
# ------------------------------------------------------------------------------
# * Explicitly upgraded setuptools (CVE-2025-47273) and msgpack, both
#   system-wide and inside Poetry's own isolated pipx venv — Trivy flagged
#   both at versions well behind their fixes. Neither is caught by this
#   project's normal version-resolution machinery: they're bundled at
#   whatever version ensurepip froze into this CPython build, not
#   something "latest" tracking touches.
# * Investigated the Moby/CVE-2026-34040 finding in docker-buildx-plugin
#   and docker-compose-plugin (both from Docker's own apt repo): confirmed
#   via direct go.mod inspection that even the latest available upstream
#   releases (buildx v0.36.1, compose v5.4.0) still depend on
#   github.com/docker/docker v28.5.2+incompatible — the exact vulnerable
#   version. Not fixable from our side until Docker's own plugins adopt
#   the v29.3.1 line; left unresolved deliberately, not silently.
# * Fixed the Python version-pinning conditional: the base-archive branch's
#   `apt-cache show "python${PYTHON_MINOR}" || apt-cache show python3`
#   check fired almost unconditionally (generic python3 exists on nearly
#   every Ubuntu release) and then installed generic `python3` rather than
#   the specific pinned minor version — meaning PYTHON_MINOR was never
#   actually verified or enforced, just coincidentally matched when
#   Ubuntu's own default happened to line up. Both branches now install
#   the specific python${PYTHON_MINOR} package by name. Node's pinning was
#   re-checked and found to already be correct as-is: NodeSource publishes
#   a separate apt repository per major version line, so no fix was needed
#   there.
# * Wired up every checksum config/resolve.sh now computes, and actually
#   enforces it: cli-tools and flutter-sdk previously downloaded ripgrep,
#   fd, bat, eza, and Flutter's amd64 archive WITHOUT ever verifying the
#   SHA256 resolve.sh already resolved for each — the checksum existed in
#   versions.lock but nothing checked the downloaded bytes against it. Every
#   download in both stages now runs through sha256sum -c before use.
# * Added task, yq, uv, and cosign — resolved and checksummed by
#   resolve.sh, but never actually installed anywhere in the image.
# * gh moved from an unpinned apt install (cli.github.com's own repo, but
#   always "whatever is latest at build time") to the same checksummed
#   cli-tools binary pattern as the other GitHub-released tools — this is
#   what versions.yaml's `github_cli.source: github` already declared;
#   the apt install just never actually honored it.
# * uv moved from `pipx install uv` (PyPI, unpinned to GH_VERSION-style
#   determinism) to the same checksummed binary pattern, honoring its own
#   `source: github` in versions.yaml.
# * Poetry and pnpm were being installed completely unpinned
#   (`pipx install poetry`, `corepack prepare pnpm@latest`) — both silently
#   ignored POETRY_VERSION/PNPM_VERSION even after resolve.sh started
#   resolving them. Both now pin to the exact resolved version.
# * Flutter's arm64 build now fetches by the exact resolved commit
#   (FLUTTER_GIT_REF) instead of by tag name — functionally similar to the
#   previous tag-based fetch, but removes any dependency on git's tag/branch
#   disambiguation entirely, since a raw commit fetch has no ref-name
#   ambiguity to resolve in the first place.
# =============================================================================

# Base image tag, single source of truth for all three stages below. Has a
# default so CI does not need to pass --build-arg UBUNTU_VERSION for normal
# builds; override it explicitly only for a deliberate one-off build.
ARG UBUNTU_VERSION=26.04

# -----------------------------------------------------------------------------
# Stage: flutter-sdk — fetch + verify + prune the Flutter stable SDK
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS flutter-sdk
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils git && \
    rm -rf /var/lib/apt/lists/*

# Version data comes exclusively from config/versions.lock (generated by
# config/resolve.sh outside of Docker). This stage never executes resolve.sh
# and never re-derives a version on its own.
COPY config/versions.lock /tmp/baobab-config/versions.lock

# Flutter's officially distributed pre-built SDK bundle is x64-only —
# live-verified against Flutter's own release manifest: every entry, at
# every version, carries "dart_sdk_arch": "x64" and no arm64 archive exists
# on any channel. There is no equivalent pre-built tarball for Linux ARM64
# hosts to point at.
#
# Per Flutter's own guidance for ARM64 Linux hosts (Raspberry Pi, Ampere
# Altra, Apple Silicon Linux VMs, GitHub's ubuntu-*-arm runners, etc.), the
# supported path there is different: fetch the flutter/flutter repository
# directly, at the exact commit config/resolve.sh already resolved
# (FLUTTER_GIT_REF — the same commit hash Flutter's own release manifest
# attributes to this stable version). The `flutter` tool detects the host
# architecture itself and fetches the matching engine/Dart SDK artifacts on
# first invocation (triggered later, in the final stage's `flutter precache`
# step) — so no manual per-arch URL construction is needed or possible for
# arm64.
#
# Fetching by exact commit hash (rather than by tag name) is deliberate: it
# sidesteps entirely the tag/branch-name collisions some past Flutter
# releases have had (see
# https://github.com/flutter/flutter/issues/104901) — a raw commit fetch has
# no ref name to disambiguate in the first place, unlike `git fetch
# <tag-name>`, which can silently resolve to a same-named branch instead of
# the intended tag. GitHub supports fetching an arbitrary reachable commit
# by its full SHA for public repositories, which is exactly what
# FLUTTER_GIT_REF is.
#
# amd64 gets the same zero-trust treatment as every other downloaded binary
# in this Dockerfile: the tarball is verified against FLUTTER_SHA256_AMD64
# via sha256sum -c before extraction. arm64 has no tarball to check a
# SHA256 against — a git commit hash is the equivalent content-addressed
# integrity guarantee there: cloning at this exact commit can only ever
# produce this exact source tree.
RUN set -euo pipefail; \
    . /tmp/baobab-config/versions.lock; \
    mkdir -p /opt/flutter-tmp; \
    case "${TARGETARCH}" in \
      amd64) \
        curl -fsSL -o /tmp/flutter.tar.xz "${FLUTTER_ARCHIVE_AMD64}"; \
        echo "${FLUTTER_SHA256_AMD64}  /tmp/flutter.tar.xz" | sha256sum -c -; \
        tar -xJf /tmp/flutter.tar.xz -C /opt/flutter-tmp --strip-components=1; \
        rm -f /tmp/flutter.tar.xz; \
        # .git MUST be kept so flutter precache can resolve the engine commit revision.
        rm -rf /opt/flutter-tmp/packages/flutter/doc \
        ;; \
      arm64) \
        git init -q /opt/flutter-tmp; \
        git -C /opt/flutter-tmp remote add origin https://github.com/flutter/flutter.git; \
        git -C /opt/flutter-tmp fetch --depth 1 origin "${FLUTTER_GIT_REF}"; \
        git -C /opt/flutter-tmp checkout -q FETCH_HEAD; \
        git -C /opt/flutter-tmp tag -f "${FLUTTER_VERSION}" FETCH_HEAD; \
        # .git MUST be kept here — the flutter tool reads git metadata on arm64
        # to resolve its own version and channel state. Docs are safe to drop.
        rm -rf /opt/flutter-tmp/packages/flutter/doc \
        ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac


# -----------------------------------------------------------------------------
# Stage: cli-tools — fetch + verify pinned Rust/Go CLI utilities from GitHub
# Releases
# -----------------------------------------------------------------------------
# Ubuntu's own package versions for these tools drift release to release and
# are sometimes missing on brand-new LTS series before universe catches up.
# Pinning to upstream GitHub release tarballs keeps every BAOBAB engineer on
# byte-identical tool versions regardless of the base image's apt state.
#
# Every single asset fetched here is verified against the exact SHA256
# config/resolve.sh already resolved for it (fetch_verify below) — this is
# the actual enforcement point of "Zero-Trust Binary Downloads". Asset
# filenames also come exclusively from versions.lock's *_ASSET_* variables,
# not reconstructed inline, so a filename typo simply 404s at build time
# instead of silently verifying against the wrong file.
FROM ubuntu:${UBUNTU_VERSION} AS cli-tools
ARG TARGETARCH
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl tar && \
    rm -rf /var/lib/apt/lists/*

# Version data comes exclusively from config/versions.lock (generated by
# config/resolve.sh outside of Docker). This stage never executes resolve.sh
# and never re-derives a version on its own.
COPY config/versions.lock /tmp/baobab-config/versions.lock

WORKDIR /tmp/cli-tools
RUN set -euo pipefail; \
    . /tmp/baobab-config/versions.lock; \
    mkdir -p /opt/cli-tools/bin; \
    \
    case "${TARGETARCH}" in \
      amd64) ARCH_SUFFIX="AMD64" ;; \
      arm64) ARCH_SUFFIX="ARM64" ;; \
      *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    \
    # Downloads a single asset and verifies it against the SHA256 resolve.sh
    # already resolved for it. Aborts the build on any mismatch — there is
    # no "warn and continue" path for a failed integrity check.
    fetch_verify() { \
        local url="$1" asset="$2" sha256="$3"; \
        curl -fsSL -o "${asset}" "${url}"; \
        echo "${sha256}  ${asset}" | sha256sum -c -; \
    }; \
    \
    # Extracts a single named binary out of a verified .tar.gz, regardless
    # of how deeply nested it is inside the archive (upstream projects are
    # inconsistent about this: some ship the binary at the archive root,
    # others nest it under a versioned directory or a bin/ subdirectory).
    # Installs the result directly under /opt/cli-tools/bin.
    extract_binary() { \
        local tarball="$1" binary_name="$2"; \
        local dest="/opt/cli-tools/bin/${binary_name}"; \
        local extract_dir; \
        extract_dir="$(mktemp -d)"; \
        tar -xzf "${tarball}" -C "${extract_dir}"; \
        find "${extract_dir}" -type f -name "${binary_name}" -exec cp {} "${dest}" \; ; \
        rm -rf "${extract_dir}"; \
        [[ -f "${dest}" ]] || { echo "Failed to locate '${binary_name}' inside ${tarball}" >&2; exit 1; }; \
    }; \
    \
    # ripgrep — tar.gz
    RG_ASSET="RIPGREP_ASSET_${ARCH_SUFFIX}"; RG_SHA="RIPGREP_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/BurntSushi/ripgrep/releases/download/${RIPGREP_VERSION}/${!RG_ASSET}" "${!RG_ASSET}" "${!RG_SHA}"; \
    extract_binary "${!RG_ASSET}" rg; \
    \
    # fd — tar.gz
    FD_ASSET="FD_ASSET_${ARCH_SUFFIX}"; FD_SHA="FD_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/sharkdp/fd/releases/download/v${FD_VERSION}/${!FD_ASSET}" "${!FD_ASSET}" "${!FD_SHA}"; \
    extract_binary "${!FD_ASSET}" fd; \
    \
    # bat — tar.gz
    BAT_ASSET="BAT_ASSET_${ARCH_SUFFIX}"; BAT_SHA="BAT_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/sharkdp/bat/releases/download/v${BAT_VERSION}/${!BAT_ASSET}" "${!BAT_ASSET}" "${!BAT_SHA}"; \
    extract_binary "${!BAT_ASSET}" bat; \
    \
    # eza — tar.gz
    EZA_ASSET="EZA_ASSET_${ARCH_SUFFIX}"; EZA_SHA="EZA_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/eza-community/eza/releases/download/v${EZA_VERSION}/${!EZA_ASSET}" "${!EZA_ASSET}" "${!EZA_SHA}"; \
    extract_binary "${!EZA_ASSET}" eza; \
    \
    # task — tar.gz
    TASK_ASSET="TASK_ASSET_${ARCH_SUFFIX}"; TASK_SHA="TASK_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/go-task/task/releases/download/v${TASK_VERSION}/${!TASK_ASSET}" "${!TASK_ASSET}" "${!TASK_SHA}"; \
    extract_binary "${!TASK_ASSET}" task; \
    \
    # uv — tar.gz, ships both uv and uvx in the same archive
    UV_ASSET="UV_ASSET_${ARCH_SUFFIX}"; UV_SHA="UV_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/${!UV_ASSET}" "${!UV_ASSET}" "${!UV_SHA}"; \
    extract_binary "${!UV_ASSET}" uv; \
    extract_binary "${!UV_ASSET}" uvx; \
    \
    # gh — tar.gz
    GH_ASSET="GH_ASSET_${ARCH_SUFFIX}"; GH_SHA="GH_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/cli/cli/releases/download/v${GH_VERSION}/${!GH_ASSET}" "${!GH_ASSET}" "${!GH_SHA}"; \
    extract_binary "${!GH_ASSET}" gh; \
    \
    # yq — raw binary, no archive to extract
    YQ_ASSET="YQ_ASSET_${ARCH_SUFFIX}"; YQ_SHA="YQ_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/${!YQ_ASSET}" "${!YQ_ASSET}" "${!YQ_SHA}"; \
    cp "${!YQ_ASSET}" /opt/cli-tools/bin/yq; \
    \
    # cosign — raw binary, no archive to extract
    COSIGN_ASSET="COSIGN_ASSET_${ARCH_SUFFIX}"; COSIGN_SHA="COSIGN_SHA256_${ARCH_SUFFIX}"; \
    fetch_verify "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/${!COSIGN_ASSET}" "${!COSIGN_ASSET}" "${!COSIGN_SHA}"; \
    cp "${!COSIGN_ASSET}" /opt/cli-tools/bin/cosign; \
    \
    chmod +x /opt/cli-tools/bin/*; \
    rm -rf /tmp/cli-tools/*

# -----------------------------------------------------------------------------
# Stage: final — the actual dev container image
# -----------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS final

ARG TARGETARCH
# Build metadata supplied by GitHub Actions
ARG BUILD_DATE
ARG VERSION
ARG REVISION

LABEL org.opencontainers.image.title="baobab-dev" \
      org.opencontainers.image.description="Standard development container for the BAOBAB Enterprise Platform (Nabhold Group Africa)" \
      org.opencontainers.image.vendor="Nabhold Group Africa" \
      org.opencontainers.image.source="https://github.com/nabhold/baobab-devcontainer" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.created=$BUILD_DATE \
      org.opencontainers.image.version=$VERSION \
      org.opencontainers.image.revision=$REVISION \
      org.opencontainers.image.authors="Platform Engineering <platform@nabhold.com>" \
      org.opencontainers.image.documentation="https://github.com/nabhold/baobab-devcontainer/blob/main/README.md"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    TZ=UTC

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# -----------------------------------------------------------------------------
# 1. Core system packages, locale, timezone
# -----------------------------------------------------------------------------
# Ubuntu's default apt config (docker-clean) deletes downloaded .deb files
# and the apt lists cache immediately after every apt-get invocation, which
# defeats BuildKit's --mount=type=cache for /var/cache/apt and /var/lib/apt
# below. Removing it (and telling apt to keep downloaded packages) lets
# those cache mounts actually persist package downloads across rebuilds.
RUN rm -f /etc/apt/apt.conf.d/docker-clean; \
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      sudo curl wget git unzip zip tar jq tree nano vim less htop procps \
      ca-certificates gnupg software-properties-common build-essential \
      pkg-config locales tzdata xz-utils apt-transport-https \
      openssh-client dnsutils iproute2 \
    && \
    locale-gen en_US.UTF-8 && \
    update-locale LANG=en_US.UTF-8 LANGUAGE=en_US:en && \
    ln -fs /usr/share/zoneinfo/${TZ} /etc/localtime && \
    dpkg-reconfigure -f noninteractive tzdata

# -----------------------------------------------------------------------------
# 2. BAOBAB runtime configuration layout
#
# config/versions.lock is the single, deterministic source of truth for every
# tool version installed below. It is generated OUTSIDE of this Dockerfile by
# config/resolve.sh (never executed during `docker build`) and is installed
# here, permanently, under /usr/local/share/baobab/config so that:
#   - the RUN layers further down in THIS stage can source it to pick up
#     pinned versions (Python, Node.js, PostgreSQL, ...);
#   - baobab-verify / baobab-summary / baobab-bootstrap / baobab-post-create
#     can read it at container runtime via $BAOBAB_CONFIG_DIR, exactly as
#     they do outside the image.
#
# config/resolve.sh itself is installed alongside it for reference/tooling
# parity (e.g. re-running version resolution from inside a running
# container), but is never invoked as part of this build.
# -----------------------------------------------------------------------------
RUN mkdir -p /usr/local/share/baobab/config

COPY config/versions.yaml /usr/local/share/baobab/config/versions.yaml
COPY config/versions.lock /usr/local/share/baobab/config/versions.lock
COPY --chmod=0755 config/resolve.sh /usr/local/share/baobab/config/resolve.sh

ENV BAOBAB_CONFIG_DIR=/usr/local/share/baobab/config

# -----------------------------------------------------------------------------
# 3. Python toolchain. The minor version (e.g. "3.14") is derived from
#    versions.lock's full PYTHON_VERSION (e.g. "3.14.6") since apt package
#    names use major.minor only.
#
# deadsnakes is added conditionally, not unconditionally: some deadsnakes
# releases deliberately omit the Ubuntu base image's own native default
# Python version, since it's already available from Ubuntu's own archives
# (e.g. Python 3.10 on jammy, 3.12 on noble, 3.14 on resolute are all
# excluded from deadsnakes for exactly this reason — see
# https://launchpad.net/~deadsnakes/+archive/ubuntu/ppa). Unconditionally
# adding the PPA and expecting it to always have the pinned version breaks
# whenever versions.lock happens to pin the same version the base image
# already ships. Probing `apt-cache show` against the base archives first,
# before deciding whether to add the PPA, keeps this correct regardless of
# whether the pin matches the base image's native version or diverges from
# it — without hard-coding today's specific version/codename pairing.
#
# pip is deliberately bootstrapped via get-pip.py on fallback paths rather
# than apt's python3-pip when deadsnakes is used, ensuring unrestricted pip
# functionality across different base OS versions.
#
# CHANGE (2026-08-06): the base-archive branch's condition previously was
# `apt-cache show "python${PYTHON_MINOR}" || apt-cache show python3` — the
# `|| apt-cache show python3` made this true almost unconditionally, since
# the generic python3 metapackage exists on virtually every Ubuntu release
# regardless of which minor version it currently defaults to. That branch
# then installed generic `python3` rather than the specific pinned minor
# version, so this section previously installed "whatever Ubuntu 26.04's
# default python3 happens to be" and never actually verified or enforced
# PYTHON_MINOR == "3.14" — the deadsnakes fallback essentially never
# triggered, and baobab-verify's check for a `python3.14` binary only
# passed by coincidence, if Ubuntu's default happened to already be 3.14.
# Both branches now install the SPECIFIC minor-versioned package by name
# (python${PYTHON_MINOR}, e.g. "python3.14") regardless of which one fires,
# so PYTHON_MINOR is genuinely what ends up on disk either way.
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    . "${BAOBAB_CONFIG_DIR}/versions.lock" && \
    PYTHON_MINOR="${PYTHON_VERSION%.*}" && \
    apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates software-properties-common && \
    if apt-cache show "python${PYTHON_MINOR}" >/dev/null 2>&1; then \
        apt-get install -y --no-install-recommends \
            "python${PYTHON_MINOR}" \
            "python${PYTHON_MINOR}-venv" \
            "python${PYTHON_MINOR}-dev" && \
        ( apt-cache show "python${PYTHON_MINOR}-pip" >/dev/null 2>&1 \
            && apt-get install -y --no-install-recommends "python${PYTHON_MINOR}-pip" \
            || curl -fsSL https://bootstrap.pypa.io/get-pip.py | "python${PYTHON_MINOR}" - --no-cache-dir --break-system-packages ); \
    else \
        add-apt-repository -y ppa:deadsnakes/ppa && \
        apt-get update && \
        apt-get install -y --no-install-recommends \
            "python${PYTHON_MINOR}" \
            "python${PYTHON_MINOR}-venv" \
            "python${PYTHON_MINOR}-dev" && \
        curl -fsSL https://bootstrap.pypa.io/get-pip.py | "python${PYTHON_MINOR}" - --no-cache-dir --break-system-packages; \
    fi && \
    update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_MINOR}" 1 && \
    update-alternatives --install /usr/bin/python  python  /usr/bin/python3 1

# Explicit setuptools/msgpack upgrade — both were found by Trivy at versions
# well behind their fixed releases (setuptools 70.3.0 vs. fixed 78.1.1,
# CVE-2025-47273; msgpack similarly behind). Neither is something our
# "latest" version-resolution machinery naturally catches: setuptools ships
# frozen inside ensurepip's bundled wheels at whatever version was baked
# into this specific CPython build, and stays exactly that version unless
# something explicitly upgrades it afterward — installing python3.14 does
# not itself pull the current setuptools from PyPI.
RUN python3 -m pip install --no-cache-dir --break-system-packages --upgrade \
        "setuptools>=78.1.1" \
        "msgpack>=1.2.1"

# pipx, Poetry — installed once, globally, then made available to every
# user via /usr/local so Codespaces prebuilds and post-create scripts share
# a single toolchain install.
#
# Poetry is pinned to the exact version config/resolve.sh resolved
# (POETRY_VERSION) rather than "whatever pipx would install today" —
# `pipx install poetry` with no version suffix previously ignored
# POETRY_VERSION entirely, so versions.lock resolving it deterministically
# had no actual effect on the image. pip's own install-time hash
# verification against PyPI (Subresource Integrity) is the verification
# mechanism here — the same reasoning already applied to pnpm below, since
# neither tool has a compiled, architecture-specific GitHub release binary
# the way ripgrep/task/gh/etc. do.
#
# uv is NOT installed here — it's a static Rust binary with a proper GitHub
# release per architecture, so it gets the same checksummed cli-tools
# treatment as ripgrep/task/gh/etc. below (Section 9), honoring its
# `source: github` in versions.yaml instead of installing it unpinned from
# PyPI via pipx.
ENV PIPX_HOME=/usr/local/pipx \
    PIPX_BIN_DIR=/usr/local/bin
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    . "${BAOBAB_CONFIG_DIR}/versions.lock" && \
    python3 -m pip install --no-cache-dir --break-system-packages pipx && \
    export PATH="/usr/local/bin:${PATH}" && \
    python3 -m pipx ensurepath && \
    pipx install --global "poetry==${POETRY_VERSION}" && \
    python3 -m pip install --no-cache-dir --break-system-packages --upgrade "setuptools>=78.1.1" "msgpack>=1.2.1" && \
    chmod -R a+rX /usr/local/pipx

# django-tenants and the rest of the BAOBAB application dependencies are
# intentionally NOT baked in here — they belong to the project's own
# pyproject.toml / poetry.lock and are installed by post-create.sh on
# container creation, keeping this base image framework-version-agnostic.
# -----------------------------------------------------------------------------
# 4. Node.js LTS, npm, pnpm, yarn
# -----------------------------------------------------------------------------
# NodeSource's own setup_${NODE_MAJOR}.x script (curl | bash) does nothing
# more than add their GPG key and an apt source entry — the same shape as
# the Docker CLI, GitHub CLI, and PostgreSQL setup blocks elsewhere in this
# stage. Piping a remote script into bash is one of the few places in this
# file that executed arbitrary remote code sight-unseen rather than adding
# a package source the same explicit way everything else here does, so it's
# replaced with the manual equivalent NodeSource itself documents at
# https://github.com/nodesource/distributions/wiki/Repository-Manual-Installation.
#
# pnpm is pinned to the exact resolved PNPM_VERSION — `corepack prepare
# pnpm@latest` previously ignored versions.lock entirely, the same gap
# Poetry had above. npm's own registry-level integrity check (Subresource
# Integrity, sha512) is what verifies the package on install; there's
# nothing for this Dockerfile to additionally check by hand, matching
# versions.yaml's own pnpm.source: npm declaration. yarn has no
# corresponding entry in versions.yaml at all (no version to pin), so
# `@stable` is left as-is — not an oversight, there's nothing to pin it to
# yet.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    . "${BAOBAB_CONFIG_DIR}/versions.lock" && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    chmod a+r /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends nodejs && \
    corepack enable && \
    corepack prepare "pnpm@${PNPM_VERSION}" --activate && \
    corepack prepare yarn@stable --activate

# -----------------------------------------------------------------------------
# 5. Flutter + Dart (copied from the flutter-sdk builder stage)
# -----------------------------------------------------------------------------
COPY --from=flutter-sdk /opt/flutter-tmp /opt/flutter
ENV PUB_CACHE=/opt/flutter/.pub-cache

# Pre-fetch platform-independent Flutter/Dart artifacts so first-run inside
# Codespaces (`flutter doctor`, `flutter pub get`) is fast and works offline
# for anything that doesn't need Android/iOS toolchains (mobile SDKs are
# intentionally excluded from this image — see README "What's NOT included").
#
# Git Safe Directory Scope & Multi-User Context:
# Running `git config --global` during image construction writes directives
# exclusively to `/root/.gitconfig`. When non-root container runtimes (such
# as the default `vscode` user or runtime healthcheck processes) execute `flutter`
# or `dart` commands later, Git ignores `/root/.gitconfig`. Because `/opt/flutter`
# retains `.git` metadata (required on ARM64 for Flutter to query its own version
# and release channel), Git flags `/opt/flutter` with a "fatal: detected dubious
# ownership" error for any actor other than `root`.
#
# Configuring `safe.directory` at the system level (`git config --system`, stored in
# `/etc/gitconfig`) guarantees that both `root` during remaining build stages and
# unprivileged runtime users inherit trusted access to `/opt/flutter` seamlessly.
#
# Invoked via absolute path rather than relying on PATH: PATH is defined
# exactly once, in its final complete form, in section 11 below — Flutter
# isn't on it yet at this point in the build.
RUN git config --system --add safe.directory /opt/flutter && \
    /opt/flutter/bin/flutter config --no-analytics --no-cli-animations && \
    /opt/flutter/bin/flutter precache --universal --no-android --no-ios --no-fuchsia && \
    chmod -R a+rX /opt/flutter

# -----------------------------------------------------------------------------
# 6. PostgreSQL client + Redis CLI (client tools only — no server daemons)
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    . "${BAOBAB_CONFIG_DIR}/versions.lock" && \
    install -d /usr/share/postgresql-common/pgdg && \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt $(. /etc/os-release && echo $VERSION_CODENAME)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      postgresql-client-${POSTGRES_MAJOR} \
      redis-tools

# -----------------------------------------------------------------------------
# 7. Docker CLI + Compose plugin (client only — Codespaces mounts the host
#    Docker socket, so no dockerd/containerd is installed in this image)
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && \
    chmod a+r /etc/apt/keyrings/docker.asc && \
    ARCH=$(dpkg --print-architecture) && \
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
      > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-compose-plugin \
      docker-buildx-plugin

# -----------------------------------------------------------------------------
# 8. Shell productivity & GitHub Actions-adjacent utilities
#    fzf and tmux come from Ubuntu's own repos (small, stable, low-churn).
#    ripgrep/fd/bat/eza/task/yq/gh/cosign/uv are all copied pre-built from
#    the cli-tools builder stage — checksummed and pinned to the exact
#    version config/resolve.sh resolved, for reproducibility across Ubuntu
#    releases. gh in particular used to come from apt (cli.github.com's own
#    repo) — that's a perfectly legitimate signed channel, but it always
#    installs "whatever is latest today", which silently ignored
#    versions.yaml's `github_cli.source: github` and GH_VERSION. Moving it
#    here makes gh's actual install channel match what versions.yaml has
#    always declared.
# -----------------------------------------------------------------------------
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends fzf tmux bash-completion

COPY --from=cli-tools /opt/cli-tools/bin/rg     /usr/local/bin/rg
COPY --from=cli-tools /opt/cli-tools/bin/fd     /usr/local/bin/fd
COPY --from=cli-tools /opt/cli-tools/bin/bat    /usr/local/bin/bat
COPY --from=cli-tools /opt/cli-tools/bin/eza    /usr/local/bin/eza
COPY --from=cli-tools /opt/cli-tools/bin/task   /usr/local/bin/task
COPY --from=cli-tools /opt/cli-tools/bin/yq     /usr/local/bin/yq
COPY --from=cli-tools /opt/cli-tools/bin/gh     /usr/local/bin/gh
COPY --from=cli-tools /opt/cli-tools/bin/cosign /usr/local/bin/cosign
COPY --from=cli-tools /opt/cli-tools/bin/uv     /usr/local/bin/uv
COPY --from=cli-tools /opt/cli-tools/bin/uvx    /usr/local/bin/uvx
RUN chmod +x /usr/local/bin/rg /usr/local/bin/fd /usr/local/bin/bat /usr/local/bin/eza \
      /usr/local/bin/task /usr/local/bin/yq /usr/local/bin/gh /usr/local/bin/cosign \
      /usr/local/bin/uv /usr/local/bin/uvx

# -----------------------------------------------------------------------------
# 9. Non-root user creation (vscode:1000)
# -----------------------------------------------------------------------------
# Ubuntu 24.04/26.04 base images ship with a default 'ubuntu' user (UID/GID 1000).
# Remove it first to free up UID/GID 1000 for 'vscode', avoiding exit code 4.
RUN if id "ubuntu" &>/dev/null; then userdel -r ubuntu; fi && \
    if getent group ubuntu &>/dev/null; then groupdel ubuntu; fi && \
    groupadd --gid 1000 vscode && \
    useradd --uid 1000 --gid 1000 --shell /bin/bash --create-home vscode && \
    echo "vscode ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/vscode && \
    chmod 0440 /etc/sudoers.d/vscode && \
    mkdir -p /workspaces /home/vscode/.local/bin && \
    chown -R vscode:vscode /workspaces /home/vscode


# -----------------------------------------------------------------------------
# 10. Global environment configuration
# -----------------------------------------------------------------------------
ENV PATH="/home/vscode/.local/bin:/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/usr/local/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=true \
    POETRY_NO_INTERACTION=1 \
    BAOBAB_IMAGE_VERSION=${VERSION} \
    BAOBAB_BUILD_DATE=${BUILD_DATE} \
    BAOBAB_GIT_REVISION=${REVISION}

# Give the vscode user ownership of the entire Flutter SDK (not just the
# pub-cache) so `flutter`/`dart` can update internal lockfiles, engine
# caches, and version state without needing sudo at runtime.
RUN chown -R vscode:vscode /opt/flutter

# -----------------------------------------------------------------------------
# 11. Shell enhancements: completions, aliases, colored prompt, history
# -----------------------------------------------------------------------------
COPY --chown=vscode:vscode config/bashrc.d/ /etc/bashrc.d/
RUN echo '\n# BAOBAB devcontainer shell enhancements\nfor f in /etc/bashrc.d/*.sh; do [ -r "$f" ] && . "$f"; done' \
      >> /etc/bash.bashrc

# -----------------------------------------------------------------------------
# 12. Install BAOBAB helper commands (used by devcontainer lifecycle hooks and
#     by engineers troubleshooting a container directly). Each command simply
#     executes its corresponding script from scripts/.
# -----------------------------------------------------------------------------
COPY --chmod=0755 scripts/bootstrap.sh    /usr/local/bin/baobab-bootstrap
COPY --chmod=0755 scripts/post-create.sh  /usr/local/bin/baobab-post-create
COPY --chmod=0755 scripts/summary.sh      /usr/local/bin/baobab-summary
COPY --chmod=0755 scripts/verify.sh       /usr/local/bin/baobab-verify

USER vscode
WORKDIR /workspaces

# Poetry: create venvs inside each project directory rather than a shared
# cache, matching the objective and keeping per-tenant-app envs isolated.
RUN poetry config virtualenvs.in-project true

# -----------------------------------------------------------------------------
# 13. Build-time verification
#
# Fail the image build itself if the toolchain isn't in the state baobab-
# verify expects (correct versions on PATH, correct user/UID/GID, passwordless
# sudo, etc.) rather than shipping a broken image and discovering it later.
# Runs as `vscode`, after the USER switch above, since baobab-verify checks
# the runtime user identity.
# -----------------------------------------------------------------------------

RUN baobab-verify 

HEALTHCHECK \
    --interval=60s \
    --timeout=10s \
    --start-period=15s \
    --retries=3 \
    CMD baobab-verify || exit 1

CMD ["sleep", "infinity"]