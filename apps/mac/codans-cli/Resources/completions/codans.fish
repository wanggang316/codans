function __tc_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]

    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __tc_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __tc_should_offer_completions_for_positional -a expected_commands expected_positional_index positional_index_comparison
    if test -z $positional_index_comparison
        set positional_index_comparison -eq
    end

    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __tc_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __tc_parse_tokens -S
    set -l unparsed_tokens (__tc_tokens -pc)
    set -l present_flags_and_options

    switch $unparsed_tokens[1]
    case 'codans'
        __tc_parse_subcommand 0 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'status'
            __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'launch'
            __tc_parse_subcommand 0 'json' 'wait=' 'version' 'h/help'
        case 'doctor'
            __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'tree'
            __tc_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
        case 'project'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'add'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'name=' 'version' 'h/help'
            case 'rm'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            end
        case 'worktree'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'path=' 'name=' 'version' 'h/help'
            case 'switch'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'rm'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
            end
        case 'tab'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            case 'switch'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            end
        case 'pane'
            __tc_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __tc_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'cwd=' 'label=+' 'version' 'h/help'
            case 'focus'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'close'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'label'
                __tc_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'replace' 'version' 'h/help'
            case 'reset'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'send'
                __tc_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'p/pane=' 'stdin' 'no-enter' 'version' 'h/help'
            case 'read'
                __tc_parse_subcommand 1 'json' 'socket=' 'timeout=' 'extent=' 'screen' 'selection' 'version' 'h/help'
            end
        case 'broadcast'
            __tc_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'tab=' 'worktree=' 'label=' 'stdin' 'no-enter' 'version' 'h/help'
        case 'help'
            __tc_parse_subcommand -r 1 'version'
        end
    end
end

function __tc_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __tc_parse_subcommand -S -a positional_count
    argparse -s r -- $argv
    set -l option_specs $argv[2..]

    set -a commands $unparsed_tokens[1]
    set -e unparsed_tokens[1]

    set positional_index 0

    while true
        argparse -sn "$commands" $option_specs -- $unparsed_tokens 2> /dev/null
        set unparsed_tokens $argv
        set positional_index (math $positional_index + 1)

        for non_repeating_flag_or_option in $non_repeating_flags_or_options
            if set -ql _flag_$non_repeating_flag_or_option
                set non_repeating_flags_or_options_absent 1
                break
            end
        end

        if test (count $unparsed_tokens) -eq 0 -o \( -z "$_flag_r" -a "$positional_index" -gt "$positional_count" \)
            break
        end
        set -e unparsed_tokens[1]
    end
end

function __tc_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf '%s\n' $subdirs
end

function __tc_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION

    set -l tokens (__tc_tokens -p)
    if test -z (__tc_tokens -t)
        set -l index (count (__tc_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'codans' -f
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'status' -d 'Show the running codans app status.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'launch' -d 'Start codans and wait for its command socket.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'doctor' -d 'Check local CLI configuration and app reachability.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'tree' -d 'List projects, worktrees, tabs, and panes.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'project' -d 'Create and remove projects.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'worktree' -d 'Create, switch, and remove worktrees.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'tab' -d 'Create, switch, and close tabs.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'pane' -d 'Create, focus, close, label, read, reset, and send panes.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'broadcast' -d 'Send text to a tab, worktree, or label scope.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans" 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans status" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans status" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans status" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans status" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans status" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans launch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans launch" wait' -l 'wait' -d 'Seconds to wait for the socket after launching.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans launch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans launch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans doctor" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans doctor" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans doctor" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans doctor" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans doctor" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" project' -l 'project' -d 'Restrict output to one project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tree" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans project" 1' -fa 'add' -d 'Add an existing directory as a project.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans project" 1' -fa 'rm' -d 'Remove a project from codans.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" name' -l 'name' -d 'Display name. Defaults to the directory name.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project rm" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project rm" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project rm" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project rm" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans project rm" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans worktree" 1' -fa 'new' -d 'Create a worktree entry.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans worktree" 1' -fa 'switch' -d 'Activate a worktree.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans worktree" 1' -fa 'rm' -d 'Remove a worktree entry.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" path' -l 'path' -d 'Path for the worktree. Defaults to the project\'s configured worktrees directory.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" name' -l 'name' -d 'Display name. Defaults to the branch name.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree switch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree switch" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree switch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree switch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree switch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans worktree rm" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans tab" 1' -fa 'new' -d 'Create a tab.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans tab" 1' -fa 'switch' -d 'Activate a tab.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans tab" 1' -fa 'close' -d 'Close a tab.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab switch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab switch" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab switch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab switch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab switch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans tab close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'new' -d 'Create a pane, optionally with an initial command.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'focus' -d 'Focus a pane.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'close' -d 'Close a pane.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'label' -d 'Add labels to a pane.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'reset' -d 'Reset a pane\'s terminal state.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'send' -d 'Send text to a pane.'
complete -c 'codans' -n '__tc_should_offer_completions_for_positional "codans pane" 1' -fa 'read' -d 'Read text from a pane.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" tab' -l 'tab' -d 'Tab id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" cwd' -l 'cwd' -d 'Working directory. Defaults to $PWD.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new"' -l 'label' -d 'Initial labels.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" project' -l 'project' -d 'Project id, name, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" worktree' -l 'worktree' -d 'Worktree id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" tab' -l 'tab' -d 'Tab id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane focus" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" project' -l 'project' -d 'Project id, name, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" worktree' -l 'worktree' -d 'Worktree id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" tab' -l 'tab' -d 'Tab id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" replace' -l 'replace' -d 'Replace the existing labels.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane label" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane reset" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane reset" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane reset" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane reset" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane reset" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" p pane' -s 'p' -l 'pane' -d 'Target pane id, @label, or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" stdin' -l 'stdin' -d 'Read text from stdin.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" no-enter' -l 'no-enter' -d 'Do not send trailing Enter after text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane send" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" extent' -l 'extent' -d 'Text extent to read: viewport, screen, or selection.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" screen' -l 'screen' -d 'Shortcut for --extent screen.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" selection' -l 'selection' -d 'Shortcut for --extent selection.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans pane read" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" tab' -l 'tab' -d 'Tab id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" label' -l 'label' -d 'Pane label.' -rfka ''
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" stdin' -l 'stdin' -d 'Read text from stdin.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" no-enter' -l 'no-enter' -d 'Do not send trailing Enter after text.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans broadcast" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__tc_should_offer_completions_for_flags_or_options "codans help" version' -l 'version' -d 'Show the version.'
