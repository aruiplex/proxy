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
    mkdir -p "$CONF_DIR"; touch "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
    awk -F'\t' -v n="$1" '$1!=n' "$SUBS_FILE" > "$SUBS_FILE.tmp"
    printf '%s\t%s\n' "$1" "$2" >> "$SUBS_FILE.tmp"
    mv -f "$SUBS_FILE.tmp" "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
}
_sub_rm() {     # name
    [[ -f "$SUBS_FILE" ]] || return 0
    awk -F'\t' -v n="$1" '$1!=n' "$SUBS_FILE" > "$SUBS_FILE.tmp"
    mv -f "$SUBS_FILE.tmp" "$SUBS_FILE"; chmod 600 "$SUBS_FILE"
}
_sub_active_name() { local n; n=$(conf_get active_sub); printf '%s' "${n:-default}"; }
_sub_url_for() { # name -> url (subs first, then legacy sub_url)
    local u; u=$(_sub_get_url "$1"); [[ -n "$u" ]] || u=$(conf_get sub_url); printf '%s' "$u"
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
        dec = base64.b64decode(t).decode('utf-8', 'replace')
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
    u = urllib.parse.urlsplit(l)
    name = urllib.parse.unquote(u.fragment).strip() or l.split('#', 1)[-1].strip()
    if not name or is_info(name):
        continue
    q = urllib.parse.parse_qs(u.query)
    p = None
    if scheme == 'hysteria2':
        p = {'name': name, 'type': 'hysteria2', 'server': u.hostname,
             'port': u.port, 'password': urllib.parse.unquote(u.username or '')}
        if q.get('sni'): p['sni'] = q['sni'][0]
        if q.get('insecure', ['0'])[0] == '1': p['skip-cert-verify'] = True
    elif scheme == 'vless':
        p = {'name': name, 'type': 'vless', 'server': u.hostname, 'port': u.port,
             'uuid': urllib.parse.unquote(u.username or ''), 'tls': True}
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
        p = {'name': name, 'type': 'trojan', 'server': u.hostname, 'port': u.port,
             'password': urllib.parse.unquote(u.username or '')}
        if q.get('sni'): p['sni'] = q['sni'][0]
        if q.get('fp'): p['client-fingerprint'] = q['fp'][0]
        if q.get('allowInsecure', ['0'])[0] == '1': p['skip-cert-verify'] = True
    elif scheme == 'vmess':
        try:
            data = json.loads(base64.b64decode(u.netloc).decode())
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
        if '@' in body:
            userinfo, _, hostport = body.rpartition('@')
            host, _, port = hostport.rpartition(':')
            if ':' not in userinfo:                      # base64(method:password)
                dec = base64.b64decode(userinfo).decode('utf-8', 'replace')
            else:
                dec = userinfo
            method, _, password = dec.partition(':')
            p = {'name': name, 'type': 'ss', 'server': host, 'port': port,
                 'cipher': method, 'password': password}
        else:                                            # legacy: whole thing base64
            m = re.match(r'^([^:]+):([^@]+)@([^:]+):(\d+)$',
                         base64.b64decode(body).decode('utf-8', 'replace'))
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
    for k in ('password', 'uuid', 'cipher', 'sni', 'servername',
              'client-fingerprint', 'alterId'):
        if k in p:
            o.append('      %s: %s' % (k, q(p[k])))
    if p.get('skip-cert-verify'): o.append('      skip-cert-verify: true')
    if p.get('tls'): o.append('      tls: true')
    if p.get('network'):
        o.append('      network: %s' % p['network'])
        for optk in ('ws-opts', 'xhttp-opts', 'grpc-opts'):
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
          "    nameserver: ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query', 223.5.5.5, 119.29.29.29]\n"
          "    fallback: ['https://8.8.8.8/dns-query', 'https://1.1.1.1/dns-query', 8.8.8.8, 1.1.1.1]\n"
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
          "    - 'GEOIP,CN,DIRECT'\n"
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
_sub_sanitize() { # <file> [controller]
    has python3 || return 0
    python3 - "$1" "${2:-$(controller_addr)}" <<'PY'
import sys, re
path, ctrl = sys.argv[1], sys.argv[2]
t = open(path).read()

pat = re.compile(r'剩余流量|套餐|到期|重置|官网|客服|邮箱|支持AI')
def name_of(s):
    s = s.strip().strip('"\'')
    return s
# info-node names: those proxy definitions whose name matches the pattern
defs = re.findall(r'(?m)^[ \t]+-\s*\{\s*name:\s*([^,}]+?),[^\n]*?(?:type:\s*\w+)', t)
drop = [name_of(d) for d in defs if pat.search(d)]

if drop:
    for n in drop:
        # drop the proxy definition line (name may be quoted in the definition)
        t = re.sub(r'(?m)^[ \t]+-\s*\{\s*name:\s*["\']?%s["\']?\s*,.*\}\s*\n' % re.escape(n), '', t)
    # rebuild every group's member list without the dropped names
    def clean_list(m):
        toks = [x.strip() for x in m.group(2).strip().split(',') if x.strip()]
        keep = [x for x in toks if name_of(x) not in drop]
        return m.group(1) + '[' + ', '.join(keep) + ']'
    t = re.sub(r'(proxies:\s*)\[(.*?)\]', clean_list, t, flags=re.S)

t = re.sub(r'(?m)^external-controller:\s*.*$', 'external-controller: %s' % ctrl, t)
open(path, 'w').write(t)
PY
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
        -h|--help|"") say "用法: proxy sub add <name> <url> | rm <name> | list | use <name> [--no-refresh] | show [name] | refresh [name] | set <url>" ;;
        *) die "proxy sub: 未知子命令 $sub" ;;
    esac
}

