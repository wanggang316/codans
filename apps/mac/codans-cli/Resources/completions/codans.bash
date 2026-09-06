#!/bin/bash

__codans_cursor_index_in_current_word() {
    local remaining="${COMP_LINE}"

    local word
    for word in "${COMP_WORDS[@]::COMP_CWORD}"; do
        remaining="${remaining##*([[:space:]])"${word}"*([[:space:]])}"
    done

    local -ir index="$((COMP_POINT - ${#COMP_LINE} + ${#remaining}))"
    if [[ "${index}" -le 0 ]]; then
        printf 0
    else
        printf %s "${index}"
    fi
}

# positional arguments:
#
# - 1: the current (sub)command's count of positional arguments
#
# required variables:
#
# - repeating_flags: the repeating flags that the current (sub)command can accept
# - non_repeating_flags: the non-repeating flags that the current (sub)command can accept
# - repeating_options: the repeating options that the current (sub)command can accept
# - non_repeating_options: the non-repeating options that the current (sub)command can accept
# - positional_number: value ignored
# - unparsed_words: unparsed words from the current command line
#
# modified variables:
#
# - non_repeating_flags: remove flags for this (sub)command that are already on the command line
# - non_repeating_options: remove options for this (sub)command that are already on the command line
# - positional_number: set to the current positional number
# - unparsed_words: remove all flags, options, and option values for this (sub)command
__codans_offer_flags_options() {
    local -ir positional_count="${1}"
    positional_number=0

    local was_flag_option_terminator_seen=false
    local is_parsing_option_value=false

    local -ar unparsed_word_indices=("${!unparsed_words[@]}")
    local -i word_index
    for word_index in "${unparsed_word_indices[@]}"; do
        if "${is_parsing_option_value}"; then
            # This word is an option value:
            # Reset marker for next word iff not currently the last word
            [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]] && is_parsing_option_value=false
            unset "unparsed_words[${word_index}]"
            # Do not process this word as a flag or an option
            continue
        fi

        local word="${unparsed_words["${word_index}"]}"
        if ! "${was_flag_option_terminator_seen}"; then
            case "${word}" in
            --)
                unset "unparsed_words[${word_index}]"
                # by itself -- is a flag/option terminator, but if it is the last word, it is the start of a completion
                if [[ "${word_index}" -ne "${unparsed_word_indices[${#unparsed_word_indices[@]} - 1]}" ]]; then
                    was_flag_option_terminator_seen=true
                fi
                continue
                ;;
            -*)
                # ${word} is a flag or an option
                # If ${word} is an option, mark that the next word to be parsed is an option value
                local option
                for option in "${repeating_options[@]}" "${non_repeating_options[@]}"; do
                    [[ "${word}" = "${option}" ]] && is_parsing_option_value=true && break
                done

                # Remove ${word} from ${non_repeating_flags} or ${non_repeating_options} so it isn't offered again
                local not_found=true
                local -i index
                for index in "${!non_repeating_flags[@]}"; do
                    if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                        unset "non_repeating_flags[${index}]"
                        non_repeating_flags=("${non_repeating_flags[@]}")
                        not_found=false
                        break
                    fi
                done
                if "${not_found}"; then
                    for index in "${!non_repeating_flags[@]}"; do
                        if [[ "${non_repeating_flags[${index}]}" = "${word}" ]]; then
                            unset "non_repeating_flags[${index}]"
                            non_repeating_flags=("${non_repeating_flags[@]}")
                            break
                        fi
                    done
                fi
                unset "unparsed_words[${word_index}]"
                continue
                ;;
            esac
        fi

        # ${word} is neither a flag, nor an option, nor an option value
        if [[ "${positional_number}" -lt "${positional_count}" || "${positional_count}" -lt 0 ]]; then
            # ${word} is a positional
            ((positional_number++))
            unset "unparsed_words[${word_index}]"
        else
            if [[ -z "${word}" ]]; then
                # Could be completing a flag, option, or subcommand
                positional_number=-1
            else
                # ${word} is a subcommand or invalid, so stop processing this (sub)command
                positional_number=-2
            fi
            break
        fi
    done

    unparsed_words=("${unparsed_words[@]}")

    if\
        ! "${was_flag_option_terminator_seen}"\
        && ! "${is_parsing_option_value}"\
        && [[ ("${cur}" = -* && "${positional_number}" -ge 0) || "${positional_number}" -eq -1 ]]
    then
        COMPREPLY+=($(compgen -W "${repeating_flags[*]} ${non_repeating_flags[*]} ${repeating_options[*]} ${non_repeating_options[*]}" -- "${cur}"))
    fi
}

__codans_add_completions() {
    local completion
    while IFS='' read -r completion; do
        COMPREPLY+=("${completion}")
    done < <(IFS=$'\n' compgen "${@}" -- "${cur}")
}

