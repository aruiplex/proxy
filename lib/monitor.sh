# shellcheck shell=bash
# proxy/lib/monitor.sh — live traffic monitor for the running mihomo core.
# Polls the controller /connections endpoint every N seconds and renders a
# refreshable console dashboard: real-time up/down rate (derived from the
# global traffic totals), cumulative totals, and the active connection table
# (host, rule, proxy chain, per-connection traffic) sorted by usage.
#
#   proxy monitor [--interval <秒>] [--sort down|up|name] [--once]

monitor_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        -h|--help)
            say "用法: proxy monitor [--interval <秒>] [--sort down|up|name] [--once]"
            say ""
            say "持续监控 mihomo 的实时流量与活动连接 (Ctrl-C 退出)。"
            say "  --interval <秒>   刷新间隔, 默认 2"
            say "  --sort down|up|name  连接排序: 按下载/上传流量/主机名, 默认 down"
            say "  --once            只输出一帧后退出 (适合脚本)"
            ;;
        *) monitor_run "$@" ;;
    esac
}

# bytes -> human readable (B/KB/MB/GB)
_fmt_bytes() {
    local b=$1
    if (( b >= 1073741824 )); then printf '%.1f GB' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1073741824}')"
    elif (( b >= 1048576 )); then printf '%.1f MB' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1048576}')"
    elif (( b >= 1024 )); then printf '%.1f KB' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1024}')"
    else printf '%d B' "$b"; fi
}

# bytes/s -> human rate
_fmt_rate() {
    local b=$1
    if (( b >= 1048576 )); then printf '%.1f MB/s' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1048576}')"
    elif (( b >= 1024 )); then printf '%.1f KB/s' "$(awk -v n="$b" 'BEGIN{printf "%.1f", n/1024}')"
    else printf '%d B/s' "$b"; fi
}

monitor_run() {
    json_guard
    ctrl_require
    local interval=2 sort_key=down limit=25 once=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --interval|-n) interval=${2:?}; shift 2 ;;
            --sort)        sort_key=${2:?}; shift 2 ;;
            --once)        once=1; shift ;;
            -h|--help)     monitor_cmd -h; return ;;
            *) die "proxy monitor: 未知参数 $1 (proxy monitor -h)" ;;
        esac
    done
    case "$sort_key" in down|up|name) ;; *) die "proxy monitor: --sort 只支持 down|up|name" ;; esac
    (( interval > 0 )) || die "proxy monitor: --interval 必须为正数"

    local tty=0
    [[ -t 1 ]] && tty=1
    local prev_up= prev_down= up= down= count=
    while true; do
        local snap rows
        snap=$(ctrl_get /connections 2>/dev/null)
        if [[ -z "$snap" ]]; then
            warn "无法获取 /connections (控制器 ↓?)"
            return 1
        fi
        rows=$(printf '%s' "$snap" | python3 -c '
import sys, json
d = json.load(sys.stdin)
conns = d.get("connections", [])
up, down = d.get("uploadTotal"), d.get("downloadTotal")
if up is None:
    up = sum(c.get("upload", 0) for c in conns)
if down is None:
    down = sum(c.get("download", 0) for c in conns)
key_fn, limit = sys.argv[1], int(sys.argv[2])
def key(c):
    if key_fn == "up":
        return c.get("upload", 0)
    if key_fn == "name":
        m = c.get("metadata", {})
        return (m.get("host") or m.get("destinationIP") or "?").lower()
    return c.get("download", 0)
rows = sorted(conns, key=key, reverse=(key_fn != "name"))[:limit]
print("TOTAL %d %d %d" % (up, down, len(conns)))
for c in rows:
    m = c.get("metadata", {})
    host = m.get("host") or m.get("destinationIP") or "?"
    rule = c.get("rule") or "-"
    chains = c.get("chains") or []
    chain = ">".join(chains) if chains else "-"
    print("ROW %s|%s|%s|%d|%d" % (host, rule, chain, c.get("upload", 0), c.get("download", 0)))
' "$sort_key" "$limit" 2>/dev/null)
        [[ -z "$rows" ]] && { warn "解析 /connections 失败"; return 1; }

        local lines up down count
        mapfile -t lines <<< "$rows"
        read -r _ up down count <<< "${lines[0]}"

        # speed from totals delta (guard against counter reset on mihomo restart)
        local up_speed=0 down_speed=0
        if [[ -n "$prev_up" && -n "$prev_down" ]]; then
            up_speed=$(( (up - prev_up) / interval ));   (( up_speed < 0 )) && up_speed=0
            down_speed=$(( (down - prev_down) / interval )); (( down_speed < 0 )) && down_speed=0
        fi
        prev_up=$up; prev_down=$down

        (( tty )) && printf '\033[2J\033[H'
        printf '%s\n' "${C_B}=== mihomo 实时流量 (Ctrl-C 退出, ${interval}s 刷新) ===${C_N}"
        printf '时间: %s\n' "$(date '+%H:%M:%S')"
        printf '速率: %s↑ %s%s  %s↓ %s%s   累计: ↑ %s  ↓ %s   活动连接: %d\n' \
            "$C_G" "$(_fmt_rate "$up_speed")" "$C_N" \
            "$C_G" "$(_fmt_rate "$down_speed")" "$C_N" \
            "$(_fmt_bytes "$up")" "$(_fmt_bytes "$down")" "$count"
        printf '%s\n' "----------------------------------------------------------------------"
        printf '%-3s %-28s %-12s %-26s %10s %10s\n' '#' '主机' '规则' '链路' '↓下载' '↑上传'
        local i=1 line
        for line in "${lines[@]:1}"; do
            local host rule chain u d
            line="${line#ROW }"     # strip python row marker
            IFS='|' read -r host rule chain u d <<< "$line"
            printf '%-3d %-28s %-12s %-26s %10s %10s\n' "$i" "${host:0:28}" "${rule:0:12}" "${chain:0:26}" "$(_fmt_bytes "$d")" "$(_fmt_bytes "$u")"
            ((i++))
        done
        (( once )) && break
        sleep "$interval"
    done
}
