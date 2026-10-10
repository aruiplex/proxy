# shellcheck shell=bash
# proxy/lib/sub.sh — multi-subscription management.
# Subscriptions are stored as `name<TAB>url` lines in subs.conf (mode 600, since
# URLs carry airport tokens). One is "active"; refresh/use pull, validate,
# replace config.yaml, then re-apply merge so prepend-rules survive.
#
#   proxy sub add <name> <url>     add/update a named subscription
#   proxy sub rm <name>            remove
#   proxy sub list                 list all (active marked, token masked)
#   proxy sub use <name>           switch active + refresh (apply) now; --no-refresh to only set active
#   proxy sub show [name]          print the (masked) URL of a subscription
#   proxy sub refresh [name]       refresh active (or named) subscription
#   proxy sub set <url>            legacy: add as "default", activate + refresh (one-shot)

SUBS_FILE="$CONF_DIR/subs.conf"

# migrate legacy single sub_url (in proxy.conf) -> a "default" subscription
_sub_ensure() {
    if [[ ! -f "$SUBS_FILE" ]]; then
        local u; u=$(conf_get sub_url)
        if [[ -n "$u" ]]; then
            mkdir -p "$CONF_DIR"
            printf 'default\t%s\n' "$u" > "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
            [[ -z "$(conf_get active_sub)" ]] && conf_set active_sub default
        fi
    fi
}

