# shellcheck shell=bash
# Only render candidate files. Normal prepare/activate validates and selects them.
auto_cmd() {
    require python3
    local sub=${1:-}; shift || true
    case "$sub" in
        prepare)
            local config="$CONFIG" prefs="$SCRIPT_DIR/templates/adaptive.example.json" output=
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --config|--preferences|--output)
                        [[ $# -ge 2 && -n "$2" ]] || die "$1 缺少 FILE"
                        case "$1" in --config) config=$2 ;; --preferences) prefs=$2 ;; --output) output=$2 ;; esac
                        shift 2 ;;
                    *) die "proxy auto prepare: 未知参数 $1" ;;
                esac
            done
            [[ -n "$output" ]] || die "指定新文件路径: proxy auto prepare --output FILE"
            python3 "$SCRIPT_DIR/libexec/adaptive_config.py" --config "$config" --preferences "$prefs" --output "$output" || return 1
            ok "候选配置已生成: $output。尚未启用；用 kernel prepare --config FILE --preferences FILE 校验，再维护启用。"
            ;;
        -h|--help|help|"")
            say '用法: proxy auto prepare --output NEW_FILE [--config FILE] [--preferences FILE]'
            say '保留规则条件和 DIRECT/REJECT；默认将 MATCH 所用代理策略的 TCP 交给原范围内的代理节点，UDP 保留原策略。'
            say '其他策略通过偏好 policies 列表明确指定。只生成候选文件，不改运行状态。'
            ;;
        *) die "proxy auto: 未知子命令 $sub" ;;
    esac
}

_adaptive_replay() { # a subscription/pool candidate, never the live file
    [[ -f "$CONF_DIR/adaptive.json" ]] || return 0
    python3 "$SCRIPT_DIR/libexec/adaptive_config.py" --config "$1" --preferences "$CONF_DIR/adaptive.json" --in-place
}
