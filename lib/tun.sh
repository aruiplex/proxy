# shellcheck shell=bash
# proxy/lib/tun.sh — transparent TUN mode. Needs root (cap_net_admin + routing).
# `proxy tun on/off` uses interactive sudo by default; `--setup-nopasswd` writes a
# single-command NOPASSWD sudoers fragment so the toggle can run unattended.

tun_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        on)              tun_set on "$@" ;;
        off)             tun_set off "$@" ;;
        --setup-nopasswd) tun_setup_nopasswd "$@" ;;
        -h|--help|"") say "用法: proxy tun on | off | --setup-nopasswd" ;;
        *) die "proxy tun: 未知子命令 $sub" ;;
    esac
}

# replace the tun: block (text-preserving; only the tun mapping is touched) with a
# standard block, enable set to the given value. gvisor stack needs no kernel tun dev.
tun_write_block() {
    local val=$1 tmp=$CONFIG.tun-tmp
    has python3 || die "tun 需要 python3 (文本编辑配置)"
    python3 - "$CONFIG" "$val" "$tmp" <<'PY'
import sys
src, val, dst = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(src).read().split('\n')
out = []
i, n = 0, len(lines)
while i < n:
    L = lines[i]
    if L.startswith('tun:') and (len(L) == 4 or L[4] in ' \t#'):
        i += 1
        while i < n and (lines[i] == '' or lines[i][0] in ' \t' or lines[i].startswith('#')):
            i += 1
        break
    out.append(L); i += 1
block = ("tun:\n  enable: %s\n  stack: gvisor\n  dns-hijack:\n    - any:53\n"
         "  auto-route: true\n  auto-detect-interface: true") % val
if out and out[-1] != '':
    out.append('')
out.append(block)
open(dst, 'w').write('\n'.join(out) + '\n')
PY
    mv -f "$tmp" "$CONFIG"
}

# stop mihomo whether it runs as the user or as root
tun_stop_any() {
    local pid; pid=$(svc_pid)
    [[ -n "$pid" ]] || return 0
    kill "$pid" 2>/dev/null
    local i; for i in $(seq 1 20); do [[ -z "$(svc_pid)" ]] && return 0; sleep 0.2; done
    if [[ "$(id -u)" -ne 0 ]] && has sudo; then
        sudo kill "$pid" 2>/dev/null
        for i in $(seq 1 20); do [[ -z "$(svc_pid)" ]] && return 0; sleep 0.2; done
        sudo kill -9 "$pid" 2>/dev/null
    fi
}

tun_set() {
    local mode=$1 bin
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    local sudo_=$(detect_sudo)
    if [[ "$mode" == "on" ]]; then
        [[ "$sudo_" == "none" ]] && die "TUN 需要 root, 但本机无 sudo 权限"
        cp -f "$CONFIG" "$BAK"
        tun_write_block true
        if ! mihomo_test "$CONFIG"; then
            warn "配置校验失败, 已还原"; cp -f "$BAK" "$CONFIG"; return 1
        fi
        info "以 root 启动 mihomo (TUN 需要特权), 可能需要输入密码 ..."
        tun_stop_any >/dev/null 2>&1
        sudo nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
        sleep 1
        if [[ -n "$(svc_pid)" ]]; then ok "TUN 已开启 (root pid $(svc_pid))"; else die "启动失败, 查 proxy log"; fi
    else
        cp -f "$CONFIG" "$BAK"
        tun_write_block false
        mihomo_test "$CONFIG" || { warn "配置校验失败, 已还原"; cp -f "$BAK" "$CONFIG"; return 1; }
        info "关闭 TUN, 以普通用户重启 mihomo ..."
        tun_stop_any >/dev/null 2>&1
        nohup "$bin" -d "$CONF_DIR" -f "$CONFIG" >> "$LOG" 2>&1 &
        sleep 1
        if [[ -n "$(svc_pid)" ]]; then ok "TUN 已关闭, mihomo 已重启 (pid $(svc_pid))"; else die "启动失败, 查 proxy log"; fi
    fi
}

# write a sudoers fragment allowing the current user to run ONLY this exact mihomo
# start command without a password; verified with visudo before it takes effect.
tun_setup_nopasswd() {
    local bin user cmd frag
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    [[ "$(detect_sudo)" == "none" ]] && die "本机无 sudo, 无法配置"
    user=$(id -un)
    cmd="$bin -d $CONF_DIR -f $CONFIG"
    frag="$user ALL=(root) NOPASSWD: $cmd"
    info "写入 /etc/sudoers.d/proxy-mihomo (仅允许: $cmd)"
    if ! echo "$frag" | sudo tee /etc/sudoers.d/proxy-mihomo >/dev/null 2>&1; then
        die "写入失败 (需要密码或权限)"
    fi
    sudo chmod 440 /etc/sudoers.d/proxy-mihomo
    if sudo visudo -c -f /etc/sudoers.d/proxy-mihomo >/dev/null 2>&1; then
        ok "已配置 NOPASSWD; 之后 proxy tun on/off 不再需要密码"
    else
        sudo rm -f /etc/sudoers.d/proxy-mihomo
        die "sudoers 校验失败, 已移除片段, 未生效"
    fi
}
