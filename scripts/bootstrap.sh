#!/usr/bin/env bash
# =============================================================================
# File: scripts/bootstrap.sh
#
# One-command onboarding for a new BAOBAB engineer or an automated runner
# that consumes the published ghcr.io/nabhold/baobab-dev image outside of the
# VS Code / Codespaces Dev Container lifecycle, for example:
#
#   • a bare `docker run`
#   • a GitHub Actions self-hosted runner
#   • a developer re-running onboarding manually
#   • a local clone of the baobab-dev repository
#
# This complements (does not replace) scripts/post-create.sh:
#
#   post-create.sh
#       Performs repository-specific initialization.
#
#   bootstrap.sh
#       Verifies the development image, configures developer identity,
#       authenticates GitHub CLI, installs Git hooks, scaffolds secrets,
#       and delegates repository initialization to post-create.sh.
#
# Usage:
#
#   ./scripts/bootstrap.sh
#   ./scripts/bootstrap.sh --non-interactive
#
# =============================================================================

set -euo pipefail

NON_INTERACTIVE=0

for arg in "$@"; do
    case "$arg" in
        --non-interactive)
            NON_INTERACTIVE=1
            ;;
    esac
done

log() {
    printf '\n\033[1;36m[bootstrap]\033[0m %s\n' "$1"
}

warn() {
    printf '\n\033[1;33m[bootstrap] WARNING:\033[0m %s\n' "$1"
}

die() {
    printf '\n\033[1;31m[bootstrap] ERROR:\033[0m %s\n' "$1" >&2
    exit 1
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "${REPO_ROOT}"

CONFIG_DIR="${REPO_ROOT}/config"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

[ -d "${CONFIG_DIR}" ] \
    || die "Missing config directory."

[ -f "${CONFIG_DIR}/versions.yaml" ] \
    || die "Missing config/versions.yaml"

[ -x "${CONFIG_DIR}/resolve.sh" ] \
    || die "config/resolve.sh is missing or is not executable."

if [ ! -f "${CONFIG_DIR}/versions.lock" ]; then
    log "Generating versions.lock"
    "${CONFIG_DIR}/resolve.sh"
fi

# shellcheck disable=SC1091
source "${CONFIG_DIR}/versions.lock"

# -----------------------------------------------------------------------------
# Verify development image
# -----------------------------------------------------------------------------

log "Checking BAOBAB development image"

if command -v baobab-verify >/dev/null 2>&1; then
    baobab-verify --quiet \
        || warn "Toolchain verification reported issues. Run 'baobab-verify' for details."
else
    warn "baobab-verify not found. Are you running inside the BAOBAB development image?"
fi

# -----------------------------------------------------------------------------
# Git configuration
# -----------------------------------------------------------------------------

log "Configuring Git"

git config --global --get-all safe.directory \
    | grep -Fxq "${REPO_ROOT}" \
    || git config --global --add safe.directory "${REPO_ROOT}"

if [ "${NON_INTERACTIVE}" -eq 0 ] &&
   [ -z "$(git config --global user.name || true)" ]; then

    read -rp "Git user.name : " GIT_NAME
    read -rp "Git user.email: " GIT_EMAIL

    git config --global user.name "${GIT_NAME}"
    git config --global user.email "${GIT_EMAIL}"
fi

git config --global pull.rebase true
git config --global init.defaultBranch main

if command -v code >/dev/null 2>&1; then
    git config --global core.editor "code --wait"
fi

# -----------------------------------------------------------------------------
# GitHub CLI
# -----------------------------------------------------------------------------

if command -v gh >/dev/null 2>&1; then

    log "Checking GitHub CLI authentication"

    if ! gh auth status >/dev/null 2>&1; then

        if [ -n "${GITHUB_TOKEN:-}" ]; then

            log "Authenticating GitHub CLI using GITHUB_TOKEN"

            echo "${GITHUB_TOKEN}" | gh auth login --with-token

        elif [ "${NON_INTERACTIVE}" -eq 0 ]; then

            log "Launching interactive GitHub authentication"

            gh auth login \
                || warn "GitHub authentication was skipped."

        else

            warn "Non-interactive mode with no GITHUB_TOKEN. Skipping authentication."

        fi

    else

        log "Authenticated as $(gh api user --jq .login 2>/dev/null || echo unknown)"

    fi

else

    warn "GitHub CLI is not installed."

fi

# -----------------------------------------------------------------------------
# Environment
# -----------------------------------------------------------------------------

if [ -f ".env.example" ] && [ ! -f ".env" ]; then

    log "Creating .env"

    cp ".env.example" ".env"

    warn ".env has been created. Populate it with your local secrets."

fi

# -----------------------------------------------------------------------------
# Git hooks
# -----------------------------------------------------------------------------

if [ -f ".pre-commit-config.yaml" ]; then

    if command -v pipx >/dev/null 2>&1; then

        log "Installing pre-commit hooks"

        pipx list 2>/dev/null | grep -q pre-commit \
            || pipx install pre-commit

        command -v pre-commit >/dev/null 2>&1 \
            || die "pre-commit installation failed."

        pre-commit install --install-hooks

    else

        warn "pipx not installed. Skipping pre-commit installation."

    fi

fi

# -----------------------------------------------------------------------------
# Repository initialization
# -----------------------------------------------------------------------------

POST_CREATE="${REPO_ROOT}/scripts/post-create.sh"

if [ -f "${POST_CREATE}" ]; then

    chmod +x "${POST_CREATE}"

    log "Running post-create.sh"

    bash "${POST_CREATE}" --stage=on-create
    bash "${POST_CREATE}" --stage=post-create

else

    warn "scripts/post-create.sh not found."

fi

# -----------------------------------------------------------------------------
# Final verification
# -----------------------------------------------------------------------------

if command -v baobab-verify >/dev/null 2>&1; then

    log "Running final environment verification"

    baobab-verify \
        || warn "Environment verification reported issues."

fi

log "Bootstrap complete."

log "Run 'baobab-summary' at any time for an overview of your development environment."
