# ~/.config/fish/conf.d/profiler.fish — written by profiler/setup/phases/16-claude.sh
# profiler PATH: Claude Code (native install) and the project's user-level tools
# live in ~/.local/bin. -g: this session only; conf.d runs for every new shell.
if test -d $HOME/.local/bin
    fish_add_path -g $HOME/.local/bin
end
# ~/.config/profiler/env holds KEY=VALUE lines (no quotes), e.g. CLAUDE_CODE_OAUTH_TOKEN
# from `claude setup-token`; keep it mode 0600.
if test -r $HOME/.config/profiler/env
    for line in (string match -r '^[A-Za-z_][A-Za-z0-9_]*=.*' < $HOME/.config/profiler/env)
        set -gx (string split -m1 = $line)
    end
end
