# profiler PATH — appended by profiler/setup/phases/16-claude.sh (do not remove this marker line)
# Claude Code (native install) and the project's user-level tools live in ~/.local/bin.
# The same block is appended to the interactive rc file and to the login profile
# (bash -lc …, the remote invocation form): it is idempotent, so both may run.
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
