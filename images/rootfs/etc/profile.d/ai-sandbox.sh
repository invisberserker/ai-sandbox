# /etc/profile.d/ai-sandbox.sh — shared shell setup for ai-sandbox images.
# Sourced by login shells via profile.d, and by interactive `bash` via the
# /root/.bashrc hook baked in the Dockerfile. Keep it POSIX-ish and fast:
# every agent session pays this cost on start.

# Tools install themselves into these (see Dockerfile ENV plumbing); make
# sure they win over any distro defaults regardless of shell flavor.
case ":$PATH:" in
  */usr/local/cargo/bin:*) ;;
  *) export PATH="/usr/local/cargo/bin:/usr/local/bin:$PATH" ;;
esac

export EDITOR=vim
export PAGER=less
export HISTSIZE=50000
export HISTFILESIZE=50000
export HISTCONTROL=ignoredups:erasedups

# The classic trio, spelled the way agents and humans both expect.
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'

# tmux: long agent sessions belong in tmux so a disconnect doesn't kill
# the TUI — but the tmux server lives only as long as the CONTAINER, so
# pair with `just up` + `just attach` (a plain `just shell` container is
# removed at exit, tmux included). Create-or-attach:
#   tmux new -A -s agent
alias attach='tmux new -A -s agent'

# Agent-managed git (opt-in per project; docs/SECURITY.md → "Git auth"):
# when the project's .ai.env carries a dedicated SSH key, install it for
# this shell. Idempotent and near-zero cost when unset; never breaks
# login (a bad key value is reported by running agent-git-auth by hand).
if [ -n "${GIT_SSH_KEY_B64:-}" ] && command -v agent-git-auth >/dev/null 2>&1; then
  agent-git-auth --quiet || true
fi
