# shellcheck shell=bash
# proxy/lib/docker.sh — route docker pull / build / container egress via mixed-port.
#
# Two layers:
#   1. mihomo listens on the docker0 gateway (default 172.17.0.1:7890) so every
#      docker network can reach the proxy as a host-local address.
#   2. ~/.docker/config.json injects HTTP(S)_PROXY into new containers and
#      docker build. docker pull is a dockerd-side fetch; without write access
#      to daemon.json this client config is still what BuildKit / compose use.
#
# Persisted in proxy.conf (`docker`, `docker_listen`) and re-applied by
# _sub_sanitize on subscription refresh — same pattern as `proxy lan`.
#
#   proxy docker on | off | status

DOCKER_CLIENT_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"
DOCKER_LISTENER_NAME=mixed-docker
DOCKER_NOPROXY='localhost,127.0.0.1,::1,.local,docker,containerd,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.169.254,22.0.0.0/8'

docker_cmd() {
    local sub=${1:-}
    case "$sub" in
        on)    docker_set on ;;
        off)   docker_set off ;;
        status|show) docker_status ;;
        -h|--help|"")
            say "用法: proxy docker on | off | status"
            say ""
            say "让 docker pull/build 与容器出网走 mixed-port 代理。"
            say "mihomo 在 docker0 网关 (通常 172.17.0.1:7890) 加 mixed 监听;"
            say "~/.docker/config.json 注入 HTTP(S)_PROXY。设置持久化, 订阅刷新后保留。"
            ;;
        *) die "proxy docker: 未知子命令 $sub" ;;
    esac
}

_docker_port() {
    local p
    p=$(awk -F': *' '/^mixed-port:/{print $2;exit}' "$CONFIG" 2>/dev/null)
    [[ "$p" =~ ^[1-9][0-9]*$ ]] && (( p <= 65535 )) || p=7890
    printf '%s' "$p"
}

