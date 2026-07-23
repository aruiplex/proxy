# shellcheck shell=bash
# proxy/lib/service.sh — mihomo lifecycle. Manages the binary directly (nohup +
# controller), independent of how it was installed (brew/gz/github), so behavior
# is identical across machines.

svc_pid() { local bin; bin=$(mihomo_bin 2>/dev/null) || bin='mihomo'; pgrep -f "$(printf '%s' "$bin" | sed 's/[].\\*[]/\\&/g') -d" | head -1; }
# any mihomo process at all (catches foreign/brew-managed instances our -d pattern misses)
svc_any() { pgrep -x mihomo 2>/dev/null | head -1; }

# release a brew-managed mihomo so its supervisor doesn't respawn it under us
_brew_stop() { has brew && brew services stop mihomo >/dev/null 2>&1 || true; }

svc_start() {
    local bin
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制 (运行 proxy install)"
    [[ -f "$CONFIG" ]] || die "未找到 config.yaml: $CONFIG (运行 proxy init)"
    if [[ -n "$(svc_pid)" ]]; then warn "已在运行 (pid $(svc_pid))"; return 0; fi
    # a foreign mihomo (brew services / stray) holding the port would make our
    # start fail on 7890 — stop it first.
    if [[ -n "$(svc_any)" ]]; then
        warn "已有非本工具管理的 mihomo 在跑 (pid $(svc_any); 可能 brew services); 先停掉"
        svc_stop
    fi
    mkdir -p "$CONF_DIR"
    info "启动 mihomo ..."
    nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
    local i
    for i in 1 2 3 4 5; do
        sleep 0.5
        [[ -n "$(svc_pid)" ]] && break
    done
    if [[ -z "$(svc_pid)" ]]; then
        die "启动失败，日志末尾:\n$(tail -5 "$LOG" 2>/dev/null)"
    fi
    if ctrl_get /version >/dev/null 2>&1; then
        ok "已启动 (pid $(svc_pid)), 控制器 http://$(controller_addr) 就绪"
    else
        warn "进程已起 (pid $(svc_pid)) 但控制器无响应，稍候或查 proxy log"
    fi
}

svc_stop() {
    _brew_stop
    local pids
    pids=$( { svc_pid; svc_any; } | sort -u | grep -v '^$' )
    [[ -n "$pids" ]] || { info "未在运行"; return 0; }
    info "停止 mihomo (pid: $(echo $pids | tr '\n' ' ')) ..."
    kill $pids 2>/dev/null
    local i
    for i in $(seq 1 20); do [[ -z "$(svc_any)" ]] && break; sleep 0.2; done
    [[ -n "$(svc_any)" ]] && { warn "未退出，发送 KILL"; pkill -9 -x mihomo 2>/dev/null; }
    ok "已停止"
}

svc_restart() { svc_stop >/dev/null 2>&1; svc_start; }

# Apply the on-disk config: hot-reload via the controller; if the controller is
# unreachable (000), fall back to stop+start so the new config actually takes
# effect. Without this, `sub use`/`refresh`/`merge apply` can report success
# while the running core keeps the OLD config (controller down -> reload fails).
svc_apply() {
    local code; code=$(ctrl_reload "$CONFIG")
    case "$code" in
        204|200) ok "已热重载" ;;
        000)
            warn "控制器无响应, 重启 mihomo 以应用新配置 ..."
            svc_stop >/dev/null 2>&1
            svc_start
            ;;
        *) warn "热重载 HTTP $code; 可 proxy restart" ;;
    esac
}

svc_status() {
    json_guard
    local pid node conns rules ctrl_up
    pid=$(svc_pid)
    if [[ -n "$pid" ]]; then
        ok "运行中 (pid $pid)"
    else
        warn "未运行"
    fi
    # ports
    local ports
    ports=$(ss -ltnp 2>/dev/null | awk '{print $4}' | grep -oE ':[0-9]+$' | tr -d ':' | sort -u | tr '\n' ' ')
    say "  监听端口: ${ports:-<none>}"
    # controller
    if ctrl_up; then
        ctrl_up=1
        say "  控制器:   http://$(controller_addr) ↑"
    else
        ctrl_up=0
        warn "  控制器:   ↓ (9090 未监听; 运行中的 mihomo 用了不带 external-controller 的旧配置)"
        say "           修复: proxy restart"
    fi
    # current exit node + live connections (only meaningful when controller is up)
    if (( ctrl_up )); then
        node=$(node_group 2>/dev/null)
        if [[ -n "$node" ]]; then
            local now
            now=$(ctrl_get "/proxies/$(jq_uri "$node")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
            say "  出口节点: $now  (组: $node)"
        fi
        conns=$(ctrl_get /connections 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(len(d.get('connections') or []))" 2>/dev/null)
        say "  活跃连接: ${conns:-0}"
    fi
}

svc_log() {
    [[ -f "$LOG" ]] || die "无日志: $LOG (mihomo 是否启动过?)"
    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        tail -f "$LOG"
    else
        tail -n "${1:-40}" "$LOG"
    fi
}
