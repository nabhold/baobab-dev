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

flutter_latest() {

    curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" |
        yq -r '
            .current_release.stable as $stable
            | .releases[]
            | select(.hash==$stable)
            | .version
        '
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
# depending on each upstream project's own checksum convention.
#
# Looked up by the exact resolved tag (releases/tags/<tag>), not /latest, so
# the digest always matches the precise asset the Dockerfile will download
# later — even if upstream ships a newer release between resolve.sh running
# and the Docker build consuming this lock file.
#
# Live-verified (2026-07-29) against BurntSushi/ripgrep, sharkdp/fd,
# sharkdp/bat, and eza-community/eza: full round-trip of digest fetch ->
# asset download -> `sha256sum -c` pass, plus a tampered-file negative
# control that correctly fails verification.
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

# Looks up the sha256 checksum for a specific resolved Flutter version (not
# just "whatever is current stable right now") from Flutter's own release
# manifest, which publishes a sha256 field per release — see
# https://github.com/flutter/flutter/issues/28465. Matching by exact version
# means this stays correct even if versions.yaml ever pins an older Flutter
# release instead of "latest".
flutter_sha256_for_version() {

    local version="$1"

    curl -fsSL \
        "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" |
        yq -r ".releases[] | select(.version == \"${version}\" and .channel == \"stable\") | .sha256" |
        head -n1
}

# npm-sourced tools (pnpm, turbo, playwright, sharp, lighthouse) have no
# GitHub Releases API equivalent worth using here — they're versioned and
# distributed via the npm registry itself, which publishes a canonical
# "latest" endpoint per package. This is the npm-registry analogue of
# github_latest()/resolve_github() below, not a replacement for them: any
# tool actually fetched as a GitHub release binary (task, uv, gh, cosign)
# still uses the GitHub path, since npm's registry has no equivalent
# concept of a platform-specific release asset for those.
npm_latest() {

    local package="$1"

    curl -fsSL "https://registry.npmjs.org/${package}/latest" |
        yq -p json -o json -r '.version'
}

resolve_npm() {

    local yaml_path="$1"
    local package="$2"

    local version

    version=$(yaml "$yaml_path")

    if [[ "$version" == "latest" ]]; then
        info "Resolving ${package} (npm)..."
        npm_latest "$package"
    else
        printf "%s" "$version"
    fi
}

# ------------------------------------------------------------------------------
# Read versions
# ------------------------------------------------------------------------------

PYTHON_VERSION=$(yaml '.languages.python.version')

NODE_MAJOR=$(yaml '.languages.node.major')

POSTGRES_MAJOR=$(yaml '.database.postgresql.major')

# ------------------------------------------------------------------------------
# Flutter
# ------------------------------------------------------------------------------

FLUTTER_VERSION=$(yaml '.languages.flutter.version')

if [[ "$FLUTTER_VERSION" == "latest" ]]; then
    info "Resolving latest Flutter release..."
    FLUTTER_VERSION=$(flutter_latest)
fi

info "Fetching Flutter SDK checksum for ${FLUTTER_VERSION}..."
FLUTTER_SHA256=$(flutter_sha256_for_version "${FLUTTER_VERSION}")

[[ -n "$FLUTTER_SHA256" && "$FLUTTER_SHA256" != "null" ]] \
    || die "Flutter's release manifest has no sha256 for stable version ${FLUTTER_VERSION}."

# ------------------------------------------------------------------------------
# Package managers (pnpm, Poetry, uv)
#
# FIX: these three were previously never resolved at all — versions.lock
# never contained PNPM_VERSION, POETRY_VERSION, or UV_VERSION despite the
# Dockerfile depending on all three (corepack prepare "pnpm@${PNPM_VERSION}",
# pipx install "poetry==${POETRY_VERSION}", and the entire uv fetch_verify
# block in the cli-tools stage). Under the Dockerfile's own set -u contexts
# this is a genuine unbound-variable failure waiting to happen the next time
# this resolver actually runs in CI, not a hypothetical.
#
# pnpm: source: npm in versions.yaml — resolved via the npm registry, via
#   resolve_npm() above, which is already defined by this point in the file.
#
# Poetry and uv both resolve via resolve_github(), which is NOT defined
# until the "GitHub tools" section below — so those two are resolved
# further down in this file (immediately after that function's definition,
# alongside TASK_VERSION/RIPGREP_VERSION/etc.), not here. Splitting them
# was a real bug in an earlier version of this fix: PNPM_VERSION uses a
# different helper (resolve_npm, defined above) and has no such ordering
# constraint, so it stays here; POETRY_VERSION/UV_VERSION do not.
# ------------------------------------------------------------------------------

PNPM_VERSION=$(resolve_npm '.package_managers.pnpm.version' 'pnpm')

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

# POETRY_VERSION / UV_VERSION — moved here deliberately, not left where
# PNPM_VERSION is defined above. Both call resolve_github(), which only
# exists from this point in the file onward; calling it earlier is exactly
# the "resolve_github: command not found" failure this fix corrects.
#
# Poetry: source: github in versions.yaml — version discovery happens
#   against python-poetry/poetry's tags even though the actual install is a
#   pipx/PyPI install, not a GitHub binary download; no asset/checksum
#   pair needed, pip's own install-time SRI hash verification covers it.
# uv: source: github — a real compiled binary per architecture, needs the
#   same asset+checksum treatment as ripgrep/fd/bat/eza below, not just a
#   bare version string (see the checksum block further down).
POETRY_VERSION=$(resolve_github '.package_managers.poetry.version' 'python-poetry/poetry')

UV_VERSION=$(resolve_github '.package_managers.uv.version' 'astral-sh/uv')

TASK_VERSION=$(resolve_github '.utilities.task.version' 'go-task/task')

RIPGREP_VERSION=$(resolve_github '.utilities.ripgrep.version' 'BurntSushi/ripgrep')

FD_VERSION=$(resolve_github '.utilities.fd.version' 'sharkdp/fd')

BAT_VERSION=$(resolve_github '.utilities.bat.version' 'sharkdp/bat')

EZA_VERSION=$(resolve_github '.utilities.eza.version' 'eza-community/eza')

YQ_VERSION=$(resolve_github '.utilities.yq.version' 'mikefarah/yq')

GH_VERSION=$(resolve_github '.development.github_cli.version' 'cli/cli')

COSIGN_VERSION=$(resolve_github '.security.cosign.version' 'sigstore/cosign')

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
# FIX: checksums for task, uv, gh, cosign
#
# The Dockerfile's cli-tools stage has referenced TASK_ASSET_*/TASK_SHA256_*,
# UV_ASSET_*/UV_SHA256_*, GH_ASSET_*/GH_SHA256_*, and COSIGN_ASSET_*/
# COSIGN_SHA256_* since the "Wired up every checksum config/resolve.sh now
# computes" change — but this resolver never actually computed any of them.
# Under `set -euo pipefail` (explicitly set at the top of that RUN block),
# the very first missing one (`${!TASK_ASSET}`) would abort the entire
# cli-tools stage with "unbound variable" the next time this resolver's
# output was actually consumed by a real `docker build`.
#
# Asset naming per tool (verified against each project's actual GitHub
# Releases, not assumed from convention):
#   task   — task_linux_<arch>.tar.gz,                 tag v<version>
#   uv     — uv-<arch-triple>-unknown-linux-gnu.tar.gz, tag <version> (no v)
#   gh     — gh_<version>_linux_<arch>.tar.gz,          tag v<version>
#   cosign — cosign-linux-<arch> (RAW BINARY, no archive), tag v<version>
# ------------------------------------------------------------------------------

info "Fetching task checksums..."
TASK_ASSET_AMD64="task_linux_amd64.tar.gz"
TASK_SHA256_AMD64=$(github_asset_digest "go-task/task" "v${TASK_VERSION}" "${TASK_ASSET_AMD64}")
TASK_ASSET_ARM64="task_linux_arm64.tar.gz"
TASK_SHA256_ARM64=$(github_asset_digest "go-task/task" "v${TASK_VERSION}" "${TASK_ASSET_ARM64}")

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
# NEW: frontend_tooling (turbo, playwright, sharp, lighthouse)
#
# Backs the `frontend`/`frontend-e2e` Dockerfile targets (ADR-0001,
# nabhold/shared) — all npm-sourced, resolved the same way as pnpm above.
# None of these have a compiled per-architecture GitHub release binary the
# way ripgrep/task/uv/gh/cosign do; npm's own install-time integrity
# checking is the verification mechanism, same reasoning already applied
# to pnpm/Poetry.
# ------------------------------------------------------------------------------

TURBO_VERSION=$(resolve_npm '.frontend_tooling.turbo.version' 'turbo')

PLAYWRIGHT_VERSION=$(resolve_npm '.frontend_tooling.playwright.version' 'playwright')

SHARP_VERSION=$(resolve_npm '.frontend_tooling.sharp.version' 'sharp')

LIGHTHOUSE_VERSION=$(resolve_npm '.frontend_tooling.lighthouse.version' 'lighthouse')

# Derived, not resolved from an external source: the minor version (e.g.
# "3.14" from "3.14.6") selects the python<MINOR> binary name and feeds
# .python-version below. Computed once, here, so both versions.lock and
# .python-version derive from the exact same value. Previously this was
# computed only after the lock-file heredoc closed, so PYTHON_MINOR never
# reached versions.lock -- any consumer sourcing it (post-create.sh) hit
# "PYTHON_MINOR: unbound variable" under set -u.
PYTHON_MINOR="${PYTHON_VERSION%.*}"

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
export PYTHON_MINOR=${PYTHON_MINOR}

export NODE_MAJOR=${NODE_MAJOR}

export FLUTTER_VERSION=${FLUTTER_VERSION}
export FLUTTER_SHA256=${FLUTTER_SHA256}

export POSTGRES_MAJOR=${POSTGRES_MAJOR}

export PNPM_VERSION=${PNPM_VERSION}
export POETRY_VERSION=${POETRY_VERSION}

export UV_VERSION=${UV_VERSION}
export UV_ASSET_AMD64=${UV_ASSET_AMD64}
export UV_SHA256_AMD64=${UV_SHA256_AMD64}
export UV_ASSET_ARM64=${UV_ASSET_ARM64}
export UV_SHA256_ARM64=${UV_SHA256_ARM64}

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

export TURBO_VERSION=${TURBO_VERSION}
export PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION}
export SHARP_VERSION=${SHARP_VERSION}
export LIGHTHOUSE_VERSION=${LIGHTHOUSE_VERSION}

EOF

chmod 644 "$LOCKFILE"

info "Generated ${LOCKFILE}"

# ------------------------------------------------------------------------------
# Generate .python-version
# ------------------------------------------------------------------------------
# (PYTHON_MINOR computed above, alongside the lock file, so both consumers
# derive from the exact same value.)

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