__codans_custom_complete() {
    if [[ -n "${cur}" || -z ${COMP_WORDS[${COMP_CWORD}]} || "${COMP_LINE:${COMP_POINT}:1}" != ' ' ]]; then
        local -ar words=("${COMP_WORDS[@]}")
    else
        local -ar words=("${COMP_WORDS[@]::${COMP_CWORD}}" '' "${COMP_WORDS[@]:${COMP_CWORD}}")
    fi

    "${COMP_WORDS[0]}" "${@}" "${words[@]}"
}

_codans() {
    local state
    state="$(shopt -p;shopt -po)"
    trap "${state//$'\n'/;}" RETURN
    shopt -s extglob
    set +o history +o posix

    local -xr SAP_SHELL=bash
    local -x SAP_SHELL_VERSION
    SAP_SHELL_VERSION="$(IFS='.';printf %s "${BASH_VERSINFO[*]}")"
    local -r SAP_SHELL_VERSION

    local -r cur="${2}"
    local -r prev="${3}"

    local -i positional_number
    local -a unparsed_words=("${COMP_WORDS[@]:1:${COMP_CWORD}}")

    local -a repeating_flags=()
    local -a non_repeating_flags=(--version -h --help)
    local -a repeating_options=()
    local -a non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    status|launch|doctor|tree|project|worktree|tab|pane|broadcast|agent|handoff|help)
        # Offer subcommand argument completions
        "_codans_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'status launch doctor tree project worktree tab pane broadcast agent handoff help' -- "${cur}"))
        ;;
    esac
}

_codans_status() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_launch() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--wait)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--wait')
        return
        ;;
    esac
}

_codans_doctor() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_tree() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    esac
}

_codans_project() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    add|rm|commands)
        # Offer subcommand argument completions
        "_codans_project_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'add rm commands' -- "${cur}"))
        ;;
    esac
}

_codans_project_add() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --name)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--name')
        return
        ;;
    esac
}

_codans_project_rm() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_project_commands() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|add|edit|rm)
        # Offer subcommand argument completions
        "_codans_project_commands_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list add edit rm' -- "${cur}"))
        ;;
    esac
}

_codans_project_commands_list() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    esac
}

_codans_project_commands_add() {
    repeating_flags=()
    non_repeating_flags=(--json --focus --no-focus --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --name --command --kind --target --direction --on-finished)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--name')
        return
        ;;
    '--command')
        return
        ;;
    '--kind')
        __codans_add_completions -W 'run'$'\n''test'$'\n''deploy'$'\n''lint'$'\n''format'$'\n''custom'
        return
        ;;
    '--target')
        __codans_add_completions -W 'focused'$'\n''newTab'$'\n''split'
        return
        ;;
    '--direction')
        __codans_add_completions -W 'up'$'\n''down'$'\n''left'$'\n''right'
        return
        ;;
    '--on-finished')
        __codans_add_completions -W 'none'$'\n''closePane'$'\n''closeTab'
        return
        ;;
    esac
}

_codans_project_commands_edit() {
    repeating_flags=()
    non_repeating_flags=(--json --focus --no-focus --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --name --command --kind --target --direction --on-finished)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--name')
        return
        ;;
    '--command')
        return
        ;;
    '--kind')
        __codans_add_completions -W 'run'$'\n''test'$'\n''deploy'$'\n''lint'$'\n''format'$'\n''custom'
        return
        ;;
    '--target')
        __codans_add_completions -W 'focused'$'\n''newTab'$'\n''split'
        return
        ;;
    '--direction')
        __codans_add_completions -W 'up'$'\n''down'$'\n''left'$'\n''right'
        return
        ;;
    '--on-finished')
        __codans_add_completions -W 'none'$'\n''closePane'$'\n''closeTab'
        return
        ;;
    esac
}

_codans_project_commands_rm() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    esac
}

_codans_worktree() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    new|switch|rm)
        # Offer subcommand argument completions
        "_codans_worktree_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'new switch rm' -- "${cur}"))
        ;;
    esac
}

_codans_worktree_new() {
    repeating_flags=()
    non_repeating_flags=(--json --reuse-existing --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --path --name)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--path')
        return
        ;;
    '--name')
        return
        ;;
    esac
}

_codans_worktree_switch() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_worktree_rm() {
    repeating_flags=()
    non_repeating_flags=(--json --all --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --by-path)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--by-path')
        return
        ;;
    esac
}

_codans_tab() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    new|switch|close)
        # Offer subcommand argument completions
        "_codans_tab_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'new switch close' -- "${cur}"))
        ;;
    esac
}

_codans_tab_new() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --worktree)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    esac
}

