# shellcheck shell=bash
# proxy/lib/pool.sh — 节点池模式: merge ALL subscriptions into one config with
# semantic-normalized node names, so the user never cares which airport a node
# belongs to. Airport-level failures (quota exhausted, provider down) are
# absorbed: each region group pools every airport's nodes, and the 🚀 自动
# fallback chain moves traffic between region groups when one goes fully dead —
# seamless, mihomo-native failover, no daemon.
#
# Node names are normalized through a semantic layer (flags/tags/倍率 suffixes
# stripped, country aliases mapped to canonical names, sequential numbering):
#   🇸🇬Singapore 01 / 新加坡01 / [一倍电信]HK 01 / 🇺🇸 美国G1|实验|1倍|V1
#   → 新加坡01 / 新加坡02 / 香港01 / 美国01 ...
# regions.conf regexes then operate on these normalized names, so the user's
# region config needs no changes between single-sub and pool mode.
#
#   proxy pool on | off | status | refresh

POOL_STATE_DIR="$CONF_DIR/pool-state"

pool_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        on)      pool_on "$@" ;;
        off)     pool_off "$@" ;;
        status|show) pool_status "$@" ;;
        refresh) pool_refresh "$@" ;;
        -h|--help|"")
            say "用法: proxy pool on | off | status | refresh"
            say ""
            say "节点池模式: 所有机场节点合并 + 语义归一化命名,"
            say "mihomo fallback 组自动无感切换 (机场挂了不影响使用)。"
            say "  on       开启并构建节点池 (聚合全部订阅)"
            say "  off      退回单订阅模式 (proxy sub use 管理)"
            say "  status   池状态: 订阅/节点数/地区组/当前出口"
            say "  refresh  重新拉取全部订阅重建池 (部分失败保留旧节点)"
            ;;
        *) die "proxy pool: 未知子命令 $sub" ;;
    esac
}

pool_on() {
    conf_set pool on
    if ! pool_refresh; then
        conf_set pool ""
        return 1
    fi
}

pool_off() {
    conf_set pool ""
    ok "已退回单订阅模式, 用活跃订阅重建配置 ..."
    # shellcheck source=sub.sh
    source "$SCRIPT_DIR/lib/sub.sh"
    sub_refresh
}

# --- fetch one subscription -> proxies section (pool-state/<name>.prox) ---
# returns 0 on success (freshly fetched), 1 on failure; on failure falls back
# to the last-good pool-state copy when one exists.
_pool_fetch() { # <name> <url> <ua> <work>
    local name=$1 url=$2 ua=$3 work=$4
    local raw="$work/$name.raw" prox="$work/$name.prox"
    if ! curl -fsSL --max-time 30 -A "$ua" "$url" -o "$raw" 2>/dev/null; then
        warn "订阅 '$name' 拉取失败"
    else
        _sub_convert "$raw" >/dev/null 2>&1 || true
        _sub_sanitize "$raw" >/dev/null 2>&1 || true
        if python3 - "$raw" "$prox" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding='utf-8').read().splitlines(keepends=True)
idx = None
for i, ln in enumerate(lines):
    if re.match(r'^proxies:[ \t]*$', ln):
        idx = i
        break
if idx is None:
    sys.exit(1)
out, inp = [], False
for ln in lines[idx:]:
    if re.match(r'^proxies:[ \t]*$', ln):
        inp = True; out.append(ln); continue
    if inp and re.match(r'^[A-Za-z]', ln):
        break
    if inp:
        out.append(ln)
open(dst, 'w').write(''.join(out))
PY
        then
            cp -f "$prox" "$POOL_STATE_DIR/$name.prox"
            return 0
        fi
        warn "订阅 '$name' 解析失败 (内容不是有效 Clash 配置)"
    fi
    # fall back to last-good state
    if [[ -f "$POOL_STATE_DIR/$name.prox" ]]; then
        cp -f "$POOL_STATE_DIR/$name.prox" "$prox"
        warn "使用上一轮的 '$name' 节点 ($POOL_STATE_DIR/$name.prox)"
        return 2
    fi
    warn "跳过 '$name' (无历史节点)"
    return 1
}

