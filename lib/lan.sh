# shellcheck shell=bash
# proxy/lib/lan.sh — allow-lan toggle for LAN devices, persisted through
# subscription refreshes.
#
# mihomo's allow-lan decides whether the mixed-port listens on all interfaces
# (LAN devices can route through this machine). The listener binding used to be
# startup-only — but mihomo 1.19+ rebinds inbounds on a hot reload
# (PUT /configs), so svc_apply (hot reload, restart fallback) suffices.
#
# Subscription refreshes replace config.yaml wholesale, so the choice is
# stored in proxy.conf (key `lan`) and re-forced by _sub_sanitize on every
# fetched config — `lan on` survives `sub use`/`refresh` forever.
#
#   proxy lan on | off | status

lan_cmd() {
    local sub=${1:-}
    case "$sub" in
        on)    lan_set on ;;
        off)   lan_set off ;;
        status|show) lan_status ;;
        -h|--help|"")
            say "用法: proxy lan on | off | status"
            say ""
            say "allow-lan 开关: 开启后局域网内其他设备可用"
            say "http://<本机IP>:<代理端口> 作为代理。设置持久化,"
            say "订阅刷新/切换后自动保留。"
            ;;
        *) die "proxy lan: 未知子命令 $sub" ;;
    esac
}

# rewrite allow-lan (+ bind-address) in config.yaml, in place
_lan_patch() { # <true|false>
    local v=$1
    python3 - "$CONFIG" "$v" <<'PY'
import sys, re
path, v = sys.argv[1], sys.argv[2]
t = open(path).read()
def set_kv(name, val):
    global t
    if re.search(r'(?m)^%s:' % name, t):
        t = re.sub(r'(?m)^%s:.*$' % name, '%s: %s' % (name, val), t)
    else:
        t = t.rstrip('\n') + '\n%s: %s\n' % (name, val)
set_kv('allow-lan', v)
if v == 'true':
    set_kv('bind-address', "'*'")
open(path, 'w').write(t)
PY
}

lan_set() {
    local v=$1
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    conf_set lan "$v"
    _lan_patch "$([[ "$v" == on ]] && echo true || echo false)"
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply >/dev/null 2>&1
    if [[ "$v" == on ]]; then
        local ip port
        if [[ "$(uname -s)" == "Darwin" ]]; then
            ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
        elif has ip; then
            ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{gsub(/\/.*/,"",$2);print $2}' | head -1)
        fi
        port=$(awk -F': *' '/^(mixed-)?port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
        ok "allow-lan: on — 局域网设备: http://${ip:-<本机IP>}:${port:-7890}  (订阅刷新后保留)"
    else
        ok "allow-lan: off — 代理仅本机可用"
    fi
}

lan_status() {
    local v bind p l
    v=$(awk -F': *' '/^allow-lan:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    bind=$(awk -F': *' '/^bind-address:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    p=$(conf_get lan)
    say "allow-lan:  ${v:-false}${bind:+  (bind-address: $bind)}"
    if [[ "$p" == "on" ]]; then
        ok "持久化:    on (订阅刷新自动保留)"
    else
        info "持久化:    ${p:-未设置} (订阅刷新后按订阅自带值)"
    fi
    l=$(ss -ltn 2>/dev/null | grep -E ':(7890|7891)\s' | head -1)
    if [[ -n "$l" ]]; then
        if echo "$l" | grep -qE '0\.0\.0\.0|\*:'; then ok "监听:      $l"
        else info "监听:      $l"
        fi
    fi
}