# docker0 gateway: docker inspect, then ip addr, then the engine default.
_docker_gateway() {
    local gw
    if has docker; then
        gw=$(docker network inspect bridge \
            --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null | head -1)
        [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$gw"; return 0; }
    fi
    if has ip; then
        gw=$(ip -4 addr show docker0 2>/dev/null | awk '/inet /{split($2,a,"/"); print a[1]; exit}')
        [[ "$gw" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$gw"; return 0; }
    fi
    printf '172.17.0.1'
}

_docker_url() { # [addr]
    printf 'http://%s:%s' "${1:-$(_docker_gateway)}" "$(_docker_port)"
}

# Insert or drop the mixed-docker listener in a mihomo YAML file.
_docker_patch_yaml() { # <file> <on|off> <listen-addr> <port>
    python3 - "$1" "$2" "$3" "$4" "$DOCKER_LISTENER_NAME" <<'PY'
import re, sys
path, mode, addr, port, name = sys.argv[1:6]
text = open(path, encoding='utf-8').read()
item = (
    '  - name: %s\n'
    '    type: mixed\n'
    '    port: %s\n'
    '    listen: %s\n'
    '    udp: true\n'
) % (name, port, addr)

def split_mapping(src, key):
    ls = src.splitlines(keepends=True)
    start = end = None
    for i, line in enumerate(ls):
        if re.match(r'^%s:(?:\s|$)' % re.escape(key), line):
            start = i
            end = i + 1
            while end < len(ls):
                cur = ls[end]
                if cur.strip() and not cur[0].isspace():
                    break
                end += 1
            break
    block = ''.join(ls[start:end]) if start is not None else None
    if start is not None:
        del ls[start:end]
    return ''.join(ls), block

def remove_named_item(block):
    if not block:
        return None
    lines = block.splitlines(keepends=True)
    header, rest = lines[0], lines[1:]
    out, i, n = [], 0, len(rest)
    while i < n:
        line = rest[i]
        m = re.match(r'^([ \t]+)-\s', line)
        if not m:
            out.append(line)
            i += 1
            continue
        indent = m.group(1)
        j = i + 1
        while j < n:
            nxt = rest[j]
            if re.match(r'^%s-\s' % re.escape(indent), nxt):
                break
            if nxt.strip() and not nxt[0].isspace():
                break
            j += 1
        chunk = ''.join(rest[i:j])
        if not re.search(r'(?m)^\s*(?:-\s+)?name:\s*["\']?%s["\']?\s*$' % re.escape(name), chunk):
            out.append(chunk)
        i = j
    body = ''.join(out)
    if not re.search(r'(?m)^[ \t]+-\s', body):
        return None
    return header + body

text, block = split_mapping(text, 'listeners')
if mode == 'on':
    if block:
        block = remove_named_item(block) or 'listeners:\n'
        lines = block.splitlines(keepends=True)
        block = lines[0] + item + ''.join(lines[1:])
    else:
        block = 'listeners:\n' + item
    text = text.rstrip('\n') + '\n' + block
    if not text.endswith('\n'):
        text += '\n'
else:
    block = remove_named_item(block)
    if block:
        text = text.rstrip('\n') + '\n' + block
        if not text.endswith('\n'):
            text += '\n'

open(path, 'w').write(text)
PY
}

_docker_write_client() { # <proxy-url|off>
    local url=$1 dir tmp
    dir=$(dirname "$DOCKER_CLIENT_CONFIG")
    mkdir -p "$dir" || die "无法创建 $dir"
    tmp=$(mktemp "$dir/.config.json.tmp.XXXXXX") || die "无法创建 docker 配置临时文件"
    if ! python3 - "$DOCKER_CLIENT_CONFIG" "$tmp" "$url" "$DOCKER_NOPROXY" <<'PY'
import json, os, sys
src, dst, url, noproxy = sys.argv[1:5]
data = {}
if os.path.isfile(src):
    try:
        with open(src, encoding='utf-8') as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (json.JSONDecodeError, OSError):
        data = {}
proxies = data.get('proxies')
if not isinstance(proxies, dict):
    proxies = {}
if url == 'off':
    proxies.pop('default', None)
    if proxies:
        data['proxies'] = proxies
    else:
        data.pop('proxies', None)
else:
    proxies['default'] = {
        'httpProxy': url,
        'httpsProxy': url,
        'ftpProxy': url,
        'noProxy': noproxy,
    }
    data['proxies'] = proxies
with open(dst, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PY
    then
        rm -f "$tmp"
        die "写入 $DOCKER_CLIENT_CONFIG 失败"
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$DOCKER_CLIENT_CONFIG" || { rm -f "$tmp"; die "替换 $DOCKER_CLIENT_CONFIG 失败"; }
    chmod 600 "$DOCKER_CLIENT_CONFIG" 2>/dev/null || true
}

_docker_listening() { # <addr> <port>
    ss -ltn 2>/dev/null | grep -Fq "$1:$2"
}

docker_set() {
    local v=$1 addr port url tmp
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    has python3 || die "proxy docker 需要 python3"
    addr=$(_docker_gateway)
    port=$(_docker_port)
    tmp="$CONFIG.docker-tmp"
    cp -f "$CONFIG" "$tmp" || die "无法创建 docker 配置临时文件"
    if [[ "$v" == on ]]; then
        _docker_patch_yaml "$tmp" on "$addr" "$port" || { rm -f "$tmp"; die "生成 docker 监听配置失败"; }
    else
        _docker_patch_yaml "$tmp" off "$addr" "$port" || { rm -f "$tmp"; die "移除 docker 监听配置失败"; }
    fi
    if ! mihomo_test "$tmp"; then
        rm -f "$tmp"
        die "docker 配置校验失败, 原配置未改动"
    fi
    cp -f "$CONFIG" "$BAK" || { rm -f "$tmp"; die "无法备份配置"; }
    mv -f "$tmp" "$CONFIG" || { rm -f "$tmp"; die "无法替换配置"; }

    if [[ "$v" == on ]]; then
        url=$(_docker_url "$addr")
        _docker_write_client "$url"
        conf_set docker on
        conf_set docker_listen "$addr"
    else
        _docker_write_client off
        conf_set docker off
        conf_set docker_listen ""
    fi

    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply || { warn "配置已保存，但未能应用到运行中的 mihomo"; return 1; }
    if [[ "$v" == on ]] && ! _docker_listening "$addr" "$port"; then
        info "热重载未绑定 $addr:$port, 重启 mihomo ..."
        svc_restart || { warn "重启失败; 查 proxy log"; return 1; }
    fi

    if [[ "$v" == on ]]; then
        if _docker_listening "$addr" "$port"; then
            ok "docker 代理: on — 容器/build: $url"
        else
            warn "docker 代理已写入配置, 但 $addr:$port 未在听; 查 proxy log"
        fi
        info "新容器会注入 HTTP_PROXY/HTTPS_PROXY; 已在跑的容器需重建才生效"
        if [[ "$(id -u)" -ne 0 ]] && [[ ! -w /etc/docker/daemon.json ]]; then
            info "docker pull 由 dockerd 发起: 本环境无权限写 /etc/docker/daemon.json, 守护进程代理保持原样"
        fi
    else
        ok "docker 代理: off — 已撤 docker0 监听与 ~/.docker/config.json proxies"
    fi
}

docker_status() {
    local persist listen port url http https bind
    persist=$(conf_get docker)
    listen=$(conf_get docker_listen)
    port=$(_docker_port)
    [[ -z "$listen" ]] && listen=$(_docker_gateway)
    url=$(_docker_url "$listen")
    say "持久化:     ${persist:-未设置} (订阅刷新${persist:+后 }$([[ "$persist" == on ]] && echo 自动保留 || echo 按订阅自带值))"
    if grep -qE "^[[:space:]]*-[[:space:]]*name:[[:space:]]*${DOCKER_LISTENER_NAME}[[:space:]]*$" "$CONFIG" 2>/dev/null; then
        bind=$(awk -v n="$DOCKER_LISTENER_NAME" '
            $0 ~ "^[[:space:]]*-[[:space:]]*name:[[:space:]]*"n {f=1; next}
            f && $0 ~ "^[[:space:]]*-[[:space:]]*name:" {exit}
            f && /listen:/ {sub(/^[^:]*:[[:space:]]*/,""); print; exit}
        ' "$CONFIG")
        say "mihomo:     listeners.$DOCKER_LISTENER_NAME  listen ${bind:-?} port $port"
    else
        info "mihomo:     无 $DOCKER_LISTENER_NAME 监听"
    fi
    if _docker_listening "$listen" "$port"; then
        ok "监听:       $listen:$port"
    else
        info "监听:       $listen:$port 未在听"
    fi
    if [[ -f "$DOCKER_CLIENT_CONFIG" ]]; then
        http=$(python3 - "$DOCKER_CLIENT_CONFIG" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    p=(d.get('proxies') or {}).get('default') or {}
    print(p.get('httpProxy') or '')
except Exception:
    print('')
PY
)
        https=$(python3 - "$DOCKER_CLIENT_CONFIG" <<'PY'
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    p=(d.get('proxies') or {}).get('default') or {}
    print(p.get('httpsProxy') or '')
except Exception:
    print('')
PY
)
        say "client:     $DOCKER_CLIENT_CONFIG"
        say "  httpProxy:  ${http:-<未设置>}"
        say "  httpsProxy: ${https:-<未设置>}"
    else
        info "client:     无 $DOCKER_CLIENT_CONFIG"
    fi
    local dproxy
    dproxy=$(docker info -f '{{.HttpProxy}}' 2>/dev/null || true)
    if [[ -n "$dproxy" ]]; then
        say "dockerd:    HTTP_PROXY=$dproxy"
    else
        info "dockerd:    未配置守护进程代理 (docker pull 不走 7890, 除非镜像层走 BuildKit/client)"
    fi
    [[ "$persist" == on ]] && say "容器代理:   $url"
}
