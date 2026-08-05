# shellcheck shell=bash
# proxy/lib/ui.sh — mihomo Web dashboard (metacubexd) via external-ui.
#
# The dashboard is served by the mihomo controller itself, so to view it from
# other machines the controller must listen on 0.0.0.0 — which exposes the
# whole control API to the LAN. Default is PASSWORDLESS (LAN-accessible, no
# auth); pass --secret to set a password (value, or auto-generated if empty).
# `proxy ui off` reverts to 127.0.0.1 and drops any secret.
#
#   proxy ui [--secret [VALUE]]   enable: download UI, bind 0.0.0.0 (passwordless
#                                 unless --secret given), restart
#   proxy ui off                  disable: back to 127.0.0.1, remove secret
#   proxy ui status               show current binding / secret / UI state

UI_URL="https://github.com/MetaCubeX/metacubexd/releases/latest/download/compressed-dist.tgz"
UI_DIR="$CONF_DIR/ui"

ui_cmd() {
    local sub=${1:-}
    case "$sub" in
        on)     shift || true; ui_on "$@" ;;
        ""|--secret|-s) ui_on "$@" ;;       # pass flags through verbatim
        off)     shift || true; ui_off "$@" ;;
        status)  ui_status ;;
        -h|--help)
            say "用法: proxy ui [--secret [VALUE]] | off | status"
            say ""
            say "mihomo Web 仪表盘 (metacubexd)。开启后控制器监听 0.0.0.0,"
            say "局域网内任意机器访问 http://<本机IP>:9090/ui/ 即可查看。"
            say "  --secret        设密码: 无值=自动生成随机; 有值=用指定密码"
            say "  (默认无密码; ⚠ 无密码时局域网内任何人都能操控代理)"
            say "  off             撤回: 恢复仅本机监听并移除密码"
            ;;
        *) die "proxy ui: 未知子命令 $sub" ;;
    esac
}

# LAN IPv4, for the URL shown to other machines
ui_lan_ip() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null
    elif has ip; then
        ip -4 addr show scope global 2>/dev/null | awk '/inet /{gsub(/\/.*/,"",$2);print $2}' | head -1
    elif has hostname; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

ui_gen_secret() {
    if has openssl; then openssl rand -hex 16
    else head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# controller port from config, else from proxy.conf, else 9090
ui_controller_port() {
    local c; c=$(awk -F'[ :]' '/^external-controller:/{print $NF;exit}' "$CONFIG" 2>/dev/null)
    [[ -n "$c" ]] && { printf '%s' "$c"; return; }
    c=$(conf_get controller); c=${c#*:}
    printf '%s' "${c:-9090}"
}

# read a top-level scalar from config.yaml (strips quotes)
_ui_cfg() {
    awk -v k="$1" '$0 ~ "^"k":" {sub(/^[^:]*:[[:space:]]*/,""); gsub(/["'\'' ]/,""); print; exit}' "$CONFIG" 2>/dev/null
}

# patch top-level keys in config.yaml (host/secret/external-ui).
# secret or uidir empty = remove that key. Writes in place; caller validates.
ui_patch_config() { # <controller-addr> <secret|-> <ui-dir|->
    local addr=$1 secret=$2 uidir=$3
    python3 - "$CONFIG" "$addr" "$secret" "$uidir" <<'PY'
import sys, re
path, addr, secret, uidir = sys.argv[1:5]
t = open(path).read()
def set_kv(name, val):
    global t
    if val == "-":
        t = re.sub(r'(?m)^%s:.*\n' % name, '', t)
    elif re.search(r'(?m)^%s:' % name, t):
        t = re.sub(r'(?m)^%s:.*$' % name, '%s: %s' % (name, val), t)
    else:
        t = t.rstrip('\n') + '\n%s: %s\n' % (name, val)
set_kv('external-controller', addr)
set_kv('secret', secret)
set_kv('external-ui', uidir)
open(path, 'w').write(t)
PY
}

# download metacubexd if not present; exits 1 on failure
ui_download() {
    [[ -f "$UI_DIR/index.html" ]] && return 0
    info "下载 metacubexd Web UI ..."
    local tmp; tmp=$(mktemp -d)
    curl -fSL --max-time 120 -o "$tmp/ui.tgz" "$UI_URL" 2>/dev/null \
        || { rm -rf "$tmp"; warn "下载失败 (网络/被墙? 可先挂代理再试)"; return 1; }
    tar -xzf "$tmp/ui.tgz" -C "$tmp" 2>/dev/null \
        || { rm -rf "$tmp"; warn "解压失败"; return 1; }
    local src="$tmp"
    [[ -f "$src/index.html" ]] || src="$tmp/dist"
    [[ -f "$src/index.html" ]] || { rm -rf "$tmp"; warn "压缩包内容不完整 (缺 index.html)"; return 1; }
    rm -rf "$UI_DIR"; mv "$src" "$UI_DIR"; rm -rf "$tmp"
    ok "Web UI 已安装: $UI_DIR"
}

