# profiler PATH — appended by profiler/setup/phases/16-claude.sh (do not remove this marker line)
# Claude Code (native install) and the project's user-level tools live in ~/.local/bin.
# This block sits in ~/.bashrc (interactive shells) and ~/.bash_profile (bash -lc …).
case ":${PATH}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) PATH="${HOME}/.local/bin:${PATH}" ;;
esac
export PATH
# ~/.config/profiler/env: KEY=VALUE lines (no quotes), e.g. CLAUDE_CODE_OAUTH_TOKEN; mode 0600
if [ -r "${HOME}/.config/profiler/env" ]; then
    set -a
    . "${HOME}/.config/profiler/env"
    set +a
fi
