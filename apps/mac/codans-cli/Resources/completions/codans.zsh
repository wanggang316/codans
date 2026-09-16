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
            'project:List, create, describe, rename, and remove projects.'
            'worktree:List, create, describe, switch, rename, prune, and remove worktrees.'
            'tab:List, create, describe, switch, rename, and close tabs.'
            'pane:List, create, split, resize, focus, close, label, read, reset, and send panes.'
            'broadcast:Send text to a tab, worktree, or label scope.'
            'agent:List and launch coding-agent profiles.'
            'handoff:Hand a task off between coding agents: archive, brief, and launch the receiver.'
            'workspace:Create and extend multi-repository workspaces.'
            'open:Open a directory in an external editor (or terminal / git client / Finder).'
            'skill:Install the bundled agent skills into your agents'\'' skill folders.'
            'help:Show subcommand help information.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        status|launch|doctor|tree|project|worktree|tab|pane|broadcast|agent|handoff|workspace|open|skill|help)
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
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
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
            'list:List projects.'
            'add:Add an existing directory as a project.'
            'show:Describe a project: paths, git root, selection, worktree counts.'
            'rename:Set a project'\''s sidebar name.'
            'rm:Remove a project from Codans.'
            'commands:Inspect and manage a project'\''s saved commands.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|add|show|rename|rm|commands)
            "_codans_project_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_project_list() {
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

_codans_project_show() {
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

_codans_project_rename() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':project:'
        ':name:'
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
            'list:List worktrees for a project.'
            'new:Create a git worktree for a branch and add it to the project.'
            'show:Describe a worktree: path, branch, project, selection, tab count.'
            'switch:Activate a worktree.'
            'rename:Set a worktree'\''s sidebar name (path and branch stay).'
            'prune:Run `git worktree prune` for a project and drop the stale rows.'
            'rm:Remove a worktree entry.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|new|show|switch|rename|prune|rm)
            "_codans_worktree_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_worktree_list() {
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

_codans_worktree_new() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':branch:'
        '--base[Committish a new branch starts from (e.g. origin/main).]:base:'
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

_codans_worktree_show() {
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

_codans_worktree_rename() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':worktree:'
        ':name:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the worktree.]:project:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_worktree_prune() {
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
        '--delete[Also remove the git worktree from disk (and its branch, per Settings), like the sidebar'\''s Remove Worktree. Without it only the entry is forgotten, and a real git worktree comes back on the next reconcile.]'
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
            'list:List tabs for a worktree.'
            'new:Create a tab.'
            'show:Describe a tab: title, handle, containers, focused pane, pane ids.'
            'switch:Activate a tab.'
            'rename:Set a tab'\''s title, or clear it to follow the shell again.'
            'close:Close a tab.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|new|show|switch|rename|close)
            "_codans_tab_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_tab_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

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
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_tab_show() {
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

_codans_tab_rename() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':tab:'
        ':name:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the tab.]:project:'
        '--worktree[Worktree id, name, branch, or '\''current'\''. Usually inferred from the tab.]:worktree:'
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
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
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
            'list:List panes for a tab.'
            'new:Create a pane, optionally with an initial command.'
            'split:Split a pane and start a shell (or a command) in the new half.'
            'show:Describe a pane from the catalog: containers, cwd, labels, agent, focus.'
            'focus:Focus a pane.'
            'resize:Move the divider next to a pane.'
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
        list|new|split|show|focus|resize|close|label|reset|send|send-key|read|info|capture)
            "_codans_pane_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_pane_list() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--project[Project id, name, or '\''current'\''.]:project:'
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
        '--tab[Tab id, t<n> handle, title, or '\''current'\''.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

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
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
        '--tab[Tab id, t<n> handle, title, or '\''current'\''.]:tab:'
        '--cwd[Working directory. Defaults to $PWD.]:cwd:'
        '--label[Initial labels.]:label:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_split() {
    local -i ret=1
    local -ar ___direction=('right' 'left' 'up' 'down')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--command[Initial command for the new pane. Omit for the default shell.]:command:'
        '--direction[Side of the anchor the new pane takes\: right (default), left, up, down.]:direction:{__codans_complete "${___direction[@]}"}'
        '--cwd[Working directory. Defaults to the anchor pane'\''s directory.]:cwd:'
        '--label[Initial labels.]:label:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_show() {
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