# apply a (validated) config edit. NOT svc_apply: external-controller and
# secret are startup-only in mihomo — a hot reload (PUT /configs) reports
# 204 yet leaves the old listener/auth running. Config already passed
# mihomo_test, so stop+start is safe (same model as sub refresh's fallback).
ui_apply() {
    cp -f "$CONFIG" "$BAK"
    mihomo_test "$CONFIG" || { cp -f "$BAK" "$CONFIG"; die "配置校验失败, 已回滚"; }
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_restart
    ctrl_up || warn "重启后控制器仍不可达; 运行 proxy status 诊断"
}

ui_on() {
    # flags: --secret [VALUE] — no flag = passwordless; --secret alone = random
    local secret=
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --secret|-s)
                if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then secret="$2"; shift 2
                else secret=$(ui_gen_secret); shift; fi ;;
            -h|--help) ui_cmd -h; return ;;
            *) die "proxy ui: 未知参数 $1" ;;
        esac
    done

    ui_download || die "Web UI 不可用 (稍后重试 proxy ui)"
    local port; port=$(ui_controller_port)
    if [[ -n "$secret" ]]; then
        info "配置控制器监听 0.0.0.0:$port + secret ..."
        ui_patch_config "0.0.0.0:$port" "$secret" "$UI_DIR"
        conf_set secret "$secret"     # before restart, so readiness check authenticates
    else
        info "配置控制器监听 0.0.0.0:$port (无密码) ..."
        ui_patch_config "0.0.0.0:$port" "-" "$UI_DIR"   # drop any stale secret
        conf_set secret ""
    fi
    ui_apply

    local ip; ip=$(ui_lan_ip)
    ok "Web UI 已开启"
    say "本机访问:   http://127.0.0.1:$port/ui/"
    [[ -n "$ip" ]] && say "局域网访问: http://$ip:$port/ui/   (其他机器浏览器打开)"
    if [[ -n "$secret" ]]; then
        say "secret:     $secret   (仪表盘登录用)"
        warn "控制器已暴露到局域网: 知道 secret 者即可切节点/改配置; 用后 proxy ui off 撤回"
    else
        warn "⚠ 无密码模式: 局域网内任何人都能操控代理 (切节点/改配置); 加 --secret 可设密码"
    fi
    has ufw && info "若被防火墙拦: sudo ufw allow ${port}/tcp"
    if has xdg-open; then xdg-open "http://127.0.0.1:$port/ui/" >/dev/null 2>&1 &
    elif has open; then open "http://127.0.0.1:$port/ui/" >/dev/null 2>&1 &
    fi
}

ui_off() {
    local port; port=$(ui_controller_port)
    info "恢复控制器监听 127.0.0.1:$port, 移除 secret ..."
    ui_patch_config "127.0.0.1:$port" "-" "-"    # keep external-ui: local dashboard still works
    conf_set secret ""                            # clear before restart (new core has no secret)
    ui_apply
    ok "已关闭局域网访问 (Web UI 本机仍可用: http://127.0.0.1:$port/ui/)"
}

ui_status() {
    local ctrl secret uidir
    ctrl=$(_ui_cfg external-controller)
    secret=$(_ui_cfg secret)
    uidir=$(_ui_cfg external-ui)
    say "external-controller: ${ctrl:-未设置}"
    if [[ -n "$ctrl" ]]; then
        local host port; host=${ctrl%%:*}; port=${ctrl##*:}
        if [[ "$host" == "0.0.0.0" ]]; then
            ok "监听 0.0.0.0 → 局域网可访问"
            local ip; ip=$(ui_lan_ip)
            [[ -n "$ip" ]] && say "局域网地址: http://$ip:$port/ui/"
            [[ -z "$secret" ]] && warn "⚠ 无密码: 局域网内任何人都能操控代理 (加 --secret 设密码)"
        else
            info "仅本机监听 ($host) → proxy ui 可开启局域网访问"
        fi
    fi
    [[ -n "$secret" ]] && say "secret: $secret" || say "secret: 未设置"
    if [[ -f "$UI_DIR/index.html" ]]; then
        ok "Web UI 已安装: $UI_DIR"
        [[ -n "$ctrl" ]] && say "本机地址: http://127.0.0.1:${ctrl##*:}/ui/"
    else
        warn "Web UI 未安装 (运行 proxy ui 下载)"
    fi
}
