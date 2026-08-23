# 30-history-and-completion.sh
# shellcheck shell=bash

# --- History improvements -----------------------------------------------
export HISTSIZE=100000
export HISTFILESIZE=200000
export HISTCONTROL=ignoreboth:erasedups   # skip dupes and leading-space cmds
export HISTTIMEFORMAT="%F %T  "
shopt -s histappend                        # append, don't overwrite, on exit
shopt -s cmdhist                           # multi-line commands as one entry
PROMPT_COMMAND="history -a; history -c; history -r; ${PROMPT_COMMAND:-}"

# --- Completion ------------------------------------------------------------
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# Git completion ships with bash-completion on Ubuntu (git-core sets it up);
# fall back to fetching it if it's ever missing from the base image.
if ! type _git >/dev/null 2>&1 && [ -f /usr/share/bash-completion/completions/git ]; then
  . /usr/share/bash-completion/completions/git
fi

# gh/docker/poetry completions: NOT generated here anymore (2026-08-23).
# They used to be regenerated live on every shell startup — three
# subprocess spawns per new terminal/tab/tmux pane, `poetry completions
# bash` worst of the three since it means a cold Python interpreter start
# just to print static text. They're now baked ONCE into
# /etc/bash_completion.d/{gh,docker,poetry} at Docker build time (see the
# Dockerfile's Section 11). Standard bash-completion (sourced immediately
# above) auto-discovers and lazily loads anything under
# /etc/bash_completion.d/ by filename — nothing further to source
# explicitly here. If gh/docker/poetry are ever upgraded at container
# runtime by some means other than a fresh image build, their completions
# would need regenerating by hand; that's not a workflow this project
# currently supports (all three are pinned, image-baked versions), so it's
# an accepted tradeoff, not an oversight.

shopt -s checkwinsize
shopt -s globstar 2>/dev/null