_sub_get_url() { # name -> url
    [[ -f "$SUBS_FILE" ]] || return 0
    awk -F'\t' -v n="$1" '$1==n {print $2; exit}' "$SUBS_FILE"
}
_sub_set() {    # name url  — add or update
    local tmp
    mkdir -p "$CONF_DIR"; touch "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
    tmp=$(mktemp "$CONF_DIR/.subs.conf.tmp.XXXXXX") || die "无法创建订阅临时文件"
    awk -F'\t' -v n="$1" '$1!=n' "$SUBS_FILE" > "$tmp"
    printf '%s\t%s\n' "$1" "$2" >> "$tmp"
    mv -f "$tmp" "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
}
_sub_rm() {     # name
    [[ -f "$SUBS_FILE" ]] || return 0
    local tmp; tmp=$(mktemp "$CONF_DIR/.subs.conf.tmp.XXXXXX") || die "无法创建订阅临时文件"
    awk -F'\t' -v n="$1" '$1!=n' "$SUBS_FILE" > "$tmp"
    mv -f "$tmp" "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
}
_sub_active_name() { local n; n=$(conf_get active_sub); printf '%s' "${n:-default}"; }
_sub_url_for() { # name -> url (subs first, then legacy sub_url)
    local u; u=$(_sub_get_url "$1")
    [[ -n "$u" || "$1" != default ]] || u=$(conf_get sub_url)
    printf '%s' "$u"
}
_sub_validate_url() {
    local url=$1
    [[ "$url" =~ ^https?:// ]] || die "订阅 URL 必须以 http:// 或 https:// 开头"
    [[ "$url" != *$'\t'* && "$url" != *$'\n'* && "$url" != *$'\r'* ]] \
        || die "订阅 URL 不能包含制表符或换行"
}

# Convert a base64 / URI-list subscription into a Clash YAML config (in place).
# GUI clients (Verge/v2rayN) do this internally; the CLI's mihomo -t validation
# requires YAML, so this is the CLI-side equivalent. No-op when the content is
# already YAML. Exits 1 when the content is neither YAML nor a parseable node
# list. Supports ss/trojan/vmess/vless/hysteria2 URIs; airport info pseudo-nodes
# are skipped here (and again by _sub_sanitize for YAML subs).
_sub_convert() { # <file> [controller]
    has python3 || return 0
    python3 - "$1" "${2:-$(controller_addr)}" <<'PY'
import sys, base64, json, re, urllib.parse

path, ctrl = sys.argv[1], sys.argv[2]
raw = open(path, 'rb').read()
t = raw.decode('utf-8', 'replace').strip()

def b64text(value):
    value = urllib.parse.unquote(value).strip()
    value += '=' * (-len(value) % 4)
    return base64.urlsafe_b64decode(value).decode('utf-8', 'replace')

def looks_yaml(s):
    for line in s.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        if line.startswith('---'):
            return True
        if '://' in line:
            return False
        return bool(re.match(r'^[A-Za-z][A-Za-z0-9_-]*\s*:', line))
    return False

if looks_yaml(t):
    sys.exit(0)                      # already a Clash YAML config

if re.match(r'^[A-Za-z0-9]+://', t):
    text = t                          # plain URI list
else:
    try:
        dec = b64text(t)
    except Exception:
        dec = ''
    if dec and ('://' in dec[:4000] or looks_yaml(dec)):
        text = dec
    else:
        text = t
    if looks_yaml(text):
        open(path, 'w').write(text)   # YAML wrapped in base64
        print('已解码: 订阅是 base64 包裹的 YAML')
        sys.exit(0)

INFO = ('剩余流量', '套餐', '到期', '重置', '官网', '客服', '邮箱', '支持AI')
def is_info(name):
    return any(k in name for k in INFO)
def ok_port(p):
    try:
        p['port'] = int(p['port'])
    except Exception:
        return False
    return 1 <= p['port'] <= 65535

nodes = []
for line in text.splitlines():
    l = line.strip()
    if not l or '://' not in l:
        continue
    scheme = l.split('://', 1)[0].lower()
    try:
        u = urllib.parse.urlsplit(l)
        host, port = u.hostname, u.port
    except (ValueError, UnicodeError):
        continue
    name = urllib.parse.unquote(u.fragment).strip() or l.split('#', 1)[-1].strip()
    if not name or is_info(name):
        continue
    q = urllib.parse.parse_qs(u.query)
    p = None
    if scheme == 'hysteria2':
        p = {'name': name, 'type': 'hysteria2', 'server': host,
             'port': port, 'password': urllib.parse.unquote(u.username or '')}
        if q.get('sni'): p['sni'] = q['sni'][0]
        if q.get('insecure', ['0'])[0] == '1': p['skip-cert-verify'] = True
    elif scheme == 'vless':
        security = q.get('security', ['none'])[0].lower()
        p = {'name': name, 'type': 'vless', 'server': host, 'port': port,
             'uuid': urllib.parse.unquote(u.username or '')}
        if security in ('tls', 'reality'): p['tls'] = True
        if q.get('flow'): p['flow'] = q['flow'][0]
        if security == 'reality':
            reality = {}
            if q.get('pbk'): reality['public-key'] = q['pbk'][0]
            if q.get('sid'): reality['short-id'] = q['sid'][0]
            if reality: p['reality-opts'] = reality
        if q.get('sni'): p['servername'] = q['sni'][0]
        if q.get('fp'): p['client-fingerprint'] = q['fp'][0]
        net = q.get('type', ['tcp'])[0]
        p['network'] = net
        pathv = urllib.parse.unquote(q.get('path', [''])[0])
        host = urllib.parse.unquote(q.get('host', [''])[0])
        if net in ('ws', 'xhttp') and (pathv or host):
            opts = {}
            if pathv: opts['path'] = pathv
            if host: opts['headers'] = {'Host': host}
            p['ws-opts' if net == 'ws' else 'xhttp-opts'] = opts
    elif scheme == 'trojan':
        p = {'name': name, 'type': 'trojan', 'server': host, 'port': port,
             'password': urllib.parse.unquote(u.username or '')}
        if q.get('sni'): p['sni'] = q['sni'][0]
        if q.get('fp'): p['client-fingerprint'] = q['fp'][0]
        if q.get('allowInsecure', ['0'])[0] == '1': p['skip-cert-verify'] = True
    elif scheme == 'vmess':
        try:
            data = json.loads(b64text(u.netloc))
        except Exception:
            try:
                data = json.loads(urllib.parse.unquote(u.netloc))
            except Exception:
                continue
        p = {'name': data.get('ps') or name, 'type': 'vmess',
             'server': data.get('add'), 'port': data.get('port'),
             'uuid': data.get('id'), 'alterId': int(data.get('aid') or 0),
             'cipher': data.get('scy') or 'auto'}
        if data.get('tls') in ('tls', True, 1): p['tls'] = True
        if data.get('sni'): p['servername'] = data['sni']
        if data.get('fp'): p['client-fingerprint'] = data['fp']
        net = data.get('net') or 'tcp'
        if net == 'ws':
            p['network'] = 'ws'
            opts = {}
            if data.get('path'): opts['path'] = data['path']
            if data.get('host'): opts['headers'] = {'Host': data['host']}
            if opts: p['ws-opts'] = opts
        elif net == 'grpc':
            p['network'] = 'grpc'
            svc = data.get('path') or data.get('serviceName') or ''
            p['grpc-opts'] = {'grpc-service-name': svc}
    elif scheme == 'ss':
        body = l[5:]
        if '#' in body: body = body.split('#', 1)[0]
        if '?' in body: body = body.split('?', 1)[0]
        if '@' in body:
            userinfo, _, hostport = body.rpartition('@')
            host, _, port = hostport.rpartition(':')
            if ':' not in userinfo:                      # base64(method:password)
                try:
                    dec = b64text(userinfo)
                except Exception:
                    continue
            else:
                dec = userinfo
            method, _, password = dec.partition(':')
            p = {'name': name, 'type': 'ss', 'server': host, 'port': port,
                 'cipher': method, 'password': password}
        else:                                            # legacy: whole thing base64
            try:
                decoded = b64text(body)
            except Exception:
                continue
            m = re.match(r'^([^:]+):([^@]+)@([^:]+):(\d+)$', decoded)
            if m:
                method, password, host, port = m.groups()
                p = {'name': name, 'type': 'ss', 'server': host, 'port': port,
                     'cipher': method, 'password': password}
    if p and ok_port(p) and p.get('server'):
        nodes.append(p)

if not nodes:
    print('无法解析: 内容既不是 Clash YAML 也没有可识别的节点', file=sys.stderr)
    sys.exit(1)

def q(s):
    s = str(s)
    if s == '' or any(c in s for c in ':{}[],&*#?|-<>=!%@`\'"') or s != s.strip():
        return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return s

def emit(p):
    o = ['    - name: %s' % q(p['name']), '      type: %s' % p['type'],
         '      server: %s' % q(p['server']), '      port: %d' % p['port']]
    for k in ('password', 'uuid', 'cipher', 'sni', 'servername', 'flow',
              'client-fingerprint', 'alterId'):
        if k in p:
            o.append('      %s: %s' % (k, q(p[k])))
    if p.get('skip-cert-verify'): o.append('      skip-cert-verify: true')
    if p.get('tls'): o.append('      tls: true')
    if p.get('network'):
        o.append('      network: %s' % p['network'])
        for optk in ('ws-opts', 'xhttp-opts', 'grpc-opts', 'reality-opts'):
            if optk in p:
                o.append('      %s:' % optk)
                for kk, vv in p[optk].items():
                    if isinstance(vv, dict):
                        o.append('        %s:' % kk)
                        for hk, hv in vv.items():
                            o.append('          %s: %s' % (hk, q(hv)))
                    else:
                        o.append('        %s: %s' % (kk, q(vv)))
    return '\n'.join(o)

names = [p['name'] for p in nodes]
member = '\n'.join('        - %s' % q(n) for n in names)
config = ('mixed-port: 7890\n'
          'mode: rule\n'
          'log-level: info\n'
          'external-controller: %s\n'
          'dns:\n'
          '    enable: true\n'
          '    ipv6: false\n'
          '    enhanced-mode: fake-ip\n'
          '    fake-ip-range: 198.18.0.1/16\n'
          '    default-nameserver: [223.5.5.5, 119.29.29.29]\n'
          "    nameserver: ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query', 'https://1.1.1.1/dns-query', 223.5.5.5, 119.29.29.29]\n"
          'proxies:\n%s\n\n'
          'proxy-groups:\n'
          '    - name: 自动选择\n'
          '      type: url-test\n'
          '      url: http://www.gstatic.com/generate_204\n'
          '      interval: 300\n'
          '      tolerance: 50\n'
          '      lazy: true\n'
          '      proxies:\n%s\n'
          '    - name: 故障转移\n'
          '      type: fallback\n'
          '      url: http://www.gstatic.com/generate_204\n'
          '      interval: 300\n'
          '      lazy: true\n'
          '      proxies:\n%s\n'
          '    - name: 节点选择\n'
          '      type: select\n'
          '      proxies:\n'
          '        - 自动选择\n'
          '        - 故障转移\n%s\n'
          'rules:\n'
          "    - 'MATCH,节点选择'\n") % (ctrl,
                                          '\n'.join(emit(p) for p in nodes),
                                          member, member,
                                          '\n'.join('        - %s' % q(n) for n in names))
open(path, 'w').write(config)
print('已转换 %d 个节点 (base64/节点列表 → Clash YAML)' % len(nodes))
PY
}

# Post-download sanitization for the fetched subscription (in place):
#   1. drop airport info pseudo-nodes (客服/官网/剩余流量/套餐/到期/重置/支持AI …).
#      These are fake proxies with non-existent servers that airports sprinkle into
#      groups — if a group auto-selects one (URLTest's initial pick = first member),
#      ALL traffic dies. Removed from definitions AND every group member list.
#   2. normalize external-controller to the CLI's configured address, so the tool
#      always finds the API no matter what port the airport ships.
_sub_sanitize() { # <file> [controller] [lan]
    has python3 || die "订阅清理需要 python3"
    python3 - "$1" "${2:-$(controller_addr)}" "${3:-$(conf_get lan)}" "$CONFIG" <<'PY'
import sys, re
path, ctrl, lan, local_path = sys.argv[1:5]
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)

pat = re.compile(r'剩余流量|套餐|到期|重置|官网|客服|邮箱|支持AI')

# Normalize a YAML scalar enough for matching pseudo-node names. Direct pattern
# matching is also used below, so a stale reference is removed even when its
# definition used a different quoting style.
def node_name(raw):
    raw = raw.strip()
    if raw[:1] in ("'", '"') and raw[-1:] == raw[:1]:
        raw = raw[1:-1]
    return raw.strip()

# 1. collect info-node names from the top-level proxies section only, both flow
#    (`- { name: X, ...`) and block (`- name: X` + props) styles
defs = []
section = None
for ln in lines:
    top = re.match(r'^([A-Za-z][A-Za-z0-9_-]*):', ln)
    if top:
        section = top.group(1)
        continue
    if section != 'proxies':
        continue
    mf = re.match(r'^[ \t]+-\s*\{\s*name:\s*([^,}]+?),', ln)
    mb = re.match(r'^[ \t]+-\s*name:\s*([^,\n]+?)\s*$', ln)
    nm = None
    if mf:
        nm = node_name(mf.group(1))
    elif mb:
        nm = node_name(mb.group(1))
    if nm and pat.search(nm) and nm not in defs:
        defs.append(nm)

# 2. line-based removal: definitions (whole entry), flow-list members,
#    and block-style member lines
out, skip_until = [], -1
section = None
for i, ln in enumerate(lines):
    if i < skip_until:
        continue
    top = re.match(r'^([A-Za-z][A-Za-z0-9_-]*):', ln)
    if top:
        section = top.group(1)
        out.append(ln)
        continue
    # block-style definition entry -> skip name line + following props
    mb = re.match(r'^([ \t]+)-\s*name:\s*(["\']?)(.*?)\2\s*$', ln)
    if section == 'proxies' and mb and (node_name(mb.group(3)) in defs or pat.search(node_name(mb.group(3)))):
        indent = len(mb.group(1))
        j = i + 1
        while j < len(lines):
            l2 = lines[j]
            if not l2.strip():
                j += 1; continue
            if len(l2) - len(l2.lstrip(' ')) <= indent:
                break
            j += 1
        skip_until = j
        continue
    # flow-style definition line
    mf = re.match(r'^[ \t]+-\s*\{\s*name:\s*["\']?(.*?)["\']?\s*,', ln)
    if section == 'proxies' and mf and (node_name(mf.group(1)) in defs or pat.search(node_name(mf.group(1)))):
        continue
    # flow-style member list: proxies: [a, b, c]
    ml = re.match(r'^([ \t]*proxies:[ \t]*)\[(.*)\]([ \t]*\n?)$', ln)
    if section == 'proxy-groups' and ml:
        toks = [x.strip() for x in ml.group(2).split(',') if x.strip()]
        keep = [x for x in toks if node_name(x) not in defs and not pat.search(node_name(x))]
        out.append(ml.group(1) + '[' + ', '.join(keep) + ']' + ml.group(3))
        continue
    # block-style member line: `- <dropped name>`
    mm = re.match(r'^([ \t]+)-[ \t]+(.+?)[ \t]*$', ln)
    if section == 'proxy-groups' and mm and 'name:' not in ln \
       and (node_name(mm.group(2)) in defs or pat.search(node_name(mm.group(2)))):
        continue
    out.append(ln)

t = ''.join(out)

# Persist machine-local controller/UI/LAN settings across subscription refreshes.
def set_kv(name, val):
    global t
    if val is None:
        t = re.sub(r'(?m)^%s:.*\n?' % re.escape(name), '', t)
    elif re.search(r'(?m)^%s:' % re.escape(name), t):
        t = re.sub(r'(?m)^%s:.*$' % name, '%s: %s' % (name, val), t)
    else:
        t = t.rstrip('\n') + '\n%s: %s\n' % (name, val)

local = open(local_path, encoding='utf-8').read() if local_path and __import__('os').path.exists(local_path) else ''
def scalar(text, name):
    m = re.search(r'(?m)^%s:\s*(.*?)\s*$' % re.escape(name), text)
    return m.group(1) if m else None

set_kv('external-controller', scalar(local, 'external-controller') or ctrl)
set_kv('secret', scalar(local, 'secret'))
set_kv('external-ui', scalar(local, 'external-ui'))

if lan == 'on':
    set_kv('allow-lan', 'true')
    set_kv('bind-address', "'*'")
elif lan == 'off':
    set_kv('allow-lan', 'false')
    set_kv('bind-address', "'127.0.0.1'")

# Replace the downloaded tun mapping with the machine-local mapping. If the
# local config has no tun block, remove a subscription-provided one so a remote
# provider cannot silently enable privileged mode.
def split_mapping(text, name):
    ls = text.splitlines(keepends=True)
    start = end = None
    for i, line in enumerate(ls):
        if re.match(r'^%s:(?:\s|$)' % re.escape(name), line):
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

t, _ = split_mapping(t, 'tun')
_, local_tun = split_mapping(local, 'tun')
if local_tun:
    t = t.rstrip('\n') + '\n' + local_tun

open(path, 'w').write(t)
PY
    local docker_st docker_addr docker_port
    docker_st=$(conf_get docker)
    if [[ "$docker_st" == on || "$docker_st" == off ]]; then
        # shellcheck source=docker.sh
        source "$SCRIPT_DIR/lib/docker.sh"
        docker_addr=$(conf_get docker_listen)
        [[ -n "$docker_addr" ]] || docker_addr=$(_docker_gateway)
        docker_port=$(_docker_port)
        _docker_patch_yaml "$1" "$docker_st" "$docker_addr" "$docker_port" \
            || die "订阅清理后写入 docker 监听失败"
    fi
}

# mask the token segment of a subscription URL for safe display
_sub_mask() {
    has python3 || { printf '%s' "$1"; return; }
    printf '%s' "$1" | python3 -c "
import sys, re
u = sys.stdin.read().strip()
u = re.sub(r'/[^/?#]+(?=[?#]|$)', '/****', u)   # last path segment
u = re.sub(r'\?[^#]*', '?****', u)               # query string
print(u)
"
}

_sub_pick() { # [prompt]
    local prompt=${1:-"选择订阅"}
    local names=() n
    while IFS=$'\t' read -r n _; do
        [[ -n "$n" ]] && names+=("$n")
    done < "$SUBS_FILE"
    (( ${#names[@]} > 0 )) || { info "无可用订阅"; return 1; }
    if has fzf; then
        printf '%s\n' "${names[@]}" | fzf --prompt="$prompt> " --height=40% --reverse --info=inline 2>/dev/null
    else
        local i
        for i in "${!names[@]}"; do printf '%2d) %s\n' "$((i+1))" "${names[$i]}" >&2; done
        local choice
        printf '%s [#] (q 取消): ' "$prompt" >&2
        read -r choice </dev/tty 2>/dev/null || return 1
        [[ "$choice" == q || "$choice" == Q || -z "$choice" ]] && return 1
        [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#names[@]} )) || return 1
        printf '%s' "${names[$((choice-1))]}"
    fi
}

sub_cmd() {
    _sub_ensure
    local sub=${1:-}; shift || true
    case "$sub" in
        add)     sub_add "$@" ;;
        rm)      sub_rm "$@" ;;
        list|ls) sub_list "$@" ;;
        use)     sub_use "$@" ;;
        show)    sub_show "$@" ;;
        refresh) sub_refresh "$@" ;;
        set)     sub_set "$@" ;;     # legacy
        "")      if [[ -t 0 ]]; then sub_list; else say "用法: proxy sub add <name> <url> | rm [name] | list | use [name] [--no-refresh] | show [name] | refresh [name] | set <url>"; fi ;;
        -h|--help) say "用法: proxy sub add <name> <url> | rm [name] | list | use [name] [--no-refresh] | show [name] | refresh [name] | set <url>" ;;
        *) die "proxy sub: 未知子命令 $sub" ;;
    esac
}

