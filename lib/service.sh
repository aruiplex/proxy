# shellcheck shell=bash
# proxy/lib/service.sh — mihomo lifecycle. Manages the binary directly (nohup +
# controller), independent of how it was installed (brew/gz/github), so behavior
# is identical across machines.

_svc_pid_matches() {
    local pid=$1 bin uid
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    bin=$(mihomo_bin 2>/dev/null) || return 1
    uid=$(ps -p "$pid" -o uid= 2>/dev/null | tr -d ' ')
    [[ "$uid" == "$(id -u)" || "$uid" == 0 ]] || return 1
    python3 - "$pid" "$bin" "$CONF_DIR" "$CONFIG" <<'PY' >/dev/null 2>&1
import os, shlex, subprocess, sys
pid, binary, confdir, config = sys.argv[1:5]
try:
    raw = open('/proc/%s/cmdline' % pid, 'rb').read()
    argv = [x.decode(errors='replace') for x in raw.split(b'\0') if x]
except Exception:
    try:
        command = subprocess.check_output(
            ['ps', '-ww', '-p', pid, '-o', 'command='], text=True).strip()
        argv = shlex.split(command)
    except Exception:
        raise SystemExit(1)
if not argv:
    raise SystemExit(1)
try:
    exe = os.path.realpath(os.readlink('/proc/%s/exe' % pid))
except Exception:
    exe = os.path.realpath(argv[0])
if exe.endswith(' (deleted)'):
    exe = exe[:-10]
if exe != os.path.realpath(binary):
    raise SystemExit(1)
def exact_arg(flag, value):
    return any(argv[i] == flag and argv[i + 1] == value for i in range(len(argv) - 1))
raise SystemExit(0 if exact_arg('-d', confdir) and exact_arg('-f', config) else 1)
PY
}

_svc_find_pid() {
    local pid
    while IFS= read -r pid; do
        _svc_pid_matches "$pid" && { printf '%s' "$pid"; return 0; }
    done < <(pgrep -x mihomo 2>/dev/null)
    return 1
}

svc_pid() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if _svc_pid_matches "$pid"; then
        printf '%s' "$pid"
        return 0
    fi
    pid=$(_svc_find_pid) || { rm -f "$PID_FILE"; return 1; }
    printf '%s\n' "$pid" > "$PID_FILE"
    printf '%s' "$pid"
}

# Any foreign mihomo process, used only for diagnostics. Never signal it.
svc_any() { pgrep -x mihomo 2>/dev/null | head -1; }

# release a brew-managed mihomo so its supervisor doesn't respawn it under us
_brew_stop() {
    [[ "$(conf_get install_method)" == brew ]] && has brew \
        && brew services stop mihomo >/dev/null 2>&1 || true
}

svc_start() {
    require python3
    local bin
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制 (运行 proxy install)"
    [[ -f "$CONFIG" ]] || die "未找到 config.yaml: $CONFIG (运行 proxy init)"
    if [[ -n "$(svc_pid)" ]]; then warn "已在运行 (pid $(svc_pid))"; return 0; fi
    # Never kill a foreign instance; if it owns our ports, startup will fail
    # with a useful log instead of destroying another user's service.
    if [[ -n "$(svc_any)" ]]; then
        warn "检测到其他 mihomo 实例 (pid $(svc_any)); 不会自动停止它"
    fi
    mkdir -p "$CONF_DIR"
    info "启动 mihomo ..."
    nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
    printf '%s\n' "$!" > "$PID_FILE"
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
        local envstate; envstate=$(cat "$ENV_STATE" 2>/dev/null)
        local tun; tun=$(awk '/^tun:/{f=1} f&&/enable:/{print;exit}' "$CONFIG" 2>/dev/null | grep -o 'true\|false')
        if [[ "$envstate" != "on" && "$tun" != "true" ]]; then
            info "💡 提示: 当前代理环境为 off，可运行 proxy on 开启当前终端代理 (或 proxy tun on 开启透明代理)"
        fi
    else
        warn "进程已起 (pid $(svc_pid)) 但控制器无响应，稍候或查 proxy log"
    fi
}

svc_stop() {
    require python3
    _brew_stop
    local pid
    pid=$(svc_pid)
    [[ -n "$pid" ]] || { info "未在运行"; return 0; }
    info "停止 mihomo (pid: $pid) ..."
    kill "$pid" 2>/dev/null || { warn "无法停止 pid $pid (可能需要 sudo)"; return 1; }
    local i
    for i in $(seq 1 20); do [[ -z "$(svc_pid)" ]] && { rm -f "$PID_FILE"; ok "已停止"; return 0; }; sleep 0.2; done
    warn "未退出，向 pid $pid 发送 KILL"
    kill -9 "$pid" 2>/dev/null || return 1
    sleep 0.2
    if _svc_pid_matches "$pid"; then
        warn "mihomo pid $pid 仍在运行"
        return 1
    fi
    rm -f "$PID_FILE"
    ok "已停止"
}

