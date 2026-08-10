#!/usr/bin/env bash
# =============================================================================
# scripts/verify.sh (installed as: baobab-verify)
#
# Verifies that the BAOBAB development environment is healthy.
#
# Exit codes
#   0 = Success
#   1 = One or more required checks failed
# =============================================================================

set -euo pipefail

###############################################################################
# Options
###############################################################################

QUIET=0

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
    esac
done

###############################################################################
# Globals
###############################################################################

PASS=0
FAIL=0
WARN=0

TMP_FLUTTER_LOG="$(mktemp)"
trap 'rm -f "${TMP_FLUTTER_LOG}"' EXIT

# Safety net: if any command anywhere in this script fails in a way that
# isn't already caught and reported by check_required/check_optional below,
# print exactly what failed and where, instead of exiting silently under
# `set -e`. This is the difference between "exit code: 1, no output" and
# an actionable diagnostic in the build log.
trap 'ec=$?; printf "\n\033[1;31mverify.sh: aborted (exit %d) at line %d\033[0m\nCommand: %s\n" "$ec" "$LINENO" "$BASH_COMMAND" >&2' ERR

###############################################################################
# Locate configuration
###############################################################################

CONFIG_DIR=""

if [[ -n "${BAOBAB_CONFIG_DIR:-}" && -f "${BAOBAB_CONFIG_DIR}/versions.lock" ]]; then
    CONFIG_DIR="${BAOBAB_CONFIG_DIR}"

elif [[ -f "/usr/local/share/baobab/config/versions.lock" ]]; then
    CONFIG_DIR="/usr/local/share/baobab/config"

elif [[ -f "./config/versions.lock" ]]; then
    CONFIG_DIR="./config"
fi

if [[ -n "${CONFIG_DIR}" ]]; then
    # shellcheck disable=SC1091
    source "${CONFIG_DIR}/versions.lock"
fi

###############################################################################
# Defaults (fallback)
###############################################################################

: "${PYTHON_MINOR:=3.14}"
: "${PYTHON_VERSION:=3.14}"
: "${NODE_MAJOR:=24}"
: "${FLUTTER_VERSION:=unknown}"
: "${EXPECTED_USER:=vscode}"
: "${EXPECTED_UID:=1000}"
: "${EXPECTED_GID:=1000}"

###############################################################################
# Output helpers
###############################################################################

say() {
    [[ "$QUIET" -eq 0 ]] && printf '%b\n' "$1"
}

ok() {
    PASS=$((PASS+1))
    say "  \033[1;32m✔\033[0m $1"
}

bad() {
    FAIL=$((FAIL+1))
    printf '  \033[1;31m✘\033[0m %s\n' "$1"
}

warnc() {
    WARN=$((WARN+1))
    [[ "$QUIET" -eq 0 ]] && printf '  \033[1;33m•\033[0m %s\n' "$1"
}

section() {
    say ""
    say "\033[1m$1\033[0m"
}

###############################################################################
# Helpers
###############################################################################

# run_version_cmd: executes "$1" and prints its first line of stdout.
# Never lets a non-zero exit status propagate to the caller under `set -e` —
# it captures the outcome explicitly instead. Sets the caller's local
# variables via the names passed in $2 (output) and $3 (stderr, for
# diagnostics), and returns the version command's own exit code.
run_version_cmd() {
    local version_cmd="$1"
    local -n _out="$2"
    local -n _err="$3"
    local rc

    set +e
    _out="$(bash -c "$version_cmd" 2>/tmp/baobab-verify-stderr.$$ | head -n1)"
    rc=$?
    set -e

    _err="$(cat /tmp/baobab-verify-stderr.$$ 2>/dev/null)"
    rm -f /tmp/baobab-verify-stderr.$$

    return "$rc"
}

check_required() {

    local label="$1"
    local cmd="$2"
    local version_cmd="${3:-$2 --version}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        bad "$label — '$cmd' not found"
        return
    fi

    local version stderr_out rc=0
    run_version_cmd "$version_cmd" version stderr_out || rc=$?

    if [[ $rc -eq 0 && -n "$version" ]]; then
        ok "$label (${version})"
    else
        bad "$label — '$version_cmd' failed (exit ${rc})${stderr_out:+: ${stderr_out}}"
    fi
}

check_optional() {

    local label="$1"
    local cmd="$2"
    local version_cmd="${3:-$2 --version}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        warnc "$label not installed"
        return
    fi

    local version stderr_out rc=0
    run_version_cmd "$version_cmd" version stderr_out || rc=$?

    if [[ $rc -eq 0 && -n "$version" ]]; then
        ok "$label (${version})"
    else
        warnc "$label — '$version_cmd' failed (exit ${rc})${stderr_out:+: ${stderr_out}}"
    fi
}