sub_add() {
    local name=$1 url=$2
    [[ -n "$name" && -n "$url" ]] || die "用法: proxy sub add <name> <url>  (name: 字母数字_-)"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "订阅名只能含字母数字_-"
    _sub_validate_url "$url"
    _sub_set "$name" "$url"
    ok "订阅 '$name' 已保存 ($(printf '%s' "$url" | awk -F/ '{print $3}'))"
    [[ -z "$(conf_get active_sub)" ]] && { conf_set active_sub "$name"; info "已设为活跃订阅"; }
}

sub_rm() {
    local name=$1
    if [[ -z "$name" ]]; then
        name=$(_sub_pick "选择要删除的订阅") || { info "取消"; return 0; }
    fi
    [[ -n "$name" ]] || die "用法: proxy sub rm [name]"
    [[ -n "$(_sub_get_url "$name")" ]] || die "无此订阅: $name"
    _sub_rm "$name"
    if [[ "$(conf_get active_sub)" == "$name" ]]; then
        local first; first=$(awk -F'\t' 'NR==1{print $1;exit}' "$SUBS_FILE" 2>/dev/null)
        conf_set active_sub "${first:-}"
        [[ -n "$first" ]] && info "活跃订阅切到 '$first'" || info "已无活跃订阅"
    fi
    ok "订阅 '$name' 已移除"
}

