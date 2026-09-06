function __codans_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]

    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __codans_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __codans_should_offer_completions_for_positional -a expected_commands expected_positional_index positional_index_comparison
    if test -z $positional_index_comparison
        set positional_index_comparison -eq
    end

    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __codans_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __codans_parse_tokens -S
    set -l unparsed_tokens (__codans_tokens -pc)
    set -l present_flags_and_options

    switch $unparsed_tokens[1]
    case 'codans'
        __codans_parse_subcommand 0 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'status'
            __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'launch'
            __codans_parse_subcommand 0 'json' 'wait=' 'version' 'h/help'
        case 'doctor'
            __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
        case 'tree'
            __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
        case 'project'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'add'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'name=' 'version' 'h/help'
            case 'rm'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'commands'
                __codans_parse_subcommand 0 'version' 'h/help'
                switch $unparsed_tokens[1]
                case 'list'
                    __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
                case 'add'
                    __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'project=' 'name=' 'command=' 'kind=' 'target=' 'direction=' 'on-finished=' 'focus' 'no-focus' 'version' 'h/help'
                case 'edit'
                    __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'name=' 'command=' 'kind=' 'target=' 'direction=' 'on-finished=' 'focus' 'no-focus' 'version' 'h/help'
                case 'rm'
                    __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'version' 'h/help'
                end
            end
        case 'worktree'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'path=' 'name=' 'reuse-existing' 'version' 'h/help'
            case 'switch'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'rm'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'by-path=' 'all' 'version' 'h/help'
            end
        case 'tab'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            case 'switch'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'close'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'version' 'h/help'
            end
        case 'pane'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'new'
                __codans_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'cwd=' 'label=+' 'version' 'h/help'
            case 'focus'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'close'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'project=' 'worktree=' 'tab=' 'version' 'h/help'
            case 'label'
                __codans_parse_subcommand -r 2 'json' 'socket=' 'timeout=' 'replace' 'version' 'h/help'
            case 'reset'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'send'
                __codans_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'p/pane=' 'stdin' 'no-enter' 'raw=' 'focus' 'version' 'h/help'
            case 'send-key'
                __codans_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'p/pane=' 'focus' 'version' 'h/help'
            case 'read'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'raw' 'tail=' 'range=' 'version' 'h/help'
            case 'info'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'capture'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'scope=' 'lines=' 'wait-stable' 'stable-ms=' 'interval-ms=' 'timeout-ms=' 'version' 'h/help'
            end
        case 'broadcast'
            __codans_parse_subcommand -r 1 'json' 'socket=' 'timeout=' 'tab=' 'worktree=' 'label=' 'stdin' 'no-enter' 'version' 'h/help'
        case 'agent'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'version' 'h/help'
            case 'launch'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'agent=' 'project=' 'worktree=' 'prompt=' 'tab' 'split=' 'background' 'version' 'h/help'
            end
        case 'handoff'
            __codans_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'to'
                __codans_parse_subcommand 1 'json' 'socket=' 'timeout=' 'pane=' 'profile=' 'brief=' 'no-brief' 'note=' 'no-launch' 'version' 'h/help'
            case 'save'
                __codans_parse_subcommand 0 'json' 'socket=' 'timeout=' 'pane=' 'brief=' 'no-brief' 'note=' 'version' 'h/help'
            end
        case 'help'
            __codans_parse_subcommand -r 1 'version'
        end
    end
end

function __codans_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __codans_parse_subcommand -S -a positional_count
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

function __codans_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf '%s\n' $subdirs
end