sub_add() {
    local name=$1 url=$2
    [[ -n "$name" && -n "$url" ]] || die "用法: proxy sub add <name> <url>  (name: 字母数字_-)"
    [[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "订阅名只能含字母数字_-"
    _sub_set "$name" "$url"
    ok "订阅 '$name' 已保存 ($(printf '%s' "$url" | awk -F/ '{print $3}'))"
    [[ -z "$(conf_get active_sub)" ]] && { conf_set active_sub "$name"; info "已设为活跃订阅"; }
}

sub_rm() {
    local name=$1
    [[ -n "$name" ]] || die "用法: proxy sub rm <name>"
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
    [[ -n "$name" ]] || die "用法: proxy sub use <name> [--no-refresh]"
    [[ "$1" == "--no-refresh" ]] && { norefresh=1; }
    # allow: proxy sub use <name> --no-refresh
    [[ "${2:-}" == "--no-refresh" ]] && norefresh=1
    [[ -n "$(_sub_get_url "$name")" ]] || die "无此订阅: $name (先 proxy sub add)"
    conf_set active_sub "$name"
    ok "活跃订阅: $name"
    if (( norefresh )); then
        info "未刷新 (--no-refresh); 应用它: proxy sub refresh"
    else
        info "切换并拉取应用 ..."
        sub_refresh "$name"
    fi
}

sub_set() {   # legacy one-shot
    local url=$1
    [[ -n "$url" ]] || die "用法: proxy sub set <url>  (或用 proxy sub add <name> <url>)"
    _sub_set default "$url"
    conf_set active_sub default
    ok "订阅 'default' 已保存并设为活跃, 正在拉取 ..."
    sub_refresh default
}

sub_refresh() {
    local name=${1:-$(_sub_active_name)}
    local url; url=$(_sub_url_for "$name")
    [[ -n "$url" ]] || die "订阅 '$name' 未配置 URL (先: proxy sub add <name> <url>)"
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"

    local bin ua
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    ua=$(conf_get sub_ua)
    [[ -n "$ua" ]] || ua="mihomo/$("$bin" -v 2>/dev/null | awk '{print $3;exit}')"

    info "拉取订阅 '$name' (UA: $ua) ..."
    if ! curl -fsSL --max-time 30 -A "$ua" "$url" -o "$CONFIG.new" 2>/dev/null; then
        die "拉取失败 (URL/UA/网络?), 配置未改动"
    fi
    local conv
    if conv=$(_sub_convert "$CONFIG.new"); then
        [[ -n "$conv" ]] && info "$conv"
    else
        die "订阅内容无法解析 (既不是 Clash YAML 也不是节点列表); 配置未改动"
    fi
    _sub_sanitize "$CONFIG.new"
    if ! mihomo_test "$CONFIG.new"; then
        warn "新订阅校验失败, 未替换; 末尾:"
        "$bin" -t -d "$CONF_DIR" -f "$CONFIG.new" 2>&1 | tail -3 >&2
        rm -f "$CONFIG.new"; return 1
    fi
    cp -f "$CONFIG" "$BAK"; mv -f "$CONFIG.new" "$CONFIG"
    [[ -n "$1" ]] && conf_set active_sub "$name"
    ok "订阅 '$name' 已更新, 备份 → $BAK"

    # re-apply merge so prepend-rules survive the subscription refresh
    if [[ -f "$MERGE_FILE" ]]; then
        # shellcheck source=merge.sh
        source "$SCRIPT_DIR/lib/merge.sh"
        if _merge_rules >/dev/null 2>&1; then
            info "重新应用 merge 规则 ..."
            merge_apply
        fi
    fi

    # re-apply region groups so they (and the ban list) survive the refresh
    if [[ -f "$CONF_DIR/regions.conf" ]]; then
        # shellcheck source=region.sh
        source "$SCRIPT_DIR/lib/region.sh"
        if [[ -n "$(_region_names)" ]]; then
            info "重新应用 region 组 ..."
            region_apply || warn "region 组应用失败 (稍后重试: proxy region apply)"
        fi
    fi

    # apply the on-disk config: hot-reload, or restart if controller is down
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply
}
