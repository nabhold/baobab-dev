# 10-prompt.sh — colored, git-aware prompt for the BAOBAB devcontainer
# shellcheck shell=bash

__baobab_git_branch() {
  git branch --show-current 2>/dev/null | sed 's/.*/(&) /'
}

if [ -n "${BASH_VERSION:-}" ] && [ -t 1 ]; then
  RESET='\[\033[0m\]'
  BOLD_GREEN='\[\033[1;32m\]'
  BOLD_BLUE='\[\033[1;34m\]'
  BOLD_YELLOW='\[\033[1;33m\]'
  PS1="${BOLD_GREEN}\u@baobab-dev${RESET}:${BOLD_BLUE}\w${RESET} ${BOLD_YELLOW}\$(__baobab_git_branch)${RESET}\$ "
fi