_codans_tab_switch() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_tab_close() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --worktree)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    esac
}

_codans_pane() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    new|focus|close|label|reset|send|send-key|read|info|capture)
        # Offer subcommand argument completions
        "_codans_pane_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'new focus close label reset send send-key read info capture' -- "${cur}"))
        ;;
    esac
}

_codans_pane_new() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=(--label)
    non_repeating_options=(--socket --timeout --project --worktree --tab --cwd)
    __codans_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    '--tab')
        return
        ;;
    '--cwd')
        return
        ;;
    '--label')
        return
        ;;
    esac
}

_codans_pane_focus() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --worktree --tab)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    '--tab')
        return
        ;;
    esac
}

_codans_pane_close() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --project --worktree --tab)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    '--tab')
        return
        ;;
    esac
}

_codans_pane_label() {
    repeating_flags=()
    non_repeating_flags=(--json --replace --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_pane_reset() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_pane_send() {
    repeating_flags=()
    non_repeating_flags=(--json --stdin --no-enter --focus --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout -p --pane --raw)
    __codans_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '-p'|'--pane')
        return
        ;;
    '--raw')
        return
        ;;
    esac
}

_codans_pane_send-key() {
    repeating_flags=()
    non_repeating_flags=(--json --focus --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout -p --pane)
    __codans_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '-p'|'--pane')
        return
        ;;
    esac
}

_codans_pane_read() {
    repeating_flags=()
    non_repeating_flags=(--json --raw --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --tail --range)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--tail')
        return
        ;;
    '--range')
        __codans_add_completions -W 'visible'$'\n''scrollback'$'\n''all'
        return
        ;;
    esac
}

_codans_pane_info() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_pane_capture() {
    repeating_flags=()
    non_repeating_flags=(--json --wait-stable --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --scope --lines --stable-ms --interval-ms --timeout-ms)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--scope')
        return
        ;;
    '--lines')
        return
        ;;
    '--stable-ms')
        return
        ;;
    '--interval-ms')
        return
        ;;
    '--timeout-ms')
        return
        ;;
    esac
}

_codans_broadcast() {
    repeating_flags=()
    non_repeating_flags=(--json --stdin --no-enter --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --tab --worktree --label)
    __codans_offer_flags_options -1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--tab')
        return
        ;;
    '--worktree')
        return
        ;;
    '--label')
        return
        ;;
    esac
}

_codans_agent() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    list|launch)
        # Offer subcommand argument completions
        "_codans_agent_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'list launch' -- "${cur}"))
        ;;
    esac
}

_codans_agent_list() {
    repeating_flags=()
    non_repeating_flags=(--json --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    esac
}

_codans_agent_launch() {
    repeating_flags=()
    non_repeating_flags=(--json --tab --background --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --agent --project --worktree --prompt --split)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--agent')
        return
        ;;
    '--project')
        return
        ;;
    '--worktree')
        return
        ;;
    '--prompt')
        return
        ;;
    '--split')
        __codans_add_completions -W 'right'$'\n''left'$'\n''up'$'\n''down'
        return
        ;;
    esac
}

_codans_handoff() {
    repeating_flags=()
    non_repeating_flags=(--version -h --help)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options 0

    # Offer subcommand / subcommand argument completions
    local -r subcommand="${unparsed_words[0]}"
    unset 'unparsed_words[0]'
    unparsed_words=("${unparsed_words[@]}")
    case "${subcommand}" in
    to|save)
        # Offer subcommand argument completions
        "_codans_handoff_${subcommand}"
        ;;
    *)
        # Offer subcommand completions
        COMPREPLY+=($(compgen -W 'to save' -- "${cur}"))
        ;;
    esac
}

_codans_handoff_to() {
    repeating_flags=()
    non_repeating_flags=(--json --no-brief --no-launch --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --pane --profile --brief --note)
    __codans_offer_flags_options 1

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--pane')
        return
        ;;
    '--profile')
        return
        ;;
    '--brief')
        return
        ;;
    '--note')
        return
        ;;
    esac
}

_codans_handoff_save() {
    repeating_flags=()
    non_repeating_flags=(--json --no-brief --version -h --help)
    repeating_options=()
    non_repeating_options=(--socket --timeout --pane --brief --note)
    __codans_offer_flags_options 0

    # Offer option value completions
    case "${prev}" in
    '--socket')
        return
        ;;
    '--timeout')
        return
        ;;
    '--pane')
        return
        ;;
    '--brief')
        return
        ;;
    '--note')
        return
        ;;
    esac
}

_codans_help() {
    repeating_flags=()
    non_repeating_flags=(--version)
    repeating_options=()
    non_repeating_options=()
    __codans_offer_flags_options -1
}

complete -o filenames -F _codans codans