function __codans_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION

    set -l tokens (__codans_tokens -p)
    if test -z (__codans_tokens -t)
        set -l index (count (__codans_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'codans' -f
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'status' -d 'Show the running Codans app status.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'launch' -d 'Start Codans and wait for its command socket.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'doctor' -d 'Check local CLI configuration and app reachability.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'tree' -d 'List projects, worktrees, tabs, and panes.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'project' -d 'Create and remove projects.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'worktree' -d 'Create, switch, and remove worktrees.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'tab' -d 'Create, switch, and close tabs.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'pane' -d 'Create, focus, close, label, read, reset, and send panes.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'broadcast' -d 'Send text to a tab, worktree, or label scope.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'agent' -d 'List and launch coding-agent profiles.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'handoff' -d 'Hand a task off between coding agents: archive, brief, and launch the receiver.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans" 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans status" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans status" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans status" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans status" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans status" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans launch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans launch" wait' -l 'wait' -d 'Seconds to wait for the socket after launching.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans launch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans launch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans doctor" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans doctor" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans doctor" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans doctor" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans doctor" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" project' -l 'project' -d 'Restrict output to one project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tree" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project" 1' -fa 'add' -d 'Add an existing directory as a project.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project" 1' -fa 'rm' -d 'Remove a project from Codans.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project" 1' -fa 'commands' -d 'Inspect and manage a project\'s saved commands.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" name' -l 'name' -d 'Display name. Defaults to the directory name.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project rm" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project rm" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project rm" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project rm" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project rm" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project commands" 1' -fa 'list' -d 'List a project\'s saved commands.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project commands" 1' -fa 'add' -d 'Add a command to a project.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project commands" 1' -fa 'edit' -d 'Edit a project\'s saved command (only the flags you pass change).'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans project commands" 1' -fa 'rm' -d 'Remove a project\'s saved command.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" name' -l 'name' -d 'Display name. Defaults to the kind\'s label.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" command' -l 'command' -d 'Shell command to run.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" kind' -l 'kind' -d 'Kind: run | test | deploy | lint | format | custom.' -rfka 'run test deploy lint format custom'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" target' -l 'target' -d 'Where it runs: focused | newTab | split.' -rfka 'focused newTab split'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" direction' -l 'direction' -d 'Split direction (split target only): up | down | left | right.' -rfka 'up down left right'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" on-finished' -l 'on-finished' -d 'On completion (spawning targets): none | closePane | closeTab.' -rfka 'none closePane closeTab'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" focus' -l 'focus' -d 'Steal focus to the spawned surface (default: focus).'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" no-focus' -l 'no-focus' -d 'Steal focus to the spawned surface (default: focus).'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" name' -l 'name' -d 'New display name (pass "" to clear it).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" command' -l 'command' -d 'New shell command.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" kind' -l 'kind' -d 'Kind: run | test | deploy | lint | format | custom.' -rfka 'run test deploy lint format custom'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" target' -l 'target' -d 'Where it runs: focused | newTab | split.' -rfka 'focused newTab split'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" direction' -l 'direction' -d 'Split direction: up | down | left | right.' -rfka 'up down left right'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" on-finished' -l 'on-finished' -d 'On completion: none | closePane | closeTab.' -rfka 'none closePane closeTab'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" focus' -l 'focus' -d 'Steal focus to the spawned surface.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" no-focus' -l 'no-focus' -d 'Steal focus to the spawned surface.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands edit" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans project commands rm" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans worktree" 1' -fa 'new' -d 'Create a worktree entry.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans worktree" 1' -fa 'switch' -d 'Activate a worktree.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans worktree" 1' -fa 'rm' -d 'Remove a worktree entry.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" path' -l 'path' -d 'Path for the worktree. Defaults to the project\'s configured worktrees directory.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" name' -l 'name' -d 'Display name. Defaults to the branch name.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" reuse-existing' -l 'reuse-existing' -d 'If a worktree with the same canonical path already exists, return its id instead of failing with a conflict. Name collisions still fail.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree switch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree switch" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree switch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree switch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree switch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" by-path' -l 'by-path' -d 'Remove every worktree row in the project whose canonical path equals this path. Mutually exclusive with the positional worktree argument.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" all' -l 'all' -d 'With --by-path, allow removing more than one matching row. Without --all, --by-path requires exactly one match.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans worktree rm" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans tab" 1' -fa 'new' -d 'Create a tab.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans tab" 1' -fa 'switch' -d 'Activate a tab.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans tab" 1' -fa 'close' -d 'Close a tab.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab switch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab switch" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab switch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab switch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab switch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans tab close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'new' -d 'Create a pane, optionally with an initial command.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'focus' -d 'Focus a pane.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'close' -d 'Close a pane and kill its zmx daemon.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'label' -d 'Add labels to a pane.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'reset' -d 'Reset a pane\'s terminal state.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'send' -d 'Send text to a pane.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'send-key' -d 'Send a named special key to a pane.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'read' -d 'Read serialized terminal state from a pane\'s zmx daemon.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'info' -d 'Probe a pane\'s zmx daemon for shell pid, pwd, and (when available) cursor + modes.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans pane" 1' -fa 'capture' -d 'Capture a pane\'s rendered text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" tab' -l 'tab' -d 'Tab id, t<n> handle, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" cwd' -l 'cwd' -d 'Working directory. Defaults to $PWD.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new"' -l 'label' -d 'Initial labels.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane new" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" project' -l 'project' -d 'Project id, name, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" worktree' -l 'worktree' -d 'Worktree id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" tab' -l 'tab' -d 'Tab id, t<n> handle, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane focus" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" project' -l 'project' -d 'Project id, name, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" worktree' -l 'worktree' -d 'Worktree id or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" tab' -l 'tab' -d 'Tab id, t<n> handle, or \'current\'. Usually inferred from the pane id.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane close" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" replace' -l 'replace' -d 'Replace the existing labels.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane label" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane reset" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane reset" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane reset" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane reset" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane reset" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" p pane' -s 'p' -l 'pane' -d 'Target pane id, p<n> handle, @label, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" stdin' -l 'stdin' -d 'Read text from stdin.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" no-enter' -l 'no-enter' -d 'Do not send trailing Enter after text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" raw' -l 'raw' -d 'Send raw bytes as a hex string (e.g. 1b5b41 for ESC [ A).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" focus' -l 'focus' -d 'Focus the target pane after sending.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" p pane' -s 'p' -l 'pane' -d 'Target pane id, p<n> handle, @label, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" focus' -l 'focus' -d 'Focus the target pane after sending.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane send-key" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" raw' -l 'raw' -d 'Return the vt-format dump with ANSI escapes preserved.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" tail' -l 'tail' -d 'Keep only the last N newline-delimited lines.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" range' -l 'range' -d 'Range: visible, scrollback, or all (default).' -rfka 'visible scrollback all'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane read" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane info" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane info" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane info" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane info" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane info" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" scope' -l 'scope' -d 'Capture scope: viewport (default) or screen.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" lines' -l 'lines' -d 'Trim output to the last N non-empty lines.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" wait-stable' -l 'wait-stable' -d 'Poll until the rendered text stops changing before capturing.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" stable-ms' -l 'stable-ms' -d 'Wait-stable: quiet window in ms the output must hold unchanged (default 500).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" interval-ms' -l 'interval-ms' -d 'Wait-stable: poll interval in ms (default 100).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" timeout-ms' -l 'timeout-ms' -d 'Wait-stable: overall cap in ms before giving up (default 5000).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans pane capture" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" tab' -l 'tab' -d 'Tab id, t<n> handle, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" label' -l 'label' -d 'Pane label.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" stdin' -l 'stdin' -d 'Read text from stdin.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" no-enter' -l 'no-enter' -d 'Do not send trailing Enter after text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans broadcast" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans agent" 1' -fa 'list' -d 'List agent profiles with their agent, enabled state, and launch command.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans agent" 1' -fa 'launch' -d 'Start an agent profile in a worktree.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent list" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent list" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent list" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent list" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" agent' -l 'agent' -d 'Agent token (claude, codex, gemini, …) when no profile is named.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" project' -l 'project' -d 'Project id, name, or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" worktree' -l 'worktree' -d 'Worktree id or \'current\'.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" prompt' -l 'prompt' -d 'Kickoff prompt; pass \'-\' to read it from stdin.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" tab' -l 'tab' -d 'Open in a new tab (overrides the profile\'s placement).'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" split' -l 'split' -d 'Split the focused pane: right, left, up, or down.' -rfka 'right left up down'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" background' -l 'background' -d 'Do not select the new tab or move focus.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans agent launch" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans handoff" 1' -fa 'to' -d 'Archive the outgoing state, install the briefing, and launch the receiving agent.'
complete -c 'codans' -n '__codans_should_offer_completions_for_positional "codans handoff" 1' -fa 'save' -d 'Checkpoint: install a fresh briefing and refresh generated context, without launching.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" pane' -l 'pane' -d 'Source pane id, p<n> handle, @label, or \'current\' (the calling pane).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" profile' -l 'profile' -d 'Profile (name or id) to launch the receiver with.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" brief' -l 'brief' -d 'Inline briefing; pass \'-\' to read it from stdin (heredoc).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" no-brief' -l 'no-brief' -d 'Context-only: skip the briefing entirely.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" note' -l 'note' -d 'Note appended to the handoff log.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" no-launch' -l 'no-launch' -d 'Archive and save only; do not start the receiver.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff to" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" json' -l 'json' -d 'Emit JSON on stdout instead of human-readable text.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" socket' -l 'socket' -d 'Override the socket path (default: $CODANS_SOCKET_PATH → Debug /tmp/codans-dev-<uid>.sock, Release /tmp/codans-<uid>.sock).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" timeout' -l 'timeout' -d 'Client-side timeout in seconds for a single unary call.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" pane' -l 'pane' -d 'Source pane id, p<n> handle, @label, or \'current\' (the calling pane).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" brief' -l 'brief' -d 'Inline briefing; pass \'-\' to read it from stdin (heredoc).' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" no-brief' -l 'no-brief' -d 'Context-only: skip the briefing entirely.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" note' -l 'note' -d 'Note appended to the handoff log.' -rfka ''
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" version' -l 'version' -d 'Show the version.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans handoff save" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'codans' -n '__codans_should_offer_completions_for_flags_or_options "codans help" version' -l 'version' -d 'Show the version.'