sub_list() {
    [[ -f "$SUBS_FILE" ]] || { info "无订阅 (先: proxy sub add <name> <url>)"; return 0; }
    local active; active=$(_sub_active_name)
    say "${C_B}subscriptions ($SUBS_FILE):${C_N}"
    while IFS=$'\t' read -r name url; do
        [[ -n "$name" ]] || continue
        local mark="  "; [[ "$name" == "$active" ]] && mark="${C_G}* ${C_N}"
        printf '%s%-16s %s\n' "$mark" "$name" "$(_sub_mask "$url")"
    done < "$SUBS_FILE"
}

sub_show() {
    local name=${1:-$(_sub_active_name)}
    local url; url=$(_sub_url_for "$name")
    [[ -n "$url" ]] || die "订阅 '$name' 无 URL"
    say "$name: $url"
}

sub_use() {
    local name=$1 norefresh=0
    if [[ "$(conf_get pool)" == "on" ]]; then
        warn "节点池模式已开启: 用 proxy pool refresh 刷新所有订阅 / proxy pool off 退回单订阅"
        return 1
    fi
    if [[ "$1" == "--no-refresh" ]]; then
        norefresh=1
        name=""
    fi
    [[ "${2:-}" == "--no-refresh" ]] && norefresh=1
    if [[ -z "$name" ]]; then
        name=$(_sub_pick "选择切换的订阅") || { info "取消"; return 0; }
    fi
    [[ -n "$(_sub_get_url "$name")" ]] || die "无此订阅: $name (先 proxy sub add)"
    if (( norefresh )); then
        conf_set active_sub "$name"
        ok "活跃订阅: $name"
        info "未刷新 (--no-refresh); 应用它: proxy sub refresh"
    else
        info "切换并拉取应用 ..."
        sub_refresh "$name" || return 1
        conf_set active_sub "$name"
        ok "活跃订阅: $name"
    fi
}