_codans_pane_focus() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--project[Project id, name, or '\''current'\''. Usually inferred from the pane id.]:project:'
        '--worktree[Worktree id, name, branch, or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id, t<n> handle, title, or '\''current'\''. Usually inferred from the pane id.]:tab:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_pane_resize() {
    local -i ret=1
    local -ar _direction=('right' 'left' 'up' 'down')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        ':direction:{__codans_complete "${_direction[@]}"}'
        '--amount[Pixels to move the divider (default 40).]:amount:'
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
        '--worktree[Worktree id, name, branch, or '\''current'\''. Usually inferred from the pane id.]:worktree:'
        '--tab[Tab id, t<n> handle, title, or '\''current'\''. Usually inferred from the pane id.]:tab:'
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
        '--wait[Wait until the command the text started has finished.]'
        '--capture[Wait, and return the output the command produced (implies --wait).]'
        '--wait-timeout[Seconds to wait for completion with --wait / --capture (1 through 600, default 30).]:wait-timeout:'
        '--stable-ms[With --wait\: the screen must hold still this long, in ms (default 500).]:stable-ms:'
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
        '--tab[Tab id, t<n> handle, title, or '\''current'\''.]:tab:'
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
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
            'status:List every pane running an agent with its runtime state.'
            'wait:Block until a pane'\''s agent reaches a state.'
            'launch:Start an agent profile in a worktree.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|status|wait|launch)
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

_codans_agent_status() {
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

_codans_agent_wait() {
    local -i ret=1
    local -ar ___until=('idle' 'working' 'blocked' 'finished' 'changed' 'exit')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':pane:'
        '--until[Condition\: idle, working, blocked, finished, changed, or exit.]:until:{__codans_complete "${___until[@]}"}'
        '--wait-timeout[Seconds to wait before giving up (1 through 600, default 60).]:wait-timeout:'
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
        '--worktree[Worktree id, name, branch, or '\''current'\''.]:worktree:'
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
    local -ar ___split=('right' 'left' 'up' 'down')
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
        '--tab[Open the receiver in a new tab (the default).]'
        '--split[Split the source pane for the receiver\: right, left, up, or down.]:split:{__codans_complete "${___split[@]}"}'
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

_codans_workspace() {
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
            'create:Create a workspace from two or more repositories.'
            'add:Add a repository to a workspace.'
            'drop:Remove a repository from a workspace, unregistering its checkout.'
            'remove:Remove a workspace from Codans, optionally deleting its checkouts.'
            'show:Describe a workspace and its repositories.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        create|add|drop|remove|show)
            "_codans_workspace_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_workspace_create() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':title:'
        '*--project[Registered project to include (repeatable).]:project:'
        '*--repo[Local repository path to include, bare or not (repeatable).]:repo:'
        '*--remote[Remote URL to clone and include (repeatable).]:remote:'
        '--branch[Branch every member checks out. Default\: slug of the title.]:branch:'
        '--base[Base ref for new branches. Default\: each repository'\''s default remote branch.]:base:'
        '--existing[Check out an existing local branch instead of creating one.]'
        '--track[Check out the remote-tracking origin/<branch> instead of creating one.]'
        '--reset-local[With --track\: reset a same-named local branch to the remote tip.]'
        '--clone-into[Folder remote members are cloned into. Default\: ~/.codans/sources.]:clone-into:'
        '--path[Workspace folder. Default\: ~/.codans/workspaces/<slug>.]:path:'
        '--description[Task summary stored in the manifest.]:description:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_workspace_add() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':workspace:'
        '*--project[Registered project to add.]:project:'
        '*--repo[Local repository path to add, bare or not.]:repo:'
        '*--remote[Remote URL to clone and add.]:remote:'
        '--name[Folder name under the workspace root. Default\: the repository'\''s folder name.]:name:'
        '--branch[Branch to check out. Default\: slug of the workspace title, or the --ref branch.]:branch:'
        '--base[Base ref for a new branch.]:base:'
        '--existing[Check out an existing local branch instead of creating one.]'
        '--track[Check out the remote-tracking origin/<branch> instead of creating one.]'
        '--ref[Remote-tracking ref to check out, e.g. origin/feature.]:ref:'
        '--reset-local[With --track or --ref\: reset a same-named local branch to the remote tip.]'
        '--clone-into[Folder a remote member is cloned into. Default\: ~/.codans/sources.]:clone-into:'
        '--role[Short role recorded in the manifest, e.g. backend.]:role:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_workspace_drop() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':workspace:'
        ':member:'
        '--keep-branch[Keep the member'\''s branch in the source repository.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_workspace_remove() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':workspace:'
        '--delete-files[Unregister every checkout and delete the workspace folder.]'
        '--delete-branches[With --delete-files\: also delete each member'\''s branch.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_workspace_show() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':workspace:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_open() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--in[Editor id (e.g. cursor, zed, vscode, xcode, finder, ghostty). Omit to use per-Project / Settings defaults.]:in:'
        ':path:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_skill() {
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
            'list:List the bundled skills with their install status per target.'
            'install:Link bundled skills into agent skill folders.'
            'uninstall:Remove bundled skill links from agent skill folders.'
            'path:Print the bundled directory of a skill.'
        )
        _describe -V subcommand subcommands && ret=0
        ;;
    arg)
        case "${words[1]}" in
        list|install|uninstall|path)
            "_codans_skill_${words[1]}" && ret=0
            ;;
        esac
        ;;
    esac

    return "${ret}"
}

