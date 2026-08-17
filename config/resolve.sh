#!/usr/bin/env bash
# ==============================================================================
# BAOBAB Enterprise Platform
# Version Resolver
#
# File: config/resolve.sh
#
# Purpose:
#   Reads config/versions.yaml and generates:
#     - config/versions.lock (consumed by the Dockerfile and helper scripts)
#     - .python-version at the repository root (consumed by uv, so the local
#       Python toolchain used for docs/testing stays pinned to the exact
#       same minor version the container itself ships, without a second
#       hand-maintained copy of that version anywhere)
#
# Requirements:
#   - bash
#   - yq v4+
#   - curl
#
# Usage:
#   ./config/resolve.sh
#
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Directories
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MANIFEST="${SCRIPT_DIR}/versions.yaml"
LOCKFILE="${SCRIPT_DIR}/versions.lock"
PYTHON_VERSION_FILE="${REPO_ROOT}/.python-version"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

info() {
    printf "[INFO] %s\n" "$*" >&2
}

warn() {
    printf "[WARN] %s\n" "$*" >&2
}

error() {
    printf "[ERROR] %s\n" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------------------

command -v yq >/dev/null 2>&1 \
    || die "yq is not installed."

command -v curl >/dev/null 2>&1 \
    || die "curl is not installed."

[[ -f "$MANIFEST" ]] \
    || die "Cannot find ${MANIFEST}"

# ------------------------------------------------------------------------------
# Temporary working files
#
# Everything under here is cleaned up on exit regardless of how the script
# terminates. FLUTTER_MANIFEST_FILE is populated lazily by the Flutter
# section below, once, and reused by every yq query against it rather than
# re-downloading the same ~large JSON document per field.
# ------------------------------------------------------------------------------

FLUTTER_MANIFEST_FILE="$(mktemp)"
trap 'rm -f "${FLUTTER_MANIFEST_FILE}"' EXIT

# ------------------------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------------------------

yaml() {
    yq -r "$1" "$MANIFEST"
}

github_latest() {

    local repo="$1"

    curl -fsSL \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
        "https://api.github.com/repos/${repo}/releases/latest" |
        yq -r '.tag_name' |
        sed 's/^v//'
}

# Latest published version of an npm package, per the registry itself —
# used for pnpm (versions.yaml: package_managers.pnpm.source: npm). No
# corresponding checksum is resolved here: npm's own client verifies each
# installed package's tarball against the integrity hash the registry
# itself publishes (Subresource Integrity, sha512) as a normal part of
# `npm install`/`npm install -g`. That is a different, already-verifying
# channel from "curl a GitHub release asset and check it ourselves" — there
# is nothing for resolve.sh to additionally pin beyond the exact version
# number, which is what makes the install deterministic across rebuilds.
npm_latest_version() {

    local package="$1"

    curl -fsSL "https://registry.npmjs.org/${package}/latest" |
        yq -p json -o json -r '.version'
}

# ------------------------------------------------------------------------------
# Checksum verification data
#
# GitHub computes and exposes an immutable SHA256 digest for every release
# asset uploaded since ~June 2025 (see
# https://github.blog/changelog/2025-06-03-releases-now-expose-digests-for-release-assets/),
# available via the standard Releases API regardless of whether the upstream
# project also publishes its own checksum file (fd and bat do not; ripgrep
# does; eza does not). Using this single, GitHub-native mechanism means every
# binary the Dockerfile downloads can be verified the same way, without
# depending on each upstream project's own checksum convention. This is now
# also how task, yq, gh, and cosign are verified below — the same mechanism,
# just applied to four more tools.
#
# Looked up by the exact resolved tag (releases/tags/<tag>), not /latest, so
# the digest always matches the precise asset the Dockerfile will download
# later — even if upstream ships a newer release between resolve.sh running
# and the Docker build consuming this lock file.
#
# Live-verified (2026-07-29) against BurntSushi/ripgrep, sharkdp/fd,
# sharkdp/bat, and eza-community/eza: full round-trip of digest fetch ->
# asset download -> `sha256sum -c` pass, plus a tampered-file negative
# control that correctly fails verification. Asset filenames for task, yq,
# uv, gh, and cosign were live-verified (2026-08-06) by probing their actual
# release-download URLs directly.
# ------------------------------------------------------------------------------

github_asset_digest() {

    local repo="$1"
    local tag="$2"
    local asset_name="$3"
    local digest

    digest=$(curl -fsSL \
        ${GITHUB_TOKEN:+-H "Authorization: Bearer ${GITHUB_TOKEN}"} \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" |
        yq -p json -o json -r ".assets[] | select(.name == \"${asset_name}\") | .digest")

    digest="${digest#sha256:}"

    if [[ -z "$digest" || "$digest" == "null" ]]; then
        die "GitHub returned no SHA256 digest for ${repo}@${tag} asset '${asset_name}'. Either the asset name no longer matches the release, or this release predates GitHub's digest feature — check https://github.com/${repo}/releases/tag/${tag} directly."
    fi

    printf "%s" "$digest"
}

# ------------------------------------------------------------------------------
# Read versions
# ------------------------------------------------------------------------------

PYTHON_VERSION=$(yaml '.languages.python.version')

NODE_MAJOR=$(yaml '.languages.node.major')

POSTGRES_MAJOR=$(yaml '.database.postgresql.major')

# ------------------------------------------------------------------------------
# Flutter
#
# The Linux SDK is x64-only. Live-verified against Flutter's own release
# manifest (2026-08-06, current stable 3.44.8): every release entry back to
# the 2.x series carries "dart_sdk_arch": "x64" and no arm64 archive of any
# kind — there is no Linux arm64 tarball to download and checksum, on any
# channel, at any version. That is not a gap in this script; it is a real
# gap in what Flutter ships. See "Flutter arm64" below for how the
# Dockerfile is expected to build for arm64 instead.
# ------------------------------------------------------------------------------

FLUTTER_VERSION=$(yaml '.languages.flutter.version')

info "Fetching Flutter release manifest..."
curl -fsSL \
    "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" \
    -o "${FLUTTER_MANIFEST_FILE}"

if [[ "$FLUTTER_VERSION" == "latest" ]]; then
    info "Resolving latest Flutter release..."
    FLUTTER_VERSION=$(yq -p json -o json -r '
        .current_release.stable as $stable
        | .releases[]
        | select(.hash==$stable)
        | .version
    ' "${FLUTTER_MANIFEST_FILE}")
fi

FLUTTER_RELEASE_QUERY=".releases[] | select(.version == \"${FLUTTER_VERSION}\" and .channel == \"stable\")"

FLUTTER_BASE_URL=$(yq -p json -o json -r '.base_url' "${FLUTTER_MANIFEST_FILE}")

FLUTTER_ARCHIVE_PATH=$(yq -p json -o json -r "${FLUTTER_RELEASE_QUERY} | .archive" "${FLUTTER_MANIFEST_FILE}" | head -n1)
FLUTTER_ARCHIVE_AMD64="${FLUTTER_BASE_URL}/${FLUTTER_ARCHIVE_PATH}"

FLUTTER_SHA256_AMD64=$(yq -p json -o json -r "${FLUTTER_RELEASE_QUERY} | .sha256" "${FLUTTER_MANIFEST_FILE}" | head -n1)

[[ -n "$FLUTTER_ARCHIVE_PATH" && "$FLUTTER_ARCHIVE_PATH" != "null" ]] \
    || die "Flutter's release manifest has no Linux archive for stable version ${FLUTTER_VERSION}."

[[ -n "$FLUTTER_SHA256_AMD64" && "$FLUTTER_SHA256_AMD64" != "null" ]] \
    || die "Flutter's release manifest has no sha256 for stable version ${FLUTTER_VERSION}."

# -------------------------------------------------------------------------
# Flutter arm64
#
# Since there is no arm64 tarball to check a SHA256 against, the zero-trust
# equivalent is a pinned git clone: FLUTTER_GIT_REF is the exact commit on
# flutter/flutter that this stable version's manifest entry (.hash) points
# to. A git commit hash IS a content-addressed integrity guarantee in
# exactly the way a SHA256 is for a tarball — cloning at this exact commit
# can only ever produce this exact source tree. The Dockerfile's arm64
# branch is expected to build the engine/tool binaries from this checkout
# rather than extract a prebuilt archive.
# -------------------------------------------------------------------------

FLUTTER_GIT_REF=$(yq -p json -o json -r "${FLUTTER_RELEASE_QUERY} | .hash" "${FLUTTER_MANIFEST_FILE}" | head -n1)

[[ -n "$FLUTTER_GIT_REF" && "$FLUTTER_GIT_REF" != "null" ]] \
    || die "Flutter's release manifest has no commit hash for stable version ${FLUTTER_VERSION}."

# ------------------------------------------------------------------------------
# GitHub tools
# ------------------------------------------------------------------------------

resolve_github() {

    local yaml_path="$1"
    local repo="$2"

    local version

    version=$(yaml "$yaml_path")

    if [[ "$version" == "latest" ]]; then
        info "Resolving ${repo}..."
        github_latest "$repo"
    else
        printf "%s" "$version"
    fi
}

TASK_VERSION=$(resolve_github '.utilities.task.version' 'go-task/task')

RIPGREP_VERSION=$(resolve_github '.utilities.ripgrep.version' 'BurntSushi/ripgrep')

FD_VERSION=$(resolve_github '.utilities.fd.version' 'sharkdp/fd')

BAT_VERSION=$(resolve_github '.utilities.bat.version' 'sharkdp/bat')

EZA_VERSION=$(resolve_github '.utilities.eza.version' 'eza-community/eza')

YQ_VERSION=$(resolve_github '.utilities.yq.version' 'mikefarah/yq')

UV_VERSION=$(resolve_github '.package_managers.uv.version' 'astral-sh/uv')

GH_VERSION=$(resolve_github '.development.github_cli.version' 'cli/cli')

COSIGN_VERSION=$(resolve_github '.security.cosign.version' 'sigstore/cosign')

# ------------------------------------------------------------------------------
# pnpm
#
# versions.yaml declares package_managers.pnpm.source as npm, not github —
# deliberately: pnpm is installed via the npm registry, and npm's own
# install-time integrity check (Subresource Integrity, sha512) is what
# verifies it, not a SHA256 we compute here. See npm_latest_version() above
# for the full rationale. Only the exact version is pinned, for
# reproducibility across rebuilds.
# ------------------------------------------------------------------------------

PNPM_VERSION=$(yaml '.package_managers.pnpm.version')

if [[ "$PNPM_VERSION" == "latest" ]]; then
    info "Resolving pnpm..."
    PNPM_VERSION=$(npm_latest_version "pnpm")
fi

# ------------------------------------------------------------------------------
# Poetry
#
# Unlike task/yq/uv/gh/cosign, Poetry has no compiled, architecture-specific
# release binary to download and checksum — it's a pure-Python package,
# installed the same way regardless of amd64 vs arm64. Same reasoning as
# pnpm above: only the exact version is pinned here (resolved from GitHub
# tags, since that's Poetry's own source of truth for version numbers);
# pip's own install-time hash verification against PyPI (the same
# Subresource Integrity mechanism, just for Python packages instead of npm
# ones) is what actually verifies the bytes, once the Dockerfile installs
# this exact pinned version rather than whatever "poetry" without a version
# suffix would resolve to on the day of the build.
#
# NOTE: an earlier version of this script also resolved a separate pinned
# commit for python-poetry/install.python-poetry.org, intending to fetch
# Poetry via its official installer script rather than pip/pipx. That was
# dropped: pipx installing an exact, pinned version already gets the same
# verified-install guarantee via pip's own hash checking, with one fewer
# moving part. versions.yaml's package_managers.poetry.source has been
# updated from "github" to "pypi" to reflect this.
# ------------------------------------------------------------------------------

POETRY_VERSION=$(resolve_github '.package_managers.poetry.version' 'python-poetry/poetry')

# ------------------------------------------------------------------------------
# Checksums: ripgrep, fd, bat, eza (per target architecture)
#
# Asset filenames are computed here — the single source of truth — and
# written to versions.lock alongside their digests, so the Dockerfile no
# longer reconstructs filenames independently. A filename typo here simply
# 404s at build time instead of silently verifying against the wrong asset.
# ------------------------------------------------------------------------------

info "Fetching ripgrep checksums..."
RIPGREP_ASSET_AMD64="ripgrep-${RIPGREP_VERSION}-x86_64-unknown-linux-musl.tar.gz"
RIPGREP_SHA256_AMD64=$(github_asset_digest "BurntSushi/ripgrep" "${RIPGREP_VERSION}" "${RIPGREP_ASSET_AMD64}")
RIPGREP_ASSET_ARM64="ripgrep-${RIPGREP_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
RIPGREP_SHA256_ARM64=$(github_asset_digest "BurntSushi/ripgrep" "${RIPGREP_VERSION}" "${RIPGREP_ASSET_ARM64}")

info "Fetching fd checksums..."
FD_ASSET_AMD64="fd-v${FD_VERSION}-x86_64-unknown-linux-musl.tar.gz"
FD_SHA256_AMD64=$(github_asset_digest "sharkdp/fd" "v${FD_VERSION}" "${FD_ASSET_AMD64}")
FD_ASSET_ARM64="fd-v${FD_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
FD_SHA256_ARM64=$(github_asset_digest "sharkdp/fd" "v${FD_VERSION}" "${FD_ASSET_ARM64}")

info "Fetching bat checksums..."
BAT_ASSET_AMD64="bat-v${BAT_VERSION}-x86_64-unknown-linux-musl.tar.gz"
BAT_SHA256_AMD64=$(github_asset_digest "sharkdp/bat" "v${BAT_VERSION}" "${BAT_ASSET_AMD64}")
BAT_ASSET_ARM64="bat-v${BAT_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
BAT_SHA256_ARM64=$(github_asset_digest "sharkdp/bat" "v${BAT_VERSION}" "${BAT_ASSET_ARM64}")

info "Fetching eza checksums..."
EZA_ASSET_AMD64="eza_x86_64-unknown-linux-gnu.tar.gz"
EZA_SHA256_AMD64=$(github_asset_digest "eza-community/eza" "v${EZA_VERSION}" "${EZA_ASSET_AMD64}")
EZA_ASSET_ARM64="eza_aarch64-unknown-linux-gnu.tar.gz"
EZA_SHA256_ARM64=$(github_asset_digest "eza-community/eza" "v${EZA_VERSION}" "${EZA_ASSET_ARM64}")

# ------------------------------------------------------------------------------
# Checksums: task, yq, uv, gh, cosign (per target architecture)
#
# Same github_asset_digest() mechanism as above — extended to the tools the
# Dockerfile already expects lockfile variables for (cli-tools, python-tools
# stages) but that resolve.sh had never actually resolved checksums for
# until now.
# ------------------------------------------------------------------------------

info "Fetching task checksums..."
TASK_ASSET_AMD64="task_linux_amd64.tar.gz"
TASK_SHA256_AMD64=$(github_asset_digest "go-task/task" "v${TASK_VERSION}" "${TASK_ASSET_AMD64}")
TASK_ASSET_ARM64="task_linux_arm64.tar.gz"
TASK_SHA256_ARM64=$(github_asset_digest "go-task/task" "v${TASK_VERSION}" "${TASK_ASSET_ARM64}")

info "Fetching yq checksums..."
YQ_ASSET_AMD64="yq_linux_amd64"
YQ_SHA256_AMD64=$(github_asset_digest "mikefarah/yq" "v${YQ_VERSION}" "${YQ_ASSET_AMD64}")
YQ_ASSET_ARM64="yq_linux_arm64"
YQ_SHA256_ARM64=$(github_asset_digest "mikefarah/yq" "v${YQ_VERSION}" "${YQ_ASSET_ARM64}")

info "Fetching uv checksums..."
UV_ASSET_AMD64="uv-x86_64-unknown-linux-gnu.tar.gz"
UV_SHA256_AMD64=$(github_asset_digest "astral-sh/uv" "${UV_VERSION}" "${UV_ASSET_AMD64}")
UV_ASSET_ARM64="uv-aarch64-unknown-linux-gnu.tar.gz"
UV_SHA256_ARM64=$(github_asset_digest "astral-sh/uv" "${UV_VERSION}" "${UV_ASSET_ARM64}")

info "Fetching gh checksums..."
GH_ASSET_AMD64="gh_${GH_VERSION}_linux_amd64.tar.gz"
GH_SHA256_AMD64=$(github_asset_digest "cli/cli" "v${GH_VERSION}" "${GH_ASSET_AMD64}")
GH_ASSET_ARM64="gh_${GH_VERSION}_linux_arm64.tar.gz"
GH_SHA256_ARM64=$(github_asset_digest "cli/cli" "v${GH_VERSION}" "${GH_ASSET_ARM64}")

info "Fetching cosign checksums..."
COSIGN_ASSET_AMD64="cosign-linux-amd64"
COSIGN_SHA256_AMD64=$(github_asset_digest "sigstore/cosign" "v${COSIGN_VERSION}" "${COSIGN_ASSET_AMD64}")
COSIGN_ASSET_ARM64="cosign-linux-arm64"
COSIGN_SHA256_ARM64=$(github_asset_digest "sigstore/cosign" "v${COSIGN_VERSION}" "${COSIGN_ASSET_ARM64}")

# ------------------------------------------------------------------------------
# Generate lock file
# ------------------------------------------------------------------------------

cat > "$LOCKFILE" <<EOF
# ==============================================================================
# BAOBAB Version Lock File
#
# Generated automatically by resolve.sh
#
# DO NOT EDIT
# ==============================================================================

export UBUNTU_VERSION=$(yaml '.platform.ubuntu.version')

export PYTHON_VERSION=${PYTHON_VERSION}

export NODE_MAJOR=${NODE_MAJOR}

export FLUTTER_VERSION=${FLUTTER_VERSION}
export FLUTTER_ARCHIVE_AMD64=${FLUTTER_ARCHIVE_AMD64}
export FLUTTER_SHA256_AMD64=${FLUTTER_SHA256_AMD64}
export FLUTTER_GIT_REF=${FLUTTER_GIT_REF}

export POSTGRES_MAJOR=${POSTGRES_MAJOR}

export TASK_VERSION=${TASK_VERSION}
export TASK_ASSET_AMD64=${TASK_ASSET_AMD64}
export TASK_SHA256_AMD64=${TASK_SHA256_AMD64}
export TASK_ASSET_ARM64=${TASK_ASSET_ARM64}
export TASK_SHA256_ARM64=${TASK_SHA256_ARM64}

export RIPGREP_VERSION=${RIPGREP_VERSION}
export RIPGREP_ASSET_AMD64=${RIPGREP_ASSET_AMD64}
export RIPGREP_SHA256_AMD64=${RIPGREP_SHA256_AMD64}
export RIPGREP_ASSET_ARM64=${RIPGREP_ASSET_ARM64}
export RIPGREP_SHA256_ARM64=${RIPGREP_SHA256_ARM64}

export FD_VERSION=${FD_VERSION}
export FD_ASSET_AMD64=${FD_ASSET_AMD64}
export FD_SHA256_AMD64=${FD_SHA256_AMD64}
export FD_ASSET_ARM64=${FD_ASSET_ARM64}
export FD_SHA256_ARM64=${FD_SHA256_ARM64}

export BAT_VERSION=${BAT_VERSION}
export BAT_ASSET_AMD64=${BAT_ASSET_AMD64}
export BAT_SHA256_AMD64=${BAT_SHA256_AMD64}
export BAT_ASSET_ARM64=${BAT_ASSET_ARM64}
export BAT_SHA256_ARM64=${BAT_SHA256_ARM64}

export EZA_VERSION=${EZA_VERSION}
export EZA_ASSET_AMD64=${EZA_ASSET_AMD64}
export EZA_SHA256_AMD64=${EZA_SHA256_AMD64}
export EZA_ASSET_ARM64=${EZA_ASSET_ARM64}
export EZA_SHA256_ARM64=${EZA_SHA256_ARM64}

export YQ_VERSION=${YQ_VERSION}
export YQ_ASSET_AMD64=${YQ_ASSET_AMD64}
export YQ_SHA256_AMD64=${YQ_SHA256_AMD64}
export YQ_ASSET_ARM64=${YQ_ASSET_ARM64}
export YQ_SHA256_ARM64=${YQ_SHA256_ARM64}

export UV_VERSION=${UV_VERSION}
export UV_ASSET_AMD64=${UV_ASSET_AMD64}
export UV_SHA256_AMD64=${UV_SHA256_AMD64}
export UV_ASSET_ARM64=${UV_ASSET_ARM64}
export UV_SHA256_ARM64=${UV_SHA256_ARM64}

export GH_VERSION=${GH_VERSION}
export GH_ASSET_AMD64=${GH_ASSET_AMD64}
export GH_SHA256_AMD64=${GH_SHA256_AMD64}
export GH_ASSET_ARM64=${GH_ASSET_ARM64}
export GH_SHA256_ARM64=${GH_SHA256_ARM64}

export COSIGN_VERSION=${COSIGN_VERSION}
export COSIGN_ASSET_AMD64=${COSIGN_ASSET_AMD64}
export COSIGN_SHA256_AMD64=${COSIGN_SHA256_AMD64}
export COSIGN_ASSET_ARM64=${COSIGN_ASSET_ARM64}
export COSIGN_SHA256_ARM64=${COSIGN_SHA256_ARM64}

export PNPM_VERSION=${PNPM_VERSION}

export POETRY_VERSION=${POETRY_VERSION}

EOF

chmod 644 "$LOCKFILE"

info "Generated ${LOCKFILE}"

# ------------------------------------------------------------------------------
# Generate .python-version
# ------------------------------------------------------------------------------

PYTHON_MINOR="${PYTHON_VERSION%.*}"

printf '%s\n' "${PYTHON_MINOR}" > "${PYTHON_VERSION_FILE}"

chmod 644 "${PYTHON_VERSION_FILE}"

info "Generated ${PYTHON_VERSION_FILE} (${PYTHON_MINOR})"

echo
cat "$LOCKFILE"
echo
echo "${PYTHON_VERSION_FILE}:"
cat "${PYTHON_VERSION_FILE}"
echo

info "Version resolution complete."