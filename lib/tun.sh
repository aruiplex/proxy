# shellcheck shell=bash
# proxy/lib/tun.sh — transparent TUN mode. Needs root (cap_net_admin + routing).
# Linux uses an explicitly installed, non-root system service with network
# capabilities. Other platforms retain interactive sudo compatibility.

# shellcheck source=service.sh
source "$SCRIPT_DIR/lib/service.sh"

tun_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        prepare)
            [[ "$(uname -s)" == Linux ]] || die "tun prepare 目前仅支持 Linux/systemd"
            local bin; bin=$(mihomo_bin) || die "未找到 mihomo"
            python3 "$SCRIPT_DIR/libexec/tun_prepare.py" --root "$CONF_DIR" --cli "$SCRIPT_DIR/proxy" --kernel "$bin" "$@"
            ;;
        on)              tun_set on "$@" ;;
        off)             tun_set off "$@" ;;
        --setup-nopasswd) tun_setup_nopasswd "$@" ;;
        -h|--help|"") say "用法: proxy tun on | off | prepare --output DIR（Linux 首次安装需管理员安装监督器）" ;;
        *) die "proxy tun: 未知子命令 $sub" ;;
    esac
}

# replace the tun: block (text-preserving; only the tun mapping is touched) with a
# standard block, enable set to the given value.
tun_write_block() {
    local val=$1 tmp=$CONFIG.tun-tmp
    has python3 || die "tun 需要 python3 (文本编辑配置)"
    python3 - "$CONFIG" "$val" "$tmp" <<'PY'
import sys
src, val, dst = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().splitlines()
out = []
i, n = 0, len(lines)
block = ["tun:", "  enable: %s" % val, "  stack: gvisor", "  dns-hijack:",
         "    - any:53", "  auto-route: true", "  auto-detect-interface: true"]
replaced = False
while i < n:
    L = lines[i]
    if L.startswith('tun:') and (len(L) == 4 or L[4] in ' \t#'):
        i += 1
        while i < n and (not lines[i].strip() or lines[i][0] in ' \t'):
            i += 1
        out.extend(block)
        if i < n and lines[i].strip():
            out.append('')
        out.extend(lines[i:])
        replaced = True
        break
    out.append(L); i += 1
if not replaced:
    if out and out[-1] != '':
        out.append('')
    out.extend(block)
open(dst, 'w').write('\n'.join(out) + '\n')
PY
    [[ -s "$tmp" ]] || { rm -f "$tmp"; die "生成 TUN 配置失败"; }
    mv -f "$tmp" "$CONFIG" || { rm -f "$tmp"; die "替换 TUN 配置失败"; }
}

# stop mihomo whether it runs as the user or as root
tun_stop_any() {
    local pid; pid=$(svc_pid)
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null
    local i; for i in $(seq 1 20); do [[ -z "$(svc_pid)" ]] && return 0; sleep 0.2; done
    if [[ "$(id -u)" -ne 0 ]] && has sudo; then
        sudo kill "$pid" 2>/dev/null || return 1
        for i in $(seq 1 20); do [[ -z "$(svc_pid)" ]] && return 0; sleep 0.2; done
        sudo kill -9 "$pid" 2>/dev/null || return 1
    elif [[ "$(id -u)" -eq 0 ]]; then
        kill -9 "$pid" 2>/dev/null || return 1
    fi
    for i in 1 2 3 4 5; do [[ -z "$(svc_pid)" ]] && return 0; sleep 0.2; done
    return 1
}

_tun_start_privileged() {
    local bin=$1
    if [[ "$(id -u)" -eq 0 ]]; then
        nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
    else
        sudo -v || return 1
        nohup sudo "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
    fi
}

_tun_restore_previous() {
    local bin=$1 was_running=$2 old_tun i
    cp -f "$BAK" "$CONFIG" || return 1
    (( was_running )) || return 0
    old_tun=$(awk '/^tun:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/enable:[[:space:]]*true/{print 1;exit}' "$CONFIG")
    if [[ "$old_tun" == 1 ]]; then
        _tun_start_privileged "$bin" || return 1
        for i in 1 2 3 4 5; do
            sleep 0.5
            [[ -n "$(svc_pid)" ]] && ctrl_up && return 0
        done
        return 1
    else
        ( svc_start ) || return 1
        ctrl_up
    fi
}

