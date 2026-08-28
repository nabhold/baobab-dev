#!/usr/bin/env bash
# =============================================================================
# summary.sh  (installed in the image as: baobab-summary)
#
# Displays a concise overview of the BAOBAB development environment.
#
# Safe to execute at any time. All lookups are best-effort and the script never
# intentionally fails the developer's shell.
# =============================================================================

set -euo pipefail

###############################################################################
# Colours
###############################################################################

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
RESET='\033[0m'

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

if [[ -n "${CONFIG_DIR}" && -f "${CONFIG_DIR}/versions.lock" ]]; then
    # shellcheck disable=SC1091
    source "${CONFIG_DIR}/versions.lock"
fi

: "${PYTHON_MINOR:=3.14}"
: "${PYTHON_VERSION:=3.14}"
: "${NODE_MAJOR:=24}"
: "${FLUTTER_VERSION:=unknown}"

###############################################################################
# Helpers
###############################################################################

section() {
    echo
    echo -e "${BOLD}$1${RESET}"
}

version() {
    local cmd="$1"
    local version_cmd="${2:-$1 --version}"

    if command -v "$cmd" >/dev/null 2>&1; then
        bash -c "$version_cmd" 2>/dev/null | head -n1
    else
        echo "Not installed"
    fi
}

status() {
    if "$@" >/dev/null 2>&1; then
        echo -e "${GREEN}Available${RESET}"
    else
        echo -e "${YELLOW}Unavailable${RESET}"
    fi
}

###############################################################################
# Banner
###############################################################################

echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${CYAN}║${RESET}  ${BOLD}BAOBAB Enterprise Platform - Development Container${RESET}               ${CYAN}║${RESET}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════╝${RESET}"

###############################################################################
# Runtime
###############################################################################

section "Runtime"

printf "  %-18s %s\n" "OS" "$(source /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}")"
printf "  %-18s %s\n" "User" "$(whoami) (uid=$(id -u), gid=$(id -g))"
printf "  %-18s %s\n" "Workspace" "$(pwd)"
printf "  %-18s %s\n" "Configuration" "${CONFIG_DIR:-Built-in defaults}"
printf "  %-18s %s\n" "Image Version" "${BAOBAB_IMAGE_VERSION:-Unknown}"
printf "  %-18s %s\n" "Build Date" "${BAOBAB_BUILD_DATE:-Unknown}"
printf "  %-18s %s\n" "Git Revision" "${BAOBAB_GIT_REVISION:-Unknown}"

###############################################################################
# Toolchain
###############################################################################

section "Languages & Toolchain"

printf "  %-18s %s\n" "Python"   "$(version python${PYTHON_MINOR} "python${PYTHON_MINOR} --version")"
printf "  %-18s %s\n" "Expected" "${PYTHON_VERSION}"

printf "  %-18s %s\n" "Poetry"   "$(version poetry)"
printf "  %-18s %s\n" "uv"       "$(version uv)"
printf "  %-18s %s\n" "Node.js"  "$(version node)"
printf "  %-18s %s\n" "Expected" "${NODE_MAJOR}.x"

printf "  %-18s %s\n" "pnpm"     "$(version pnpm)"
printf "  %-18s %s\n" "Flutter"  "$(version flutter "flutter --version")"
printf "  %-18s %s\n" "Expected" "${FLUTTER_VERSION}"

###############################################################################
# Infrastructure
###############################################################################

section "Infrastructure"

printf "  %-18s %s\n" "PostgreSQL" "$(version psql)"
printf "  %-18s %s\n" "Redis CLI" "$(version redis-cli "redis-cli --version")"
printf "  %-18s %s\n" "Docker" "$(version docker)"
printf "  %-18s %s\n" "Compose" "$(version docker "docker compose version --short")"
printf "  %-18s %s\n" "GitHub CLI" "$(version gh)"

###############################################################################
# Services
###############################################################################

section "Service Status"

printf "  %-18s %b\n" "Docker Daemon" "$(status docker info)"
printf "  %-18s %b\n" "GitHub Login" "$(status gh auth status)"

###############################################################################
# Project Detection
###############################################################################

section "Project Detection"

FOUND=0

detect() {
    if [[ -e "$1" ]]; then
        echo -e "  ${GREEN}✔${RESET} $2"
        FOUND=1
    fi
}

detect "pyproject.toml"          "Python project (Poetry)"
detect "requirements.txt"        "Python project (requirements.txt)"
detect "package.json"            "Node.js project"
detect "pubspec.yaml"            "Flutter project"

detect "backend"                 "Directory: backend"
detect "frontend"                "Directory: frontend"
detect "mobile"                  "Directory: mobile"
detect "services"                "Directory: services"

detect "compose.yaml"            "Docker Compose configuration"
detect "docker-compose.yml"      "Docker Compose configuration"
detect "docker-compose.yaml"     "Docker Compose configuration"

if [[ $FOUND -eq 0 ]]; then
    echo -e "  ${DIM}No recognizable project files detected.${RESET}"
fi

if [[ ! -f ".env" && -f ".env.example" ]]; then
    echo -e "  ${YELLOW}•${RESET} .env has not yet been created."
fi

###############################################################################
# Useful Commands
###############################################################################

section "Useful Commands"

printf "  %-22s %s\n" "baobab-bootstrap" "Developer onboarding"
printf "  %-22s %s\n" "baobab-verify" "Verify the environment"
printf "  %-22s %s\n" "baobab-summary" "Show this summary"
printf "  %-22s %s\n" "docker compose up -d" "Start local infrastructure"

###############################################################################
# Footer
###############################################################################

echo
echo -e "${GREEN}Development environment is ready.${RESET}"
echo -e "Run ${BOLD}baobab-verify${RESET} for a complete health check."
echo