###############################################################################
# Header
###############################################################################

say ""
say "\033[1mBAOBAB Development Environment Verification\033[0m"

if [[ -f "${CONFIG_DIR:-}/versions.lock" ]]; then
    say "Configuration : ${CONFIG_DIR}/versions.lock"
else
    say "Configuration : built-in defaults"
fi

###############################################################################
# Core
###############################################################################

section "Core System"

check_required "git" git
check_required "curl" curl
check_required "jq" jq
check_required "sudo" sudo

###############################################################################
# Python
###############################################################################

section "Python"

check_required \
    "Python ${PYTHON_VERSION}" \
    "python${PYTHON_MINOR}" \
    "python${PYTHON_MINOR} --version"

check_required "pip" pip3
check_required "pipx" pipx
check_required "uv" uv
check_required "Poetry" poetry

if command -v poetry >/dev/null; then

    poetry_setting=""
    set +e
    poetry_setting="$(poetry config virtualenvs.in-project 2>/dev/null)"
    set -e

    if [[ "$poetry_setting" == "true" ]]; then
        ok "Poetry configured for in-project virtualenvs"
    else
        warnc "Poetry virtualenvs.in-project=${poetry_setting:-unknown}"
    fi

fi

###############################################################################
# JavaScript
###############################################################################

section "JavaScript"

check_required "Node.js ${NODE_MAJOR}" node
check_required "npm" npm
check_required "pnpm" pnpm
check_optional "Yarn" yarn

###############################################################################
# Flutter
###############################################################################

section "Flutter"

check_required "Flutter" flutter
check_required "Dart" dart

if [[ "$QUIET" -eq 0 ]] && command -v flutter >/dev/null; then

    flutter doctor --no-version-check >"${TMP_FLUTTER_LOG}" 2>&1 || true

    if grep -q "No issues found" "${TMP_FLUTTER_LOG}"; then
        ok "flutter doctor reports healthy environment"
    else
        warnc "flutter doctor reports warnings"
    fi

fi

###############################################################################
# Databases
###############################################################################

section "Database"

check_required "PostgreSQL client" psql
check_required "Redis CLI" redis-cli

###############################################################################
# Docker
###############################################################################

section "Containers"

check_required "Docker CLI" docker

if command -v docker >/dev/null; then

    if docker compose version >/dev/null 2>&1; then
        ok "Docker Compose plugin"
    else
        bad "Docker Compose plugin missing"
    fi

    if docker info >/dev/null 2>&1; then
        ok "Docker daemon reachable"
    else
        warnc "Docker daemon unavailable"
    fi

fi

###############################################################################
# GitHub
###############################################################################

section "GitHub"

check_required "GitHub CLI" gh

if command -v gh >/dev/null; then

    if gh auth status >/dev/null 2>&1; then
        ok "GitHub authentication"
    else
        warnc "GitHub CLI not authenticated"
    fi

fi

###############################################################################
# Utilities
###############################################################################

section "Utilities"

check_required "ripgrep" rg
check_required "fd" fd
check_required "bat" bat
check_required "eza" eza
check_required "fzf" fzf
check_optional "tmux" tmux "tmux -V"
check_required "Task" task "task --version"
check_required "yq" yq "yq --version"
# cosign version's actual output leads with an ASCII-art banner before the
# GitVersion/GitCommit/etc. fields — filtering to the GitVersion line here
# avoids run_version_cmd's `head -n1` capturing banner art instead.
check_required "Cosign" cosign "cosign version | grep GitVersion"

###############################################################################
# User
###############################################################################

section "User"

[[ "$(id -u)" == "${EXPECTED_UID}" ]] \
    && ok "UID ${EXPECTED_UID}" \
    || bad "Expected UID ${EXPECTED_UID}, got $(id -u)"

[[ "$(id -g)" == "${EXPECTED_GID}" ]] \
    && ok "GID ${EXPECTED_GID}" \
    || bad "Expected GID ${EXPECTED_GID}, got $(id -g)"

[[ "$(whoami)" == "${EXPECTED_USER}" ]] \
    && ok "User ${EXPECTED_USER}" \
    || bad "Expected user ${EXPECTED_USER}, got $(whoami)"

sudo -n true >/dev/null 2>&1 \
    && ok "Passwordless sudo" \
    || bad "Passwordless sudo unavailable"

###############################################################################
# Summary
###############################################################################

say ""
say "------------------------------------------------"

say "Passed   : ${PASS}"
say "Warnings : ${WARN}"
say "Failed   : ${FAIL}"

if [[ "$FAIL" -eq 0 ]]; then

    say ""
    say "\033[1;32mEnvironment Status : HEALTHY\033[0m"

    exit 0

else

    say ""
    say "\033[1;31mEnvironment Status : FAILED\033[0m"

    exit 1

fi