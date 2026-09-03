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
CONTRACT=0

for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=1 ;;
        --contract) CONTRACT=1 ;;
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
: "${JAVA_MAJOR:=17}"
: "${EXPECTED_USER:=vscode}"
: "${EXPECTED_UID:=1000}"
: "${EXPECTED_GID:=1000}"

# BAOBAB_BUILD_PROFILE identifies which Dockerfile target produced THIS
# image (full / frontend / frontend-e2e) — baked in via ENV in each target,
# not something a repo sets. Defaulting to "full" here means every existing
# image that predates this variable (i.e. every image built before the
# frontend/frontend-e2e targets existed) behaves EXACTLY as before: every
# check below still runs, nothing is newly skipped. Only images actually
# built FROM a frontend/frontend-e2e target, which explicitly set this ENV
# themselves, get the narrower check set.
: "${BAOBAB_BUILD_PROFILE:=full}"

###############################################################################
# Output helpers
###############################################################################

say() {
    if [[ "$QUIET" -eq 0 ]]; then
        printf '%b\n' "$1"
    fi
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
    if [[ "$QUIET" -eq 0 ]]; then
        printf '  \033[1;33m•\033[0m %s\n' "$1"
    fi
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

# check_contract: validates the calling repo's own .nabhold/environment.yaml
# (if one exists) against this image's config/capabilities.yaml, per the
# Development Environment Contract (nabhold/shared, ADR-0001).
#
# Deliberately opt-in and non-blocking as of v1.1.0 — see the design notes
# in baobab-dev-v1_1_0-release-plan-amended.md §2 for why this stays a soft
# check rather than a hard-fail path for now.
#
#   - No contract file present  -> informational message only, no PASS/FAIL
#     impact. This MUST be the behavior for every current baobab-style
#     checkout that hasn't adopted the contract yet.
#   - yq missing, or this image's own capabilities.yaml missing -> warnc(),
#     not bad(): a missing prerequisite for RUNNING the check is not the
#     same thing as a confirmed incompatibility.
#   - Contract present and parseable -> each required_capability (a
#     domain-qualified dotted path, e.g. "languages.node") is looked up
#     directly against capabilities.<profile>.* in this image's own
#     capabilities.yaml.
check_contract() {

    section "Development Environment Contract"

    local contract_file=".nabhold/environment.yaml"

    if [[ ! -f "$contract_file" ]]; then
        say "  No environment contract found (${contract_file}) — skipping compatibility check."
        return
    fi

    if ! command -v yq >/dev/null 2>&1; then
        warnc "yq not found — cannot parse ${contract_file}, skipping contract check"
        return
    fi

    if [[ -z "${CONFIG_DIR:-}" || ! -f "${CONFIG_DIR}/capabilities.yaml" ]]; then
        warnc "baobab-dev capabilities.yaml not found — cannot validate contract, skipping"
        return
    fi

    local capabilities_file="${CONFIG_DIR}/capabilities.yaml"

    local profile
    profile="$(yq -r '.environment.profile // ""' "$contract_file")"

    if [[ -z "$profile" ]]; then
        bad "Contract ${contract_file} does not declare environment.profile"
        return
    fi

    if [[ "$(yq -r ".capabilities | has(\"${profile}\")" "$capabilities_file")" != "true" ]]; then
        bad "Contract declares unknown profile '${profile}' — baobab-dev capabilities.yaml has no such profile"
        return
    fi

    say "  Declared profile: ${profile}"

    # Cross-check: does THIS running image's own build profile match what
    # the repo declares it needs? Without this, a `frontend` image whose
    # capabilities.yaml still technically "lists" a `full` section (it
    # documents everything baobab-dev CAN provide, not just what THIS
    # build actually has) could give a false pass on the wrong image
    # variant. BAOBAB_BUILD_PROFILE is baked in via ENV per Dockerfile
    # target — it is not something a repo's environment.yaml sets.
    if [[ "${BAOBAB_BUILD_PROFILE}" != "${profile}" ]]; then
        bad "This image was built with profile '${BAOBAB_BUILD_PROFILE}' but the repo declares '${profile}' — wrong image variant"
        return
    fi

    local cap cap_value
    while IFS= read -r cap; do
        [[ -z "$cap" ]] && continue

        cap_value="$(yq -r ".capabilities.${profile}.${cap} // \"MISSING\"" "$capabilities_file" 2>/dev/null || echo "MISSING")"

        if [[ "$cap_value" == "MISSING" || "$cap_value" == "null" ]]; then
            bad "Contract requires '${cap}' — not provided by baobab-dev profile '${profile}'"
        else
            ok "Contract requirement '${cap}' satisfied (${cap_value})"
        fi
    done < <(yq -r '.validation.required_capabilities[]' "$contract_file")
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

say "Profile       : ${BAOBAB_BUILD_PROFILE}"

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

if [[ "$BAOBAB_BUILD_PROFILE" == "full" ]]; then

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

else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Python"
fi

###############################################################################
# JavaScript
###############################################################################

section "JavaScript"

# `infra` is the one profile that branches off `base` directly instead of
# `with-node` (see the Dockerfile's `infra` stage comment) — every other
# profile to date (full/frontend/frontend-e2e) descends from `with-node`
# unconditionally, which is why this section previously had no gate at all.
if [[ "$BAOBAB_BUILD_PROFILE" != "infra" ]]; then

    check_required "Node.js ${NODE_MAJOR}" node
    check_required "npm" npm
    check_required "pnpm" pnpm
    check_optional "Yarn" yarn

else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Node.js"
fi

###############################################################################
# Flutter
###############################################################################

section "Flutter"

if [[ "$BAOBAB_BUILD_PROFILE" == "full" ]]; then

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

else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Flutter"
fi

###############################################################################
# Java
###############################################################################

section "Java"

# Needed only for baobab-erp's iDempiere ERP engine migration — not by any
# other BAOBAB engine today. Matches capabilities.yaml, which only lists
# `languages.java`/`development.maven` under `full`.
if [[ "$BAOBAB_BUILD_PROFILE" == "full" ]]; then

    check_required "Java ${JAVA_MAJOR}" java "java --version"
    check_required "javac" javac "javac --version"
    check_required "Maven" mvn "mvn --version"

else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Java/Maven"
fi

###############################################################################
# Databases
###############################################################################

section "Database"

if [[ "$BAOBAB_BUILD_PROFILE" == "full" ]]; then
    check_required "PostgreSQL client" psql
    check_required "Redis CLI" redis-cli
else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include database clients"
fi

###############################################################################
# Docker
###############################################################################

section "Containers"

# `infra` added alongside `full` (2026-09-03) — it installs Docker CLI +
# Compose plugin too (nabhold/infrastructure's own compose stack), matching
# capabilities.yaml's `development.docker: true` under both profiles.
if [[ "$BAOBAB_BUILD_PROFILE" == "full" || "$BAOBAB_BUILD_PROFILE" == "infra" ]]; then

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

else
    # ASSUMPTION: neither frontend nor frontend-e2e includes Docker CLI —
    # matches capabilities.yaml, which only lists `docker` under `full`/
    # `infra`. Revisit if a digital-estate repo later needs local
    # containerized services (e.g. a local mock backend).
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Docker CLI"
fi

###############################################################################
# Infrastructure
###############################################################################

section "Infrastructure"

# Needed only for nabhold/infrastructure's Terraform-managed AWS
# infrastructure — not by any other BAOBAB repo today. Matches
# capabilities.yaml, which only lists `development.terraform`/`aws_cli`
# under `infra`.
if [[ "$BAOBAB_BUILD_PROFILE" == "infra" ]]; then

    check_required "Terraform" terraform "terraform version"
    check_required "AWS CLI" aws "aws --version"

else
    say "  Skipped — profile '${BAOBAB_BUILD_PROFILE}' does not include Terraform/AWS CLI"
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
check_optional "tmux" tmux

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
# Development Environment Contract (opt-in — see check_contract() above)
###############################################################################

if [[ "$CONTRACT" -eq 1 ]]; then
    check_contract
fi

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