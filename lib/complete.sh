# shellcheck shell=bash
# proxy/lib/complete.sh — bash tab completion for the `proxy` CLI.
# Sourced by the .bashrc hook in interactive bash shells (zsh: enable
# bashcompinit). Covers the static command tree plus dynamic names:
# node members (via the controller, short timeout), subscription names
# (subs.conf), and merge rules (merge.yaml).

_PROXY_COMPLETE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"

_proxy_complete() {
    local cur prev sub1 sub2
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    sub1="${COMP_WORDS[1]}"
    sub2="${COMP_WORDS[2]}"

    local cmds="install init doctor upgrade uninstall start stop restart status log env node merge sub tun check route monitor ui lan pool sync"

    case "$COMP_CWORD" in
        1)
            COMPREPLY=( $(compgen -W "$cmds" -- "$cur") ); return
            ;;
        2)
            case "$sub1" in
                env)     COMPREPLY=( $(compgen -W "on off show" -- "$cur") ) ;;
                node)    COMPREPLY=( $(compgen -W "list test use" -- "$cur") ) ;;
                merge)   COMPREPLY=( $(compgen -W "list add rm diff apply" -- "$cur") ) ;;
                sub)     COMPREPLY=( $(compgen -W "add rm list use show refresh set" -- "$cur") ) ;;
                tun)     COMPREPLY=( $(compgen -W "on off --setup-nopasswd" -- "$cur") ) ;;
                ui)      COMPREPLY=( $(compgen -W "on off status --secret" -- "$cur") ) ;;
                lan)     COMPREPLY=( $(compgen -W "on off status" -- "$cur") ) ;;
                pool)    COMPREPLY=( $(compgen -W "on off status refresh" -- "$cur") ) ;;
                monitor) COMPREPLY=( $(compgen -W "--interval --sort --once" -- "$cur") ) ;;
                sync)    COMPREPLY=( $(compgen -W "export import push pull" -- "$cur") ) ;;
            esac
            return
            ;;
        3)
            case "$sub1" in
                node)
                    case "$sub2" in
                        use|test)
                            # node names via `proxy node list`; guard against a
                            # down controller hanging the tab (timeout where available).
                            # substring match (like `node use`), since names carry
                            # flag emojis that would defeat compgen prefix matching
                            local IFS=$'\n' names n
                            if command -v timeout >/dev/null 2>&1; then
                                names=$(timeout 2 "$_PROXY_COMPLETE_DIR/proxy" node list 2>/dev/null | sed -n 's/^ *[0-9]*) //p')
                            else
                                names=$("$_PROXY_COMPLETE_DIR/proxy" node list 2>/dev/null | sed -n 's/^ *[0-9]*) //p')
                            fi
                            COMPREPLY=()
                            for n in $names; do
                                [[ -z "$cur" || "${n,,}" == *"${cur,,}"* ]] && COMPREPLY+=("$n")
                            done
                            ;;
                    esac
                    ;;
                sub)
                    case "$sub2" in
                        use|rm|show|refresh)
                            local IFS=$'\n' subs
                            subs=$(awk -F'\t' '{print $1}' "${CONF_DIR:-$HOME/.config/mihomo}/subs.conf" 2>/dev/null)
                            COMPREPLY=( $(compgen -W "$subs" -- "$cur") ) ;;
                    esac
                    ;;
                merge)
                    case "$sub2" in
                        rm)
                            # substring match, like `merge rm` itself (rules carry
                            # a rule-type prefix that would defeat compgen prefixing)
                            local IFS=$'\n' rules r
                            rules=$(awk '/^  - /{sub(/^  - /,"");print}' "${CONF_DIR:-$HOME/.config/mihomo}/merge.yaml" 2>/dev/null)
                            COMPREPLY=()
                            for r in $rules; do
                                [[ -z "$cur" || "$r" == *"$cur"* ]] && COMPREPLY+=("$r")
                            done
                            ;;
                    esac
                    ;;
                ui)
                    [[ "$prev" == "--secret" || "$prev" == "-s" ]] && return ;;
                monitor)
                    case "$prev" in
                        --sort) COMPREPLY=( $(compgen -W "down up name" -- "$cur") ) ;;
                    esac
                    ;;
            esac
            ;;
    esac
}

complete -F _proxy_complete proxy 2>/dev/null
