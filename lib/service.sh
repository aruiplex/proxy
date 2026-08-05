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

# When the controller is down, explain WHY by inspecting the running process:
# which -f config it uses, and whether that config has external-controller.
# This turns "9090 ↓, restart it" into a precise diagnosis (foreign config, missing
# field, wrong config file, or port conflict).
_svc_diag() {
    local pid; pid=$(svc_any)
    if [[ -z "$pid" ]]; then
        say "  诊断: 无 mihomo 进程; 运行 proxy start"
        return
    fi
    local args fcfg
    args=$(ps -p "$pid" -o args= 2>/dev/null | sed 's/^ *//')
    say "  运行实例 pid $pid: $args"
    fcfg=$(printf '%s' "$args" | sed -nE 's/.*[[:space:]]-f[[:space:]]+([^[:space:]]+).*/\1/p')
    if [[ -z "$fcfg" ]]; then
        warn "  该实例未指定 -f (用 mihomo 默认配置, 通常无 external-controller) → 9090 起不来"
        say "  修复: proxy restart  (用 $CONFIG 重起, 带控制器)"
        return
    fi
    if [[ "$fcfg" != "$CONFIG" ]]; then
        warn "  该实例用的不是本工具的配置: $fcfg  (本工具: $CONFIG)"
        say "  → 残留/外来实例; proxy restart 会停掉它并用 $CONFIG 重起"
        return
    fi
    if grep -qE '^[[:space:]]*external-controller:' "$fcfg" 2>/dev/null; then
        say "  配置 $fcfg 含 external-controller, 但控制器仍 ↓"
        say "  → 可能 secret 不匹配或 9090 端口被占; 查: ss -ltnp | grep 9090  和  proxy log"
    else
        warn "  配置 $fcfg 无 external-controller 字段 → 这就是 9090 起不来的原因"
        say "  修复: printf '\\nexternal-controller: 127.0.0.1:9090\\n' >> $fcfg; proxy restart"
    fi
}

_fmt_bytes() { # <raw bytes> -> human size
    awk -v b="$1" 'BEGIN{
        if (b >= 1000000000) printf "%.2f GB", b/1e9
        else if (b >= 1000000) printf "%.1f MB", b/1e6
        else if (b >= 1000) printf "%.1f KB", b/1e3
        else printf "%d B", b}'
}

svc_status() {
    json_guard
    local pid up=0 ver etime mport envstate asub tun conns node now
    pid=$(svc_pid)
    if [[ -n "$pid" ]]; then
        etime=$(ps -p "$pid" -o etime= 2>/dev/null | sed 's/^ *//')
        if ctrl_up; then
            up=1
            ver=$(ctrl_get /version 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
            ok "运行中 (pid $pid${ver:+ · $ver}${etime:+ · 已运行 $etime})"
        else
            ok "运行中 (pid $pid${etime:+ · 已运行 $etime})"
        fi
    else
        warn "未运行 — 运行 proxy start 启动"
    fi

    # exit node + live connections/totals (meaningful only when the controller is up)
    if (( up )); then
        node=$(node_group 2>/dev/null)
        if [[ -n "$node" ]]; then
            now=$(ctrl_get "/proxies/$(jq_uri "$node")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
            say "  出口节点:  ${now:-?}   (组: $node)"
        fi
        local conns upb down
        read -r conns upb down < <(ctrl_get /connections 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(len(d.get('connections') or []), d.get('uploadTotal',0), d.get('downloadTotal',0))" 2>/dev/null)
        say "  活跃连接:  ${conns:-0}"
        say "  累计流量:  ↑ $(_fmt_bytes "${upb:-0}") / ↓ $(_fmt_bytes "${down:-0}")"
    fi

    if (( up )); then
        say "  控制器:    http://$(controller_addr) ↑"
    else
        warn "  控制器:    ↓"
        _svc_diag
    fi

    mport=$(awk -F': *' '/^mixed-port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    local mtype=mixed-port
    [[ -z "$mport" ]] && { mport=$(awk -F': *' '/^port:/{print $2;exit}' "$CONFIG" 2>/dev/null); mtype=port; }
    say "  代理端口:  ${mport:-<未设置>} ($mtype)"

    envstate=$(cat "$ENV_STATE" 2>/dev/null)
    if [[ "$envstate" == "on" ]]; then
        ok "  代理环境:  on"
    else
        info "  代理环境:  off"
    fi

    asub=$(conf_get active_sub)
    [[ -n "$asub" ]] && say "  订阅:      $asub"

    tun=$(awk '/^tun:/{f=1} f&&/enable:/{print;exit}' "$CONFIG" 2>/dev/null | grep -o 'true\|false')
    if [[ "$tun" == "true" ]]; then
        ok "  TUN:       开启 (透明代理)"
    else
        info "  TUN:       关闭"
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