_codans_skill_list() {
    local -i ret=1
    local -ar ___target=('claude' 'codex' 'agents')
    local -ar ___scope=('user' 'project')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '--target[Target (repeatable)\: claude, codex, or agents. Defaults to every detected target.]:target:{__codans_complete "${___target[@]}"}'
        '--scope[Scope\: user (default) or project.]:scope:{__codans_complete "${___scope[@]}"}'
        '--project-root[Repository root for --scope project. Defaults to the git root of $PWD.]:project-root:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_skill_install() {
    local -i ret=1
    local -ar ___target=('claude' 'codex' 'agents')
    local -ar ___scope=('user' 'project')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '*:skills:'
        '--target[Target (repeatable)\: claude, codex, or agents. Defaults to every detected target.]:target:{__codans_complete "${___target[@]}"}'
        '--scope[Scope\: user (default) or project.]:scope:{__codans_complete "${___scope[@]}"}'
        '--project-root[Repository root for --scope project. Defaults to the git root of $PWD.]:project-root:'
        '--force[Replace a directory or foreign link that occupies the skill'\''s name.]'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_skill_uninstall() {
    local -i ret=1
    local -ar ___target=('claude' 'codex' 'agents')
    local -ar ___scope=('user' 'project')
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        '*:skills:'
        '--target[Target (repeatable)\: claude, codex, or agents. Defaults to every detected target.]:target:{__codans_complete "${___target[@]}"}'
        '--scope[Scope\: user (default) or project.]:scope:{__codans_complete "${___scope[@]}"}'
        '--project-root[Repository root for --scope project. Defaults to the git root of $PWD.]:project-root:'
        '--version[Show the version.]'
        '(-h --help)'{-h,--help}'[Show help information.]'
    )
    _arguments -w -s -S : "${arg_specs[@]}" && ret=0

    return "${ret}"
}

_codans_skill_path() {
    local -i ret=1
    local -ar arg_specs=(
        '--json[Emit JSON on stdout instead of human-readable text.]'
        '--socket[Override the socket path (default\: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).]:socket:'
        '--timeout[Client-side timeout in seconds for a single unary call.]:timeout:'
        ':skill:'
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
