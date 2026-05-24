#compdef tc

__tc_complete() {
    local -ar non_empty_completions=("${@:#(|:*)}")
    local -ar empty_completions=("${(M)@:#(|:*)}")
    _describe -V '' non_empty_completions -- empty_completions -P $'\'\''
}

__tc_custom_complete() {
    local -a completions
    completions=("${(@f)"$("${command_name}" "${@}" "${command_line[@]}")"}")
    if [[ "${#completions[@]}" -gt 1 ]]; then
        __tc_complete "${completions[@]:0:-1}"
    fi
}

__tc_cursor_index_in_current_word() {
    if [[ -z "${QIPREFIX}${IPREFIX}${PREFIX}" ]]; then
        printf 0
    else
        printf %s "${#${(z)LBUFFER}[-1]}"
    fi
}

_tc() {
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
            'status:Show the running touch-code app status.'
            'launch:Start touch-code and wait for its command socket.'
            'doctor:Check local CLI configuration and app reachability.'
            'tree:List projects, worktrees, tabs, and panes.'
            'project:Create and remove projects.'
            'worktree:Create, switch, and remove worktrees.'
            'tab:Create, switch, and close tabs.'
            'pane:Create, focus, close, label, read, reset, and send panes.'
            'broadcast:Send text to a tab, worktree, or label scope.'
            'help:Show subcommand help information.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        status|launch|doctor|tree|project|worktree|tab|pane|broadcast|help)
            "_tc_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_status() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_launch() {
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

_tc_doctor() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tree() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Restrict output to one project id, name, or '\''current'\''.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_project() {
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
            'rm:Remove a project from touch-code.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        add|rm)
            "_tc_project_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_project_add() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':path:'
        '--name[Display name. Defaults to the directory name.]:name:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_project_rm() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree() {
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
            "_tc_worktree_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_worktree_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':branch:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--path[Path for the worktree. Defaults to the project'\''s configured worktrees directory.]:path:'
        '--name[Display name. Defaults to the branch name.]:name:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree_switch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_worktree_rm() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':worktree:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tab() {
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
            "_tc_tab_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_tab_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
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

_tc_tab_switch() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_tab_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
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

_tc_pane() {
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
            'close:Close a pane.'
            'label:Add labels to a pane.'
            'reset:Reset a pane'\''s terminal state.'
            'send:Send text to a pane.'
            'read:Read text from a pane.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        new|focus|close|label|reset|send|read)
            "_tc_pane_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_tc_pane_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '*:command:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id or '\''current'\''.]:worktree:'
        '--tab[Tab id or '\''current'\''.]:tab:'
        '--cwd[Working directory. Defaults to $PWD.]:cwd:'
        '--label[Initial labels.]:label:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_focus() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the pane id.]:project:'
        '--worktree[Worktree id or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id or '\''current'\''. Usually inferred from the pane id.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_close() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the pane id.]:project:'
        '--worktree[Worktree id or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id or '\''current'\''. Usually inferred from the pane id.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_label() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
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

_tc_pane_reset() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_send() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '(-p --pane)'{-p,--pane}'[Target pane id, @label, or '\''current'\''.]:pane:'
        '*:arguments:'
        '--stdin[Read text from stdin.]'
        '--no-enter[Do not send trailing Enter after text.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_pane_read() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--extent[Text extent to read\: viewport, screen, or selection.]:extent:'
        '--screen[Shortcut for --extent screen.]'
        '--selection[Shortcut for --extent selection.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_tc_broadcast() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $TOUCH_CODE_SOCKET_PATH → Debug /tmp/touch-code-dev-<uid>.sock, Release /tmp/touch-code-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--tab[Tab id or '\''current'\''.]:tab:'
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

_tc_help() {
    local -i ret=1
    local -ar arg_specs=(
        '*:subcommands:'
        '--version[Show the version.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

if [[ "${funcstack[1]}" = _tc ]]; then
    _tc "${@}"
else
    compdef _tc tc
fi
