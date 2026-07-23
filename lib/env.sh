# shellcheck shell=bash
# proxy/lib/env.sh — proxy environment-variable injection via a .bashrc hook.
# A child process cannot edit its parent shell's env, so the hook does
# `eval "$(proxy _login 2>/dev/null)"` at shell start: _login prints export/unset
# lines to stdout (applied by the parent) and keeps all diagnostics on stderr.

# the proxy listen address: configured, else parsed from config mixed-port, else 7890
proxy_addr() {
    local a; a=$(conf_get proxy_addr)
    [[ -n "$a" ]] && { printf '%s' "$a"; return; }
    local port
    port=$(awk '/^mixed-port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    port=${port:-7890}
    printf '127.0.0.1:%s' "$port"
}

# print export/unset lines based on the on/off toggle (no side effects, no logging)
_env_exports() {
    local st addr
    st=$(cat "$ENV_STATE" 2>/dev/null)
    addr=$(proxy_addr)
    if [[ "$st" == "on" ]]; then
        printf 'export http_proxy=http://%s\n' "$addr"
        printf 'export https_proxy=http://%s\n' "$addr"
        printf 'export all_proxy=socks5://%s\n' "$addr"
        printf 'export HTTP_PROXY=http://%s\n' "$addr"
        printf 'export HTTPS_PROXY=http://%s\n' "$addr"
        printf 'export ALL_PROXY=socks5://%s\n' "$addr"
        printf 'export no_proxy=localhost,127.0.0.1,::1\n'
    else
        printf 'unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY\n'
    fi
}

# internal: called by the .bashrc hook. Autostarts mihomo if down, then emits env.
# Interactivity is checked by the hook line itself (the parent shell); this always
# emits so `eval "$(proxy _login)"` works regardless of this child's $-.
env_login() {
    local bin
    if bin=$(mihomo_bin 2>/dev/null) && [[ -f "$CONFIG" ]] && ! detect_running; then
        ( nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 & ) 2>/dev/null
    fi
    _env_exports
}

env_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        on)
            mkdir -p "$CONF_DIR"; printf 'on\n' > "$ENV_STATE"
            ok "代理环境变量已开启 (新 shell 自动生效)"
            info "当前 shell 立即生效: eval \"\$(proxy env show)\""
            ;;
        off)
            mkdir -p "$CONF_DIR"; printf 'off\n' > "$ENV_STATE"
            ok "代理环境变量已关闭 (新 shell 自动不注入)"
            info "当前 shell 立即清除: eval \"\$(proxy env show)\""
            ;;
        show) _env_exports ;;
        -h|--help|"") say "用法: proxy env on|off|show  (开关存 $ENV_STATE, 由 .bashrc 钩子在 shell 启动时应用)" ;;
        *) die "proxy env: 未知子命令 $sub" ;;
    esac
}
