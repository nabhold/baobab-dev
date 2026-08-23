#!/usr/bin/env bash
# =============================================================================
# File: scripts/post-create.sh
#
# Runs inside the running container as the `vscode` user, via Dev Container
# lifecycle hooks. It is intentionally split into stages:
#
#   --stage=on-create
#       Runs once immediately after the container is created. Performs
#       lightweight, idempotent infrastructure initialization that can be
#       cached by Codespaces prebuilds.
#
#   --stage=update-content
#       Runs during Codespaces prebuild generation, and again on every
#       content update. THIS is the stage Codespaces prebuilds actually
#       snapshot — see CHANGE LOG below. Runs the same repository dependency
#       installation as post-create (they intentionally share one
#       implementation, run_post_create — see that entry for why).
#
#   --stage=post-create
#       Runs after the workspace is mounted, once per Codespace/container
#       creation. Installs THIS repository's project dependencies while
#       keeping the published development image framework-version agnostic.
#
# Safe to re-run. Every operation is idempotent.
#
# CHANGE LOG (this file, most recent first)
# ------------------------------------------------------------------------------
# * [2026-08-23] Added the missing `update-content` case branch. Root cause:
#   devcontainer.json's `updateContentCommand` calls this script with
#   `--stage=update-content`, but the case statement below only recognized
#   `on-create` and `post-create` — any other stage fell through to the `*)`
#   branch and called `die`. Since `updateContentCommand` runs on EVERY
#   Codespaces prebuild generation and every Codespace creation, this
#   crashed every single time, unconditionally.
#
#   Fixed by pointing `update-content` at the SAME `run_post_create`
#   function `post-create` already calls, rather than inventing a separate
#   implementation — deliberately, for two reasons:
#     1. It's the fix with the smallest, most auditable diff: one new case
#        arm, zero changes to existing behavior.
#     2. scripts/bootstrap.sh (onboarding outside the Codespaces/Dev
#        Container lifecycle — bare `docker run`, a self-hosted runner, a
#        manual clone) calls this script directly with
#        `--stage=on-create` then `--stage=post-create`, and NEVER
#        `--stage=update-content`. Moving the dependency-install logic OUT
#        of `run_post_create` (e.g. into a new, update-content-only
#        function) would have silently broken bootstrap.sh's "one-command
#        onboarding" promise for every one of those use cases. Reusing the
#        same function instead keeps bootstrap.sh, and every existing
#        Codespaces behavior, completely unchanged.
#
#   Side effect, and the actual point of this fix beyond just not crashing:
#   this is also what makes Codespaces prebuilds worth having. Prebuild
#   generation runs `updateContentCommand` and snapshots its result;
#   `postCreateCommand` (a separate stage) never gets captured by a
#   prebuild. The expensive part of this script — Poetry/npm/Flutter
#   dependency installation — now runs during the stage that's actually
#   captured, so a Codespace created from a fresh prebuild gets those
#   dependencies pre-installed. `post-create` still re-runs the same
#   installs on actual Codespace creation regardless (every tool here —
#   Poetry, npm ci, flutter pub get — is fast/no-op when nothing changed
#   since the prebuild), as a correctness safety net: a prebuild can be
#   stale relative to the exact commit a Codespace is created from, and
#   re-running is far cheaper than silently serving stale dependencies.
# =============================================================================

set -euo pipefail

STAGE="post-create"

for arg in "$@"; do
    case "$arg" in
        --stage=*)
            STAGE="${arg#*=}"
            ;;
    esac
done

WORKSPACE_DIR="${WORKSPACE_DIR:-$(pwd)}"
CONFIG_DIR="${WORKSPACE_DIR}/config"

log() {
    printf '\n\033[1;36m[post-create:%s]\033[0m %s\n' "$STAGE" "$1"
}

warn() {
    printf '\n\033[1;33m[post-create:%s] WARNING:\033[0m %s\n' "$STAGE" "$1"
}

