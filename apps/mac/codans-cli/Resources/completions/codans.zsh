#compdef codans

__codans_complete() {
    local -ar non_empty_completions=("${@:#(|:*)}")
    local -ar empty_completions=("${(M)@:#(|:*)}")
    _describe -V '' non_empty_completions -- empty_completions -P $'\'\''
}

__codans_custom_complete() {
    local -a completions
    completions=("${(@f)"$("${command_name}" "${@}" "${command_line[@]}")"}")
    if [[ "${#completions[@]}" -gt 1 ]]; then
        __codans_complete "${completions[@]:0:-1}"
    fi
}

__codans_cursor_index_in_current_word() {
    if [[ -z "${QIPREFIX}${IPREFIX}${PREFIX}" ]]; then
        printf 0
    else
        printf %s "${#${(z)LBUFFER}[-1]}"
    fi
}

_codans() {
    emulate -RL zsh -G
    setopt extendedglob nullglob numericglobsort
    unsetopt aliases banghist

    local -xr SAP_SHELL=zsh
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(builtin emulate zsh -c 'printf %s "${ZSH_VERSION}"')"
    local -r SAP_SHELL_VERSION

    local context state state_descr line
    local -A opt_args

    local -r command_name="${words[1]}"
    local -ar command_line=("${words[@]}")
    local -ir current_word_index="$((CURRENT - 1))"

    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'status:Show the running Codans app status.'
            'launch:Start Codans and wait for its command socket.'
            'doctor:Check local CLI configuration and app reachability.'
            'tree:List projects, worktrees, tabs, and panes.'
            'project:Create and remove projects.'
            'worktree:Create, switch, and remove worktrees.'
            'tab:Create, switch, and close tabs.'
            'pane:Create, focus, close, label, read, reset, and send panes.'
            'broadcast:Send text to a tab, worktree, or label scope.'
            'agent:List and launch coding-agent profiles.'
            'handoff:Hand a task off between coding agents: archive, brief, and launch the receiver.'
            'help:Show subcommand help information.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        status|launch|doctor|tree|project|worktree|tab|pane|broadcast|agent|handoff|help)
            "_codans_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_status() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_launch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--wait[Seconds to wait for the socket after launching.]:wait:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_doctor() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_tree() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Restrict output to one project id, name, or '\''current'\''.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'add:Add an existing directory as a project.'
            'rm:Remove a project from Codans.'
            'commands:Inspect and manage a project'\''s saved commands.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        add|rm|commands)
            "_codans_project_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_project_add() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':path:'
        '--name[Display name. Defaults to the directory name.]:name:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project_rm() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project_commands() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'list:List a project'\''s saved commands.'
            'add:Add a command to a project.'
            'edit:Edit a project'\''s saved command (only the flags you pass change).'
            'rm:Remove a project'\''s saved command.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|add|edit|rm)
            "_codans_project_commands_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_project_commands_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project_commands_add() {
    local -i ret=1
    local -ar ___kind=('run' 'test' 'deploy' 'lint' 'format' 'custom')
    local -ar ___target=('focused' 'newTab' 'split')
    local -ar ___direction=('up' 'down' 'left' 'right')
    local -ar ___on_finished=('none' 'closePane' 'closeTab')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--name[Display name. Defaults to the kind'\''s label.]:name:'
        '--command[Shell command to run.]:command:'
        '--kind[Kind\: run | test | deploy | lint | format | custom.]:kind:{__codans_complete "${___kind[@]}"}'
        '--target[Where it runs\: focused | newTab | split.]:target:{__codans_complete "${___target[@]}"}'
        '--direction[Split direction (split target only)\: up | down | left | right.]:direction:{__codans_complete "${___direction[@]}"}'
        '--on-finished[On completion (spawning targets)\: none | closePane | closeTab.]:on-finished:{__codans_complete "${___on_finished[@]}"}'
        '--focus[Steal focus to the spawned surface (default\: focus).]'
        '--no-focus[Steal focus to the spawned surface (default\: focus).]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project_commands_edit() {
    local -i ret=1
    local -ar ___kind=('run' 'test' 'deploy' 'lint' 'format' 'custom')
    local -ar ___target=('focused' 'newTab' 'split')
    local -ar ___direction=('up' 'down' 'left' 'right')
    local -ar ___on_finished=('none' 'closePane' 'closeTab')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--name[New display name (pass "" to clear it).]:name:'
        '--command[New shell command.]:command:'
        '--kind[Kind\: run | test | deploy | lint | format | custom.]:kind:{__codans_complete "${___kind[@]}"}'
        '--target[Where it runs\: focused | newTab | split.]:target:{__codans_complete "${___target[@]}"}'
        '--direction[Split direction\: up | down | left | right.]:direction:{__codans_complete "${___direction[@]}"}'
        '--on-finished[On completion\: none | closePane | closeTab.]:on-finished:{__codans_complete "${___on_finished[@]}"}'
        '--focus[Steal focus to the spawned surface.]'
        '--no-focus[Steal focus to the spawned surface.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_project_commands_rm() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':id:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_worktree() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'new:Create a worktree entry.'
            'switch:Activate a worktree.'
            'rm:Remove a worktree entry.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        new|switch|rm)
            "_codans_worktree_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_worktree_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':branch:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--path[Path for the worktree. Defaults to the project'\''s configured worktrees directory.]:path:'
        '--name[Display name. Defaults to the branch name.]:name:'
        '--reuse-existing[If a worktree with the same canonical path already exists, return its id instead of failing with a conflict. Name collisions still fail.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_worktree_switch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_worktree_rm() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':worktree:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--by-path[Remove every worktree row in the project whose canonical path equals this path. Mutually exclusive with the positional worktree argument.]:by-path:'
        '--all[With --by-path, allow removing more than one matching row. Without --all, --by-path requires exactly one match.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_tab() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'new:Create a tab.'
            'switch:Activate a tab.'
            'close:Close a tab.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        new|switch|close)
            "_codans_tab_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_tab_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':name:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_tab_switch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_tab_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':tab:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'new:Create a pane, optionally with an initial command.'
            'focus:Focus a pane.'
            'close:Close a pane and kill its zmx daemon.'
            'label:Add labels to a pane.'
            'reset:Reset a pane'\''s terminal state.'
            'send:Send text to a pane.'
            'send-key:Send a named special key to a pane.'
            'read:Read serialized terminal state from a pane'\''s zmx daemon.'
            'info:Probe a pane'\''s zmx daemon for shell pid, pwd, and (when available) cursor + modes.'
            'capture:Capture a pane'\''s rendered text.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        new|focus|close|label|reset|send|send-key|read|info|capture)
            "_codans_pane_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_pane_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '*:command:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--tab[Tab id, t<n> handle, or '\''current'\''.]:tab:'
        '--cwd[Working directory. Defaults to $PWD.]:cwd:'
        '--label[Initial labels.]:label:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_focus() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the pane id.]:project:'
        '--worktree[Worktree id or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id, t<n> handle, or '\''current'\''. Usually inferred from the pane id.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the pane id.]:project:'
        '--worktree[Worktree id or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id, t<n> handle, or '\''current'\''. Usually inferred from the pane id.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_label() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '*:labels:'
        '--replace[Replace the existing labels.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_reset() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_send() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '(-p --pane)'{-p,--pane}'[Target pane id, p<n> handle, @label, or '\''current'\''.]:pane:'
        '*:arguments:'
        '--stdin[Read text from stdin.]'
        '--no-enter[Do not send trailing Enter after text.]'
        '--raw[Send raw bytes as a hex string (e.g. 1b5b41 for ESC \[ A).]:raw:'
        '--focus[Focus the target pane after sending.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_send-key() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '(-p --pane)'{-p,--pane}'[Target pane id, p<n> handle, @label, or '\''current'\''.]:pane:'
        '*:arguments:'
        '--focus[Focus the target pane after sending.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_read() {
    local -i ret=1
    local -ar ___range=('visible' 'scrollback' 'all')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--raw[Return the vt-format dump with ANSI escapes preserved.]'
        '--tail[Keep only the last N newline-delimited lines.]:tail:'
        '--range[Range\: visible, scrollback, or all (default).]:range:{__codans_complete "${___range[@]}"}'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_info() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_capture() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--scope[Capture scope\: viewport (default) or screen.]:scope:'
        '--lines[Trim output to the last N non-empty lines.]:lines:'
        '--wait-stable[Poll until the rendered text stops changing before capturing.]'
        '--stable-ms[Wait-stable\: quiet window in ms the output must hold unchanged (default 500).]:stable-ms:'
        '--interval-ms[Wait-stable\: poll interval in ms (default 100).]:interval-ms:'
        '--timeout-ms[Wait-stable\: overall cap in ms before giving up (default 5000).]:timeout-ms:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_broadcast() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--tab[Tab id, t<n> handle, or '\''current'\''.]:tab:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--label[Pane label.]:label:'
        '*:text:'
        '--stdin[Read text from stdin.]'
        '--no-enter[Do not send trailing Enter after text.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_agent() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'list:List agent profiles with their agent, enabled state, and launch command.'
            'launch:Start an agent profile in a worktree.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|launch)
            "_codans_agent_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_agent_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_agent_launch() {
    local -i ret=1
    local -ar ___split=('right' 'left' 'up' 'down')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':profile:'
        '--agent[Agent token (claude, codex, gemini, …) when no profile is named.]:agent:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--prompt[Kickoff prompt; pass '\''-'\'' to read it from stdin.]:prompt:'
        '--tab[Open in a new tab (overrides the profile'\''s placement).]'
        '--split[Split the focused pane\: right, left, up, or down.]:split:{__codans_complete "${___split[@]}"}'
        '--background[Do not select the new tab or move focus.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_handoff() {
    local -i ret=1
    local -ar arg_specs=(
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
        '(-): :->command'
        '(-)*:: :->arg'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0
    case "${state}" in
    command)
        local -ar subcommands=(
            'to:Archive the outgoing state, install the briefing, and launch the receiving agent.'
            'save:Checkpoint: install a fresh briefing and refresh generated context, without launching.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        to|save)
            "_codans_handoff_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_handoff_to() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':agent:'
        '--pane[Source pane id, p<n> handle, @label, or '\''current'\'' (the calling pane).]:pane:'
        '--profile[Profile (name or id) to launch the receiver with.]:profile:'
        '--brief[Inline briefing; pass '\''-'\'' to read it from stdin (heredoc).]:brief:'
        '--no-brief[Context-only\: skip the briefing entirely.]'
        '--note[Note appended to the handoff log.]:note:'
        '--no-launch[Archive and save only; do not start the receiver.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_handoff_save() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--pane[Source pane id, p<n> handle, @label, or '\''current'\'' (the calling pane).]:pane:'
        '--brief[Inline briefing; pass '\''-'\'' to read it from stdin (heredoc).]:brief:'
        '--no-brief[Context-only\: skip the briefing entirely.]'
        '--note[Note appended to the handoff log.]:note:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_help() {
    local -i ret=1
    local -ar arg_specs=(
        '*:subcommands:'
        '--version[Show the version.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

if [[ "${funcstack[1]}" = _codans ]]; then
    _codans "${@}"
else
    compdef _codans codans
fi