svc_restart() { svc_stop >/dev/null 2>&1 || return 1; svc_start; }

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
            svc_stop >/dev/null 2>&1 || { warn "无法停止旧 mihomo 实例"; return 1; }
            svc_start
            ;;
        *) warn "热重载 HTTP $code; 可 proxy restart"; return 1 ;;
    esac
}

# When the controller is down, explain WHY by inspecting the running process:
# which -f config it uses, and whether that config has external-controller.
# This turns "9090 ↓, restart it" into a precise diagnosis (foreign config, missing
# field, wrong config file, or port conflict).
_svc_diag() {
    local pid; pid=$(svc_pid)
    [[ -n "$pid" ]] || pid=$(svc_any)
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
    local pid up=0 ver etime mport envstate asub tun conns node now is_pool
    pid=$(svc_pid)
    if [[ -n "$pid" ]]; then
        etime=$(ps -p "$pid" -o etime= 2>/dev/null | sed 's/^ *//')
        if ctrl_up; then
            up=1
            ver=$(ctrl_get /version 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
            ok "● 运行中 (pid $pid${ver:+ · $ver}${etime:+ · 运行 $etime})"
        else
            ok "● 运行中 (pid $pid${etime:+ · 运行 $etime})"
        fi
    else
        warn "○ 未运行 — 运行 proxy start 启动"
    fi

    # exit node (meaningful when the controller is up)
    if (( up )); then
        node=$(node_group 2>/dev/null)
        if [[ -n "$node" ]]; then
            now=$(ctrl_get "/proxies/$(jq_uri "$node")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
            say "  出口节点:  ${now:-?}  ${C_D}(组: $node)${C_N}"
        fi
    fi

    # Pool mode vs Single subscription
    is_pool=$(conf_get pool)
    if [[ "$is_pool" == "on" ]]; then
        local sub_files=("$POOL_STATE_DIR"/*.prox)
        local pool_sub_cnt=0 pool_node_cnt=0
        if [[ -f "${sub_files[0]}" ]]; then
            pool_sub_cnt=${#sub_files[@]}
            pool_node_cnt=$(grep -chE '^[ \t]+- ' "${sub_files[@]}" 2>/dev/null | awk '{s+=$1} END{print s}')
        fi
        ok "  订阅模式:  节点池 (pool on · 聚合 ${pool_sub_cnt} 个订阅 / ${pool_node_cnt:-0} 节点)"
    else
        asub=$(conf_get active_sub)
        say "  订阅模式:  单订阅 (${asub:-default})"
    fi

    envstate=$(cat "$ENV_STATE" 2>/dev/null)
    if [[ "$envstate" == "on" ]]; then
        ok "  代理环境:  on (开启)"
    else
        info "  代理环境:  off (关闭)"
    fi

    tun=$(awk '/^tun:/{f=1} f&&/enable:/{print;exit}' "$CONFIG" 2>/dev/null | grep -o 'true\|false')
    if [[ "$tun" == "true" ]]; then
        ok "  透明 TUN:  开启"
    else
        info "  透明 TUN:  关闭"
    fi

    mport=$(awk -F': *' '/^mixed-port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    local mtype=mixed-port
    [[ -z "$mport" ]] && { mport=$(awk -F': *' '/^port:/{print $2;exit}' "$CONFIG" 2>/dev/null); mtype=port; }
    say "  代理端口:  ${mport:-<未设置>} ($mtype)"

    if (( up )); then
        say "  控制器:    http://$(controller_addr) ↑"
        local conns upb down
        read -r conns upb down < <(ctrl_get /connections 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(len(d.get('connections') or []), d.get('uploadTotal',0), d.get('downloadTotal',0))" 2>/dev/null)
        say "  连接/流量: 活跃连接 ${conns:-0}  |  累计 ↑ $(_fmt_bytes "${upb:-0}") / ↓ $(_fmt_bytes "${down:-0}")"
    else
        warn "  控制器:    ↓"
        _svc_diag
    fi

    local dkr dkr_addr dkr_port
    dkr=$(conf_get docker)
    if [[ "$dkr" == on ]]; then
        dkr_addr=$(conf_get docker_listen)
        dkr_port=$(awk -F': *' '/^mixed-port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
        ok "  Docker:    on → http://${dkr_addr:-172.17.0.1}:${dkr_port:-7890}"
    fi
}

_colorize_log() {
    if [[ -t 1 ]]; then
        awk '
            /\[(ERROR|ERR|FATAL)\]/ { print "\033[1;31m" $0 "\033[0m"; next }
            /\[(WARN|WARNING)\]/     { print "\033[33m" $0 "\033[0m"; next }
            /\[(INFO)\]/            { print "\033[36m" $0 "\033[0m"; next }
            /\[(DEBUG)\]/           { print "\033[2m" $0 "\033[0m"; next }
            { print }
        '
    else
        cat
    fi
}

svc_log() {
    [[ -f "$LOG" ]] || die "无日志: $LOG (mihomo 是否启动过?)"
    if [[ "${1:-}" == "-f" || "${1:-}" == "--follow" ]]; then
        tail -f "$LOG" | _colorize_log
    else
        tail -n "${1:-40}" "$LOG" | _colorize_log
    fi
}
