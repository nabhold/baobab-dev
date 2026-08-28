# 20-aliases.sh — useful aliases for the BAOBAB devcontainer
# shellcheck shell=bash

# Modern replacements for classic tools (fall back gracefully if not present)
command -v eza >/dev/null 2>&1 && alias ls='eza --group-directories-first' && alias ll='eza -alh --group-directories-first' && alias lt='eza --tree --level=2'
command -v bat >/dev/null 2>&1 && alias cat='bat --paging=never'
command -v fd  >/dev/null 2>&1 && alias find='fd'
command -v rg  >/dev/null 2>&1 && alias grep='rg'

alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'
alias h='history'

# Django / BAOBAB shortcuts
alias dj='python manage.py'
alias djmig='python manage.py makemigrations && python manage.py migrate'
alias djshell='python manage.py shell'

# -----------------------------------------------------------------------------
# Deprecation warnings — baobab-dev v1.1.0 task 1.5. djrun, djtenant,
# celeryworker, and celerybeat are Baobab-app-specific (unlike dj/djmig/
# djshell above, which are generic Django-CLI conventions, not tied to
# Baobab's own manage.py setup) and will move to the baobab repo itself in
# baobab-dev v2.0.0 (see baobab-dev-v2_0_0-release-plan.md task 2.2). They
# remain FULLY FUNCTIONAL here — this is a warning only, no removal, no
# change to the command each one actually runs.
#
# Implemented as functions rather than plain `alias` because a plain alias
# is pure text substitution with no way to run logic (like a one-time
# warning check) before the substituted command executes. Each guards on
# its own env var so the warning fires once per interactive shell session
# — not on every invocation — regardless of how many times this file itself
# gets sourced within that session.
# -----------------------------------------------------------------------------
_baobab_deprecated_alias_warning() {
    echo "[baobab-dev] '$1' is a Baobab-app-specific alias and will move to the baobab repo in baobab-dev v2.0.0. See docs/environment-contract.md#alias-migration for details." >&2
}

djrun() {
    if [[ -z "${_BAOBAB_WARNED_DJRUN:-}" ]]; then
        _baobab_deprecated_alias_warning "djrun"
        export _BAOBAB_WARNED_DJRUN=1
    fi
    python manage.py runserver 0.0.0.0:8000 "$@"
}

djtenant() {
    if [[ -z "${_BAOBAB_WARNED_DJTENANT:-}" ]]; then
        _baobab_deprecated_alias_warning "djtenant"
        export _BAOBAB_WARNED_DJTENANT=1
    fi
    python manage.py migrate_schemas "$@"
}

# Celery
celeryworker() {
    if [[ -z "${_BAOBAB_WARNED_CELERYWORKER:-}" ]]; then
        _baobab_deprecated_alias_warning "celeryworker"
        export _BAOBAB_WARNED_CELERYWORKER=1
    fi
    celery -A config worker -l info "$@"
}

celerybeat() {
    if [[ -z "${_BAOBAB_WARNED_CELERYBEAT:-}" ]]; then
        _baobab_deprecated_alias_warning "celerybeat"
        export _BAOBAB_WARNED_CELERYBEAT=1
    fi
    celery -A config beat -l info "$@"
}

# Docker Compose
alias dc='docker compose'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias dcps='docker compose ps'

# Poetry
alias pin='poetry install'
alias prun='poetry run'
alias pshell='poetry shell'

# Node / frontend
alias ni='pnpm install'
alias nd='pnpm dev'
alias nb='pnpm build'

# Flutter
alias fldr='flutter doctor'
alias flr='flutter run'
alias flpg='flutter pub get'

# Git
alias gs='git status'
alias gp='git pull --rebase'
alias gl='git log --oneline --graph --decorate -n 20'