# --- assemble pool config: normalize names, build groups, emit YAML ---
_pool_assemble() { # <work-dir> <out-file>
    python3 - "$1" "$CONFIG" "$REGIONS_FILE" "$2" "$(controller_addr)" "$(conf_get lan)" "$(_region_exclude)" <<'PY'
import sys, re, os, glob

work, oldconf, regfile, outpath, ctrl, lan, exclude = sys.argv[1:8]

# ---- country aliases -> canonical region (order matters: first hit wins) ----
ALIASES = [
    ('新加坡', [r'singapore', r'\bsg\b', '\U0001F1F8\U0001F1EC', '狮城']),
    ('香港',   [r'hong ?kong', r'\bhk\b', '\U0001F1ED\U0001F1F0']),
    ('澳门',   [r'macao', r'\bmo\b', '\U0001F1F2\U0001F1F4']),
    ('台湾',   [r'taiwan', r'\btw\b', '\U0001F1F9\U0001F1FC', '台北', '台中', '高雄']),
    ('日本',   [r'japan', r'\bjp\b', '\U0001F1EF\U0001F1F5', '东京', '大阪', '名古屋', '札幌', '冲绳']),
    ('韩国',   [r'korea', r'\bkr\b', '\U0001F1F0\U0001F1F7', '首尔']),
    ('美国',   [r'united ?states', r'america', r'\bus\b', r'\busa\b', '\U0001F1FA\U0001F1F8', '美东', '美西', '美']),
    ('加拿大', [r'canada', r'\bca\b', '\U0001F1E8\U0001F1E6', '温哥华', '多伦多']),
    ('墨西哥', [r'mexico', r'\bmx\b', '\U0001F1F2\U0001F1FD']),
    ('巴西',   [r'brazil', r'\bbr\b', '\U0001F1E7\U0001F1F7']),
    ('阿根廷', [r'argentina', r'\bar\b', '\U0001F1E6\U0001F1F7', '布宜诺']),
    ('智利',   [r'chile', r'\bcl\b', '\U0001F1E8\U0001F1F1']),
    ('秘鲁',   [r'peru', r'\bpe\b', '\U0001F1F5\U0001F1EA']),
    ('哥伦比亚', [r'colombia', r'\bco\b', '\U0001F1E8\U0001F1F4']),
    ('英国',   [r'united ?kingdom', r'\buk\b', r'\bgb\b', '\U0001F1EC\U0001F1E7', '伦敦', '曼彻斯特']),
    ('法国',   [r'france', r'\bfr\b', '\U0001F1EB\U0001F1F7', '巴黎']),
    ('德国',   [r'germany', r'\bde\b', '\U0001F1E9\U0001F1EA', '柏林', '法兰克福']),
    ('荷兰',   [r'netherlands', r'holland', r'\bnl\b', '\U0001F1F3\U0001F1F1', '阿姆斯特丹']),
    ('比利时', [r'belgium', r'\bbe\b', '\U0001F1E7\U0001F1EA']),
    ('瑞士',   [r'swiss', r'switzerland', r'\bch\b', '\U0001F1E8\U0001F1ED']),
    ('奥地利', [r'austria', r'\bat\b', '\U0001F1E6\U0001F1F9']),
    ('意大利', [r'italy', r'\bit\b', '\U0001F1EE\U0001F1F9', '米兰', '罗马']),
    ('西班牙', [r'spain', r'\bes\b', '\U0001F1EA\U0001F1F8', '马德里', '巴塞罗那']),
    ('葡萄牙', [r'portugal', r'\bpt\b', '\U0001F1F5\U0001F1F9', '里斯本']),
    ('俄罗斯', [r'russia', r'\bru\b', '\U0001F1F7\U0001F1FA', '莫斯科']),
    ('乌克兰', [r'ukraine', r'\bua\b', '\U0001F1FA\U0001F1E6']),
    ('土耳其', [r'turkey', r'turkiye', r'\btr\b', '\U0001F1F9\U0001F1F7', '伊斯坦布尔']),
    ('阿联酋', [r'uae', r'dubai', r'\bae\b', '\U0001F1E6\U0001F1EA', '迪拜']),
    ('沙特',   [r'saudi', r'\bsa\b', '\U0001F1F8\U0001F1E6']),
    ('以色列', [r'israel', r'\bil\b', '\U0001F1EE\U0001F1F1', '特拉维夫']),
    ('埃及',   [r'egypt', r'\beg\b', '\U0001F1EA\U0001F1EC']),
    ('南非',   [r'south ?africa', r'\bza\b', '\U0001F1FF\U0001F1E6']),
    ('澳大利亚', [r'australia', r'\bau\b', '\U0001F1E6\U0001F1FA', '悉尼', '墨尔本']),
    ('新西兰', [r'new ?zealand', r'\bnz\b', '\U0001F1F3\U0001F1FF', '奥克兰']),
    ('印度',   [r'india', r'\bin\b', '\U0001F1EE\U0001F1F3', '孟买']),
    ('印尼',   [r'indonesia', r'indo', r'\bid\b', '\U0001F1EE\U0001F1E9', '雅加达']),
    ('马来西亚', [r'malaysia', r'\bmy\b', '\U0001F1F2\U0001F1FE', '吉隆坡']),
    ('菲律宾', [r'philippines', r'\bph\b', '\U0001F1F5\U0001F1ED', '马尼拉']),
    ('越南',   [r'vietnam', r'\bvn\b', '\U0001F1FB\U0001F1F3', '胡志明', '河内']),
    ('泰国',   [r'thailand', r'\bth\b', '\U0001F1F9\U0001F1ED', '曼谷']),
    ('缅甸',   [r'myanmar', r'burma', '\U0001F1F2\U0001F1F2']),
    ('柬埔寨', [r'cambodia', r'\bkh\b', '\U0001F1F0\U0001F1ED']),
    ('蒙古',   [r'mongolia', r'\bmn\b', '\U0001F1F2\U0001F1F3']),
    ('哈萨克', [r'kazakhstan', r'\bkz\b', '\U0001F1F0\U0001F1FF']),
    ('波兰',   [r'poland', r'\bpl\b', '\U0001F1F5\U0001F1F1']),
    ('瑞典',   [r'sweden', r'\bse\b', '\U0001F1F8\U0001F1EA', '斯德哥尔摩']),
    ('挪威',   [r'norway', r'\bno\b', '\U0001F1F3\U0001F1F4', '奥斯陆']),
    ('芬兰',   [r'finland', r'\bfi\b', '\U0001F1EB\U0001F1EE', '赫尔辛基']),
    ('丹麦',   [r'denmark', r'\bdk\b', '\U0001F1E9\U0001F1F0', '哥本哈根']),
    ('捷克',   [r'czech', r'\bcz\b', '\U0001F1E8\U0001F1FF', '布拉格']),
    ('匈牙利', [r'hungary', r'\bhu\b', '\U0001F1ED\U0001F1FA', '布达佩斯']),
    ('罗马尼亚', [r'romania', r'\bro\b', '\U0001F1F7\U0001F1F4']),
    ('希腊',   [r'greece', r'\bgr\b', '\U0001F1EC\U0001F1F7', '雅典']),
    ('爱尔兰', [r'ireland', r'\bie\b', '\U0001F1EE\U0001F1EA', '都柏林']),
    ('尼日利亚', [r'nigeria', r'\bng\b', '\U0001F1F3\U0001F1EC']),
]

def clean(raw):
    n = raw
    n = re.sub(r'[\U0001F1E6-\U0001F1FF]{2}', '', n)        # flag emojis
    n = re.sub(r'[\U0001F000-\U0001FAFF\u2600-\u27BF]', '', n)  # other emojis
    n = n.split('|')[0]                                     # |实验|1倍|V1 suffix
    n = re.sub(r'\[[^\]]*\]', ' ', n)                       # [一倍电信]
    n = re.sub(r'(?i)(cloudfront|telecom|unicom|mobile|experiment|native|ipv6|ipv4|倍率|流量|解锁|家宽|实验|优化|专线|中转|机场|官网|线路|节点)', ' ', n)
    n = re.sub(r'[\d.]*\s*倍', ' ', n)                      # 0.7倍 / 一倍
    n = re.sub(r'\s+', ' ', n).strip(' -|·')
    return n

def region_of(cleaned):
    low = cleaned.lower()
    for canon, pats in ALIASES:
        if canon in low:            # 规范化名本身 (中文机场常直接写 新加坡01)
            return canon
        for p in pats:
            try:
                if re.search(p, low):
                    return canon
            except re.error:
                pass
    return ''

# ---- read old config for preservation (ports / tun / secret / external-ui) ----
old = ''
try:
    old = open(oldconf, encoding='utf-8').read()
except Exception:
    pass
def oldkv(key):
    m = re.search(r'(?m)^%s:\s*(.+?)\s*$' % re.escape(key), old)
    return m.group(1).strip() if m else None

port_keys = ''
for k in ('mixed-port', 'port', 'socks-port'):
    v = oldkv(k)
    if v:
        port_keys += '%s: %s\n' % (k, v)
if not port_keys:
    port_keys = 'mixed-port: 7890\n'
secret = oldkv('secret')
extui = oldkv('external-ui')
tun = ''
m = re.search(r'(?m)^tun:[ \t]*\n(?:[ \t]+.*\n)*', old)
if m:
    tun = m.group(0)

# ---- read regions.conf ----
regions = []
try:
    for line in open(regfile, encoding='utf-8'):
        line = line.rstrip('\n')
        if not line or line.startswith('#'):
            continue
        if '\t' in line:
            nm, rx = line.split('\t', 1)
            nm = nm.strip()
            if nm:
                regions.append((nm, rx.strip()))
except Exception:
    pass

# ---- read node entries from per-sub proxies sections ----
entries = []   # (canonical, cleaned-original, text)
for pf in sorted(glob.glob(os.path.join(work, '*.prox'))):
    t = open(pf, encoding='utf-8').read()
    lines = t.splitlines(keepends=True)
    i = 0
    while i < len(lines):
        ln = lines[i]
        m = re.match(r'^([ \t]+)-\s', ln)
        if m and 'name:' in ln:
            if '{' in ln:                       # flow style: single line
                buf = [ln]; i += 1
            else:                               # block style: until next entry
                indent = m.group(1)
                buf = [ln]; i += 1
                while i < len(lines):
                    l2 = lines[i]
                    if not l2.strip():
                        buf.append(l2); i += 1; continue
                    m2 = re.match(r'^([ \t]+)-\s', l2)
                    if m2 and len(m2.group(1)) == len(indent) and 'name:' in l2:
                        break
                    if re.match(r'^[^ \t]', l2):
                        break
                    buf.append(l2); i += 1
            text = ''.join(buf)
            mname = re.search(r'name:\s*(["\']?)(.*?)\1(?=\s*[,}\n]|$)', text, re.S)
            raw_name = mname.group(2).strip() if mname else ''
            if not raw_name:
                continue
            cleaned = clean(raw_name)
            entries.append((region_of(cleaned), cleaned, text))
            continue
        i += 1

if not entries:
    print('池内无任何节点 (订阅全部失败?)', file=sys.stderr)
    sys.exit(1)

# ---- normalize: sequential numbering per canonical region (deterministic) ----
from collections import defaultdict
by_canon = defaultdict(list)
for canon, cleaned, text in entries:
    by_canon[canon].append((cleaned, text))
numbered = []       # (canon, final_name, text)
used = set()
for canon in sorted(by_canon, key=lambda c: (c == '', c)):
    lst = sorted(by_canon[canon], key=lambda x: x[0].lower())
    for idx, (cleaned, text) in enumerate(lst, 1):
        final = ('%s%02d' % (canon, idx)) if canon else cleaned
        if final in used:                       # unnamed collision -> suffix
            k = 2
            while '%s-%d' % (final, k) in used:
                k += 1
            final = '%s-%d' % (final, k)
        used.add(final)
        numbered.append((canon, final, text))

# ---- rename the name field in each entry text ----
def rename(text, new):
    return re.sub(r'(name:\s*)(["\']?)(.*?)\2(?=\s*[,}\n]|$)',
                  lambda m: m.group(1) + m.group(2) + new + m.group(2),
                  text, count=1)

proxies_out = []
for canon, final, text in numbered:
    proxies_out.append(rename(text, final))

# ---- build groups ----
xre = re.compile(exclude) if exclude else None
gdefs = list(regions)
have = {g for g, _ in gdefs}
for canon in sorted({c for c, _, _ in numbered if c}):
    if canon not in have:
        gdefs.append((canon, '^' + re.escape(canon)))
gregex = {}
for g, rx in gdefs:
    try:
        gregex[g] = re.compile(rx)
    except re.error:
        continue
gmembers = defaultdict(list)
other = []
for canon, final, text in numbered:
    if xre and xre.search(final):
        continue                                 # banned: not in any group
    hit = None
    for g, rx in gregex.items():
        if rx.search(final):
            hit = g
            break
    if hit:
        gmembers[hit].append(final)
    else:
        other.append(final)
gorder = [g for g, _ in gdefs if g in gmembers]
gorder.sort(key=lambda g: next((i for i, (n, _) in enumerate(gdefs) if n == g), 99))

def sq(s):
    return "'%s'" % s.replace("'", "''")

group_lines = []
chain = []
for g in gorder:
    gn = '%s-自动' % g
    chain.append(gn)
    group_lines.append('    - name: %s' % gn)
    group_lines.append('      type: url-test')
    group_lines.append('      url: http://www.gstatic.com/generate_204')
    group_lines.append('      interval: 300')
    group_lines.append('      tolerance: 50')
    group_lines.append('      lazy: true')
    group_lines.append('      include-all: true')
    group_lines.append('      filter: %s' % sq(gregex[g].pattern))
    if xre:
        group_lines.append('      exclude-filter: %s' % sq(xre.pattern))
other_name = None
if other:
    other_name = '其他-自动'
    chain.append(other_name)
    group_lines.append('    - name: %s' % other_name)
    group_lines.append('      type: url-test')
    group_lines.append('      url: http://www.gstatic.com/generate_204')
    group_lines.append('      interval: 300')
    group_lines.append('      tolerance: 50')
    group_lines.append('      lazy: true')
    group_lines.append('      proxies:')
    for nm in other:
        group_lines.append('        - %s' % nm)

member = '\n'.join('      - %s' % c for c in chain)
entry_groups = '\n'.join('        - %s' % c for c in ['🚀 自动'] + chain)

out = []
out.append(port_keys.rstrip('\n'))
out.append('mode: rule')
out.append('log-level: info')
out.append('external-controller: %s' % ctrl)
if secret:
    out.append('secret: %s' % secret)
if extui:
    out.append('external-ui: %s' % extui)
if lan == 'on':
    out.append("allow-lan: true")
    out.append("bind-address: '*'")
elif lan == 'off':
    out.append('allow-lan: false')
if tun:
    out.append('')
    out.append(tun.rstrip('\n'))
out.append('')
out.append('dns:')
out.append('    enable: true')
out.append('    ipv6: false')
out.append('    enhanced-mode: fake-ip')
out.append('    fake-ip-range: 198.18.0.1/16')
out.append('    default-nameserver: [223.5.5.5, 119.29.29.29]')
out.append("    nameserver: ['https://doh.pub/dns-query', 'https://dns.alidns.com/dns-query', 223.5.5.5, 119.29.29.29]")
out.append("    fallback: ['https://8.8.8.8/dns-query', 'https://1.1.1.1/dns-query', 8.8.8.8, 1.1.1.1]")
out.append('proxies:')
out.append('\n'.join(proxies_out))
out.append('')
out.append('proxy-groups:')
out.append('    - name: 节点选择')
out.append('      type: select')
out.append('      proxies:')
out.append(entry_groups)
out.append('    - name: 🚀 自动')
out.append('      type: fallback')
out.append('      url: http://www.gstatic.com/generate_204')
out.append('      interval: 300')
out.append('      proxies:')
out.append(member)
out.extend(group_lines)
out.append('')
out.append('rules:')
out.append("    - 'GEOIP,CN,DIRECT'")
out.append("    - 'MATCH,节点选择'")
out.append('')
open(outpath, 'w').write('\n'.join(out))
print('merged %d nodes from %d entries' % (len(numbered), len(entries)))
PY
}