_tun_recover_or_warn() {
    if _tun_restore_previous "$1" "$2" >/dev/null 2>&1; then
        warn "已恢复原配置与原运行模式"
        return 0
    fi
    warn "原配置已恢复，但原运行模式恢复失败，mihomo 可能仍处于停止状态"
    return 1
}

tun_set() {
    local mode=$1 bin was_running=0
    if [[ "$(uname -s)" == Linux ]]; then
        tun_linux_set "$mode"
        return
    fi
    require python3
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    [[ -n "$(svc_pid)" ]] && was_running=1
    local sudo_; sudo_=$(detect_sudo)
    if [[ "$mode" == "on" ]]; then
        [[ "$sudo_" == "none" ]] && die "TUN 需要 root, 但本机无 sudo 权限"
        cp -f "$CONFIG" "$BAK" || die "无法备份配置"
        tun_write_block true
        if ! mihomo_test "$CONFIG"; then
            warn "配置校验失败, 已还原"; cp -f "$BAK" "$CONFIG"; return 1
        fi
        info "以 root 启动 mihomo (TUN 需要特权), 可能需要输入密码 ..."
        if ! tun_stop_any >/dev/null 2>&1; then
            cp -f "$BAK" "$CONFIG"
            die "无法停止旧 mihomo，TUN 配置已还原"
        fi
        if ! _tun_start_privileged "$bin"; then
            if _tun_recover_or_warn "$bin" "$was_running"; then
                die "sudo 启动失败，已恢复原运行模式"
            else
                die "sudo 启动失败，且原运行模式恢复失败"
            fi
        fi
        local i
        for i in 1 2 3 4 5; do
            sleep 0.5
            [[ -n "$(svc_pid)" ]] && ctrl_up && break
        done
        if [[ -n "$(svc_pid)" ]] && ctrl_up; then
            ok "TUN 已开启 (root pid $(svc_pid))"
        else
            tun_stop_any >/dev/null 2>&1 || true
            _tun_recover_or_warn "$bin" "$was_running" || true
            die "TUN 启动失败; 查 proxy log"
        fi
    else
        cp -f "$CONFIG" "$BAK" || die "无法备份配置"
        tun_write_block false
        mihomo_test "$CONFIG" || { warn "配置校验失败, 已还原"; cp -f "$BAK" "$CONFIG"; return 1; }
        info "关闭 TUN, 以普通用户重启 mihomo ..."
        if ! tun_stop_any >/dev/null 2>&1; then
            cp -f "$BAK" "$CONFIG"
            die "无法停止 TUN 实例，配置已还原"
        fi
        if ( svc_start ); then
            ok "TUN 已关闭, mihomo 已重启 (pid $(svc_pid))"
        else
            _tun_recover_or_warn "$bin" "$was_running" || true
            die "普通模式启动失败; 查 proxy log"
        fi
    fi
}

# Linux toggles the existing capability-bearing supervised process by reload.
# Initial migration is staged separately; never replace supervision with sudo/nohup.
tun_linux_set() {
    [[ -f "$CONF_DIR/supervisor.json" ]] || die "Linux TUN 需要受监督服务；先运行 proxy tun prepare --output DIR，按使用指南安装并迁移"
    local bin; bin=$(mihomo_bin) || die "未找到 mihomo"
    python3 "$SCRIPT_DIR/libexec/tun_linux.py" --root "$CONF_DIR" --kernel "$bin" "$1"
}

_tun_replay() {
    [[ -f "$CONF_DIR/tun.json" ]] || return 0
    python3 "$SCRIPT_DIR/libexec/tun_config.py" --config "$1" --preferences "$CONF_DIR/tun.json" --in-place
}

tun_setup_nopasswd() {
    if [[ -e /etc/sudoers.d/proxy-mihomo ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            rm -f /etc/sudoers.d/proxy-mihomo || die "旧 sudoers 规则移除失败"
        else
            sudo rm -f /etc/sudoers.d/proxy-mihomo \
                || die "旧 sudoers 规则不安全且移除失败，请手动删除"
        fi
        warn "已移除旧的 proxy-mihomo NOPASSWD 规则"
    fi
    die "--setup-nopasswd 已停用：mihomo 位于用户可写目录时会造成免密 root 执行风险"
}
