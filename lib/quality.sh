# shellcheck shell=bash
quality_cmd() {
    require python3
    local command=$1; shift
    local group= json=0 args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --group)
                [[ $# -ge 2 && -n "$2" ]] || die "--group 缺少 NAME"
                group=$2; shift 2 ;;
            --json) json=1; shift ;;
            -h|--help)
                if [[ "$command" == next ]]; then
                    say '用法: proxy next DOMAIN[:PORT] [--group NAME] [--reason timeout|disconnect|unusable|unknown]'
                    say '默认端口 443；自动查找唯一有建立记录的组，已有连接保持。'
                    return
                fi
                say '用法: proxy quality [--group NAME] [--target HOST:PORT] [--json]'
                say '      proxy feedback HOST:PORT [--group NAME] [--reason timeout|disconnect|unusable|unknown]'
                return ;;
            *) args+=("$1"); shift ;;
        esac
    done
    local options=(--root "$CONF_DIR")
    [[ -n "$group" ]] && options+=(--group "$group")
    [[ "$json" == 1 ]] && options+=(--json)
    python3 "$SCRIPT_DIR/libexec/quality.py" "${options[@]}" "$command" "${args[@]}"
}