# --- build the pool: fetch all subs, assemble, validate, replace, apply ---
pool_refresh() {
    json_guard
    local bin ua
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制 (运行 proxy install)"
    ua=$(conf_get sub_ua)
    [[ -n "$ua" ]] || ua="mihomo/$("$bin" -v 2>/dev/null | awk '{print $3;exit}')"
    # shellcheck source=sub.sh
    source "$SCRIPT_DIR/lib/sub.sh"
    # shellcheck source=region.sh
    source "$SCRIPT_DIR/lib/region.sh"
    _region_ensure
    mkdir -p "$POOL_STATE_DIR"

    # collect subscriptions
    local -a names urls
    if [[ -f "$SUBS_FILE" ]]; then
        local n u
        while IFS=$'\t' read -r n u; do
            [[ -n "$n" && -n "$u" && "$n" != \#* ]] || continue
            names+=("$n"); urls+=("$u")
        done < "$SUBS_FILE"
    fi
    if (( ${#names[@]} == 0 )); then
        local legacy; legacy=$(conf_get sub_url)
        [[ -n "$legacy" ]] && { names=(default); urls=("$legacy"); }
    fi
    (( ${#names[@]} > 0 )) || die "无订阅 (先: proxy sub add <name> <url>)"

    local work; work=$(mktemp -d)
    trap 'rm -rf "$work"' RETURN
    local i okn=0
    for i in "${!names[@]}"; do
        info "拉取 '${names[$i]}' ..."
        _pool_fetch "${names[$i]}" "${urls[$i]}" "$ua" "$work"
        case $? in
            0) okn=$((okn+1)) ;;
            2) okn=$((okn+1)) ;;   # stale but usable
        esac
    done

    local out="$work/pool.yaml"
    if ! _pool_assemble "$work" "$out"; then
        die "池配置生成失败 (无任何订阅可用?)"
    fi
    if ! mihomo_test "$out"; then
        warn "池配置校验失败, 未替换 config.yaml, mihomo 未受影响:"
        "$bin" -t -d "$CONF_DIR" -f "$out" 2>&1 | tail -4 >&2
        return 1
    fi
    cp -f "$CONFIG" "$BAK"; mv -f "$out" "$CONFIG"
    ok "节点池已构建: $okn/${#names[@]} 个订阅生效"
    date +%s > "$POOL_STATE_DIR/.built"

    # re-apply merge rules so prepend-rules survive the rebuild
    if [[ -f "$MERGE_FILE" ]]; then
        # shellcheck source=merge.sh
        source "$SCRIPT_DIR/lib/merge.sh"
        merge_apply
    fi

    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply
    pool_status
}

pool_status() {
    # shellcheck source=region.sh   (REGIONS_FILE 定义在此)
    source "$SCRIPT_DIR/lib/region.sh"
    local mode; mode=$(conf_get pool)
    if [[ "$mode" == "on" ]]; then
        ok "节点池模式: on"
    else
        info "节点池模式: off (单订阅模型; proxy pool on 开启)"
        return 0
    fi
    local built; built=$(cat "$POOL_STATE_DIR/.built" 2>/dev/null)
    if [[ -n "$built" ]]; then
        say "上次构建:  $(date -d @"$built" '+%F %T' 2>/dev/null || echo 未知)"
    fi
    say "${C_B}订阅节点数:${C_N}"
    local f
    for f in "$POOL_STATE_DIR"/*.prox; do
        [[ -f "$f" ]] || continue
        printf '  %-18s %s 节点\n' "$(basename "$f" .prox)" "$(grep -cE '^[ \t]+- ' "$f")"
    done
    if ctrl_up; then
        local g now; g=$(node_group)
        if [[ -n "$g" ]]; then
            now=$(ctrl_get "/proxies/$(jq_uri "$g")" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('now',''))" 2>/dev/null)
            say "当前出口:  $g → ${now:-?}"
        fi
        # live state of the pool groups (regions + 其他 + chain)
        local name
        while IFS=$'\t' read -r name _; do
            [[ -n "$name" && "$name" != \#* ]] || continue
            local enc now cnt
            enc=$(jq_uri "$name-自动")
            read -r now cnt < <(ctrl_get "/proxies/$enc" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('now','-'), len(d.get('all') or []))
except Exception: print('-', 0)" 2>/dev/null)
            printf '  %-14s now=%s  (%s 节点)\n' "$name-自动" "$now" "$cnt"
        done < "$REGIONS_FILE"
        local enc2 now2
        enc2=$(jq_uri "其他-自动")
        now2=$(ctrl_get "/proxies/$enc2" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('now','-'))" 2>/dev/null)
        [[ -n "$now2" ]] && printf '  %-14s now=%s\n' "其他-自动" "$now2"
    else
        info "控制器未启动; 仅显示静态状态 (proxy status 诊断)"
    fi
}
