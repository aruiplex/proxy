# shellcheck shell=bash
# proxy/lib/env.sh — proxy environment-variable injection via a .bashrc hook.
# A child process cannot edit its parent shell's env, so the hook does
# `eval "$(proxy _login 2>/dev/null)"` at shell start: _login prints export/unset
# lines to stdout (applied by the parent) and keeps all diagnostics on stderr.

_env_custom_addr() {
    local a; a=$(conf_get proxy_addr)
    if [[ "$a" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9._-]+):([1-9][0-9]*)$ ]] \
       && (( BASH_REMATCH[2] >= 1 && BASH_REMATCH[2] <= 65535 )); then
        printf '%s' "$a"
        return 0
    fi
    return 1
}

_env_config_port() {
    local key=$1 port
    port=$(awk -v k="$key" '$0 ~ "^"k":[[:space:]]*[0-9]+[[:space:]]*$" {print $2;exit}' "$CONFIG" 2>/dev/null)
    [[ "$port" =~ ^[1-9][0-9]*$ ]] && (( port <= 65535 )) || return 1
    printf '%s' "$port"
}

proxy_addr() {
    local addr port
    addr=$(_env_custom_addr) && { printf '%s' "$addr"; return; }
    port=$(_env_config_port mixed-port) || port=$(_env_config_port port) || port=7890
    printf '127.0.0.1:%s' "$port"
}

proxy_socks_addr() {
    local addr port
    addr=$(_env_custom_addr) && { printf '%s' "$addr"; return; }
    port=$(_env_config_port mixed-port) || port=$(_env_config_port socks-port) || return 1
    printf '127.0.0.1:%s' "$port"
}

# print export/unset lines based on the on/off toggle (no side effects, no logging)
_env_exports() {
    local st addr socks
    st=$(cat "$ENV_STATE" 2>/dev/null)
    addr=$(proxy_addr)
    socks=$(proxy_socks_addr)
    if [[ "$st" == "on" ]]; then
        printf 'export http_proxy=%q\n' "http://$addr"
        printf 'export https_proxy=%q\n' "http://$addr"
        if [[ -n "$socks" ]]; then printf 'export all_proxy=%q\n' "socks5h://$socks"
        else printf 'unset all_proxy ALL_PROXY\n'; fi
        printf 'export HTTP_PROXY=%q\n' "http://$addr"
        printf 'export HTTPS_PROXY=%q\n' "http://$addr"
        [[ -n "$socks" ]] && printf 'export ALL_PROXY=%q\n' "socks5h://$socks"
        printf 'export no_proxy=localhost,127.0.0.1,::1\n'
        printf 'export NO_PROXY=localhost,127.0.0.1,::1\n'
    else
        printf 'unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY\n'
    fi
}

# internal: called by the .bashrc hook. Autostarts mihomo if down, then emits env.
# Interactivity is checked by the hook line itself (the parent shell); this always
# emits so `eval "$(proxy _login)"` works regardless of this child's $-.
env_login() {
    local bin tun_enabled
    if ! has python3; then
        _env_exports
        return
    fi
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    tun_enabled=$(awk '/^tun:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/enable:[[:space:]]*true/{print 1;exit}' "$CONFIG" 2>/dev/null)
    if [[ "$tun_enabled" != 1 ]] && bin=$(mihomo_bin 2>/dev/null) && [[ -f "$CONFIG" ]] && ! svc_pid >/dev/null; then
        ( nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
          printf '%s\n' "$!" > "$PID_FILE" ) 2>/dev/null
    fi
    _env_exports
}

env_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        on)
            mkdir -p "$CONF_DIR"; printf 'on\n' > "$ENV_STATE"
            ok "代理环境设置已开启 (已安装的 proxy Shell 函数会同步当前终端)"
            if ! detect_running; then
                warn "⚠️ mihomo 核心未在运行，流量尚无法转发。可运行: proxy start"
            fi
            ;;
        off)
            mkdir -p "$CONF_DIR"; printf 'off\n' > "$ENV_STATE"
            ok "代理环境设置已关闭 (已安装的 proxy Shell 函数会同步当前终端)"
            ;;
        toggle)
            local cur; cur=$(cat "$ENV_STATE" 2>/dev/null)
            if [[ "$cur" == "on" ]]; then
                env_cmd off
            else
                env_cmd on
            fi
            ;;
        show) _env_exports ;;
        -h|--help) say "用法: proxy env on|off|toggle|show  (开关存 $ENV_STATE, 由 .bashrc 钩子在 shell 启动时应用)" ;;
        "")
            local st; st=$(cat "$ENV_STATE" 2>/dev/null)
            if [[ "$st" == "on" ]]; then
                ok "当前代理环境变量: on (开启)"
            else
                info "当前代理环境变量: off (关闭)"
            fi
            say "用法: proxy env on | off | toggle | show  (快捷指令: proxy on / proxy off / proxy toggle)"
            ;;
        *) die "proxy env: 未知子命令 $sub" ;;
    esac
}