sub_set() {   # legacy one-shot
    local url=$1
    [[ -n "$url" ]] || die "用法: proxy sub set <url>  (或用 proxy sub add <name> <url>)"
    _sub_validate_url "$url"
    _sub_set default "$url"
    ok "订阅 'default' 已保存, 正在拉取 ..."
    sub_refresh default || return 1
    conf_set active_sub default
    ok "订阅 'default' 已设为活跃"
}

sub_refresh() { (
    local name=${1:-$(_sub_active_name)}
    if [[ "$(conf_get pool)" == "on" ]]; then
        warn "节点池模式已开启: 用 proxy pool refresh 刷新所有订阅 / proxy pool off 退回单订阅"
        return 1
    fi
    local url; url=$(_sub_url_for "$name")
    [[ -n "$url" ]] || die "订阅 '$name' 未配置 URL (先: proxy sub add <name> <url>)"
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"

    local bin ua
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    ua=$(conf_get sub_ua)
    [[ -n "$ua" ]] || ua="mihomo/$("$bin" -v 2>/dev/null | awk '{print $3;exit}')"

    local new
    new=$(mktemp "$CONF_DIR/.config.new.XXXXXX") || die "无法创建订阅临时文件"
    trap 'rm -f "$new"' EXIT
    info "拉取订阅 '$name' (UA: $ua) ..."
    if ! curl_download_private "$url" "$new" "$ua" 2>/dev/null; then
        die "拉取失败 (URL/UA/网络?), 配置未改动"
    fi
    local conv
    if conv=$(_sub_convert "$new"); then
        [[ -n "$conv" ]] && info "$conv"
    else
        die "订阅内容无法解析 (既不是 Clash YAML 也不是节点列表); 配置未改动"
    fi
    _sub_sanitize "$new"
    source "$SCRIPT_DIR/lib/auto.sh"
    _adaptive_replay "$new" || return 1
    if ! mihomo_test "$new"; then
        warn "新订阅校验失败, 未替换; 末尾:"
        "$bin" -t -d "$CONF_DIR" -f "$new" 2>&1 | tail -3 >&2
        return 1
    fi
    cp -f "$CONFIG" "$BAK" || die "无法备份当前配置，订阅未替换"
    mv -f "$new" "$CONFIG" || die "无法替换 config.yaml"
    ok "订阅 '$name' 已更新, 备份 → $BAK"

    # re-apply merge so prepend-rules survive the subscription refresh
    if [[ -f "$MERGE_FILE" ]]; then
        # shellcheck source=merge.sh
        source "$SCRIPT_DIR/lib/merge.sh"
        if _merge_rules >/dev/null 2>&1; then
            info "重新应用 merge 规则 ..."
            ( PRESERVE_BAK=1 DEFER_APPLY=1 merge_apply ) \
                || { cp -f "$BAK" "$CONFIG"; warn "merge 应用失败，订阅更新已回滚"; return 1; }
        fi
    fi

    # re-apply region groups so they (and the ban list) survive the refresh
    if [[ -f "$CONF_DIR/regions.conf" ]]; then
        # shellcheck source=region.sh
        source "$SCRIPT_DIR/lib/region.sh"
        if [[ -n "$(_region_names)" ]]; then
            info "重新应用 region 组 ..."
            ( PRESERVE_BAK=1 DEFER_APPLY=1 region_apply ) \
                || { cp -f "$BAK" "$CONFIG"; warn "region 应用失败，订阅更新已回滚"; return 1; }
        fi
    fi

    # apply the on-disk config: hot-reload, or restart if controller is down
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    if ! ( svc_apply ); then
        cp -f "$BAK" "$CONFIG"
        warn "新订阅无法应用，磁盘配置已回滚"
        ( svc_apply ) >/dev/null 2>&1 || true
        return 1
    fi
); }