die() {
    printf '\n\033[1;31m[post-create:%s] ERROR:\033[0m %s\n' "$STAGE" "$1" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Validate configuration
# -----------------------------------------------------------------------------

[ -d "${CONFIG_DIR}" ] \
    || die "Missing config directory."

[ -f "${CONFIG_DIR}/versions.yaml" ] \
    || die "Missing config/versions.yaml."

[ -x "${CONFIG_DIR}/resolve.sh" ] \
    || die "config/resolve.sh is missing or not executable."

if [ ! -f "${CONFIG_DIR}/versions.lock" ]; then
    log "Generating versions.lock"
    "${CONFIG_DIR}/resolve.sh"
fi

# shellcheck disable=SC1091
source "${CONFIG_DIR}/versions.lock"

# -----------------------------------------------------------------------------
# Stage: on-create
# -----------------------------------------------------------------------------

run_on_create() {

    log "Verifying development toolchain"

    if command -v baobab-verify >/dev/null 2>&1; then
        baobab-verify --quiet \
            || warn "Toolchain verification reported issues. Run 'baobab-verify' for details."
    fi

    log "Priming Git configuration"

    git config --global --get user.name >/dev/null 2>&1 \
        || git config --global user.name "BAOBAB Developer"

    git config --global --get user.email >/dev/null 2>&1 \
        || git config --global user.email "dev@example.com"

    git config --global pull.rebase true
    git config --global init.defaultBranch main

    git config --global --get-all safe.directory \
        | grep -Fxq "${WORKSPACE_DIR}" \
        || git config --global --add safe.directory "${WORKSPACE_DIR}"

    if command -v poetry >/dev/null 2>&1; then
        log "Priming Poetry cache"
        poetry config virtualenvs.in-project true
    else
        warn "Poetry not installed."
    fi
}

# -----------------------------------------------------------------------------
# Stage: post-create (and update-content — see CHANGE LOG above)
# -----------------------------------------------------------------------------

run_post_create() {

    cd "${WORKSPACE_DIR}"

    # -------------------------------------------------------------------------
    # Python
    # -------------------------------------------------------------------------

    if [ -f "pyproject.toml" ]; then

        if ! command -v poetry >/dev/null 2>&1; then
            warn "Poetry not installed. Skipping Python dependency installation."
        else

            PYTHON_BIN="python${PYTHON_MINOR}"

            log "Installing Python dependencies with Poetry"

            poetry env use "$(command -v "${PYTHON_BIN}")"
            poetry install --no-interaction --no-ansi

        fi

    elif [ -f "requirements.txt" ]; then

        if ! command -v uv >/dev/null 2>&1; then
            warn "uv not installed. Skipping Python dependency installation."
        else

            log "Installing Python dependencies with uv"

            uv venv .venv

            # shellcheck disable=SC1091
            source .venv/bin/activate

            uv pip install -r requirements.txt

        fi

    else

        log "No Python dependency manifest found."

    fi

    # -------------------------------------------------------------------------
    # JavaScript / TypeScript
    # -------------------------------------------------------------------------

    if [ -f "package.json" ]; then

        log "Installing JavaScript dependencies"

        if [ -f "pnpm-lock.yaml" ]; then

            if command -v pnpm >/dev/null 2>&1; then
                pnpm install --frozen-lockfile
            else
                warn "pnpm not installed."
            fi

        elif [ -f "yarn.lock" ]; then

            if command -v yarn >/dev/null 2>&1; then
                yarn install --immutable
            else
                warn "Yarn not installed."
            fi

        else

            if command -v npm >/dev/null 2>&1; then
                npm ci || npm install
            else
                warn "npm not installed."
            fi

        fi

    else

        log "No package.json found."

    fi

    # -------------------------------------------------------------------------
    # Flutter
    # -------------------------------------------------------------------------

    if [ -f "pubspec.yaml" ]; then

        if command -v flutter >/dev/null 2>&1; then
            log "Running flutter pub get"
            flutter pub get
        else
            warn "Flutter SDK not installed."
        fi

    else

        log "No pubspec.yaml found."

    fi

    # -------------------------------------------------------------------------
    # Monorepo support
    # -------------------------------------------------------------------------

    if [ -d "frontend" ] && [ -f "frontend/package.json" ] && [ ! -f "package.json" ]; then

        log "Installing frontend dependencies"

        (
            cd frontend

            if [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
                pnpm install --frozen-lockfile
            elif command -v npm >/dev/null 2>&1; then
                npm install
            else
                warn "No supported JavaScript package manager available."
            fi
        )

    fi

    if [ -d "mobile" ] && [ -f "mobile/pubspec.yaml" ]; then

        if command -v flutter >/dev/null 2>&1; then
            log "Installing Flutter mobile dependencies"
            (
                cd mobile
                flutter pub get
            )
        else
            warn "Flutter SDK not installed."
        fi

    fi

    # -------------------------------------------------------------------------
    # Docker Compose
    # -------------------------------------------------------------------------

    if [ -f "docker-compose.yml" ] ||
       [ -f "docker-compose.yaml" ] ||
       [ -f "compose.yaml" ]; then

        if command -v docker >/dev/null 2>&1; then
            log "Compose configuration detected."
            log "Run: docker compose up -d"
        fi

    fi

    # -------------------------------------------------------------------------
    # Environment
    # -------------------------------------------------------------------------

    if [ -f ".env.example" ] && [ ! -f ".env" ]; then
        log "Creating .env from .env.example"
        cp .env.example .env
    fi

    # -------------------------------------------------------------------------
    # Summary
    # -------------------------------------------------------------------------

    log "Post-create complete."

    if command -v baobab-summary >/dev/null 2>&1; then
        baobab-summary
    fi

    # -------------------------------------------------------------------------
    # Final verification
    # -------------------------------------------------------------------------

    if command -v baobab-verify >/dev/null 2>&1; then
        baobab-verify --quiet
    fi
}

case "${STAGE}" in
    on-create)
        run_on_create
        ;;

    update-content)
        run_post_create
        ;;

    post-create)
        run_post_create
        ;;

    *)
        die "Unknown stage '${STAGE}'."
        ;;
esac