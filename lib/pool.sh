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
    info "正在用活跃订阅重建单订阅配置 ..."
    # shellcheck source=sub.sh
    source "$SCRIPT_DIR/lib/sub.sh"
    if ! sub_refresh; then
        conf_set pool on
        warn "重建失败，节点池模式保持开启"
        return 1
    fi
    ok "已退回单订阅模式"
}

# --- fetch one subscription -> proxies section (pool-state/<name>.prox) ---
# returns 0 on success (freshly fetched), 1 on failure; on failure falls back
# to the last-good pool-state copy when one exists.
_pool_fetch() { # <name> <url> <ua> <work>
    local name=$1 url=$2 ua=$3 work=$4
    local raw="$work/$name.raw" prox="$work/$name.prox"
    if ! curl_download_private "$url" "$raw" "$ua" 2>/dev/null; then
        warn "订阅 '$name' 拉取失败"
    else
        if _sub_convert "$raw" >/dev/null 2>&1 \
           && _sub_sanitize "$raw" >/dev/null 2>&1 \
           && python3 - "$raw" "$prox" <<'PY'
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
            : > "$work/$name.fresh"
            return 0
        fi
        warn "订阅 '$name' 解析失败 (内容不是有效 Clash 配置)"
    fi
    # fall back to last-good state
    rm -f "$raw" # discard failed/partial downloads before selecting cached routing
    if [[ -f "$POOL_STATE_DIR/$name.prox" ]]; then
        cp -f "$POOL_STATE_DIR/$name.prox" "$prox"
        [[ ! -f "$POOL_STATE_DIR/$name.profile" ]] || cp -f "$POOL_STATE_DIR/$name.profile" "$raw"
        warn "使用上一轮的 '$name' 节点 ($POOL_STATE_DIR/$name.prox)"
        return 2
    fi
    warn "跳过 '$name' (无历史节点)"
    return 1
}

# --- assemble pool config: normalize names, build groups, emit YAML ---
_pool_assemble() { # <work-dir> <out-file>
    # shellcheck source=region.sh
    source "$SCRIPT_DIR/lib/region.sh"
    python3 - "$1" "$CONFIG" "$REGIONS_FILE" "$2" "$(controller_addr)" "$(conf_get lan)" "$(_region_exclude)" "$(_region_interval)" "$(_region_url)" "${POOL_RULES_SOURCE:-$(conf_get pool_rules_source)}" "$(conf_get active_sub)" "$SCRIPT_DIR/libexec" <<'PY'
import sys, re, os, glob, json
sys.path.insert(0, sys.argv[12])
from routing_profile import routing_entry
from pool_profile import apply_profile

work, oldconf, regfile, outpath, ctrl, lan, exclude, interval, test_url = sys.argv[1:10]
baseline = sys.argv[10] or sys.argv[11]
if not baseline or not re.fullmatch(r'[A-Za-z0-9_.-]+', baseline):
    sys.exit('节点池需要明确的规则基准: 先选择 active_sub 或设置 pool_rules_source')
profile_path = os.path.join(work, baseline + '.raw')
if not os.path.isfile(profile_path):
    sys.exit('规则基准不可用；保留现用配置，不生成简化兜底规则')
profile = open(profile_path, encoding='utf-8').read()
interval = interval or '60'
test_url = test_url or 'http://www.gstatic.com/generate_204'

# ---- country aliases -> canonical region (order matters: first hit wins) ----
ALIASES = [
    ('SG', [r'singapore', r'\bsg\b', '\U0001F1F8\U0001F1EC', '新加坡', '狮城']),
    ('HK', [r'hong ?kong', r'\bhk\b', '\U0001F1ED\U0001F1F0', '香港']),
    ('MO', [r'macao', r'\bmo\b', '\U0001F1F2\U0001F1F4', '澳门']),
    ('TW', [r'taiwan', r'\btw\b', '\U0001F1F9\U0001F1FC', '台湾', '台北', '台中', '高雄']),
    ('JP', [r'japan', r'\bjp\b', '\U0001F1EF\U0001F1F5', '日本', '东京', '大阪', '名古屋', '札幌', '冲绳']),
    ('KR', [r'korea', r'\bkr\b', '\U0001F1F0\U0001F1F7', '韩国', '首尔']),
    ('US', [r'united ?states', r'america', r'\bus\b', r'\busa\b', '\U0001F1FA\U0001F1F8', '美国', '美东', '美西', '美']),
    ('CA', [r'canada', r'\bca\b', '\U0001F1E8\U0001F1E6', '加拿大', '温哥华', '多伦多']),
    ('MX', [r'mexico', r'\bmx\b', '\U0001F1F2\U0001F1FD', '墨西哥']),
    ('BR', [r'brazil', r'\bbr\b', '\U0001F1E7\U0001F1F7', '巴西']),
    ('AR', [r'argentina', r'\bar\b', '\U0001F1E6\U0001F1F7', '阿根廷', '布宜诺']),
    ('CL', [r'chile', r'\bcl\b', '\U0001F1E8\U0001F1F1', '智利']),
    ('PE', [r'peru', r'\bpe\b', '\U0001F1F5\U0001F1EA', '秘鲁']),
    ('CO', [r'colombia', r'\bco\b', '\U0001F1E8\U0001F1F4', '哥伦比亚']),
    ('UK', [r'united ?kingdom', r'\buk\b', r'\bgb\b', '\U0001F1EC\U0001F1E7', '英国', '伦敦', '曼彻斯特']),
    ('FR', [r'france', r'\bfr\b', '\U0001F1EB\U0001F1F7', '法国', '巴黎']),
    ('DE', [r'germany', r'\bde\b', '\U0001F1E9\U0001F1EA', '德国', '柏林', '法兰克福']),
    ('NL', [r'netherlands', r'holland', r'\bnl\b', '\U0001F1F3\U0001F1F1', '荷兰', '阿姆斯特丹']),
    ('BE', [r'belgium', r'\bbe\b', '\U0001F1E7\U0001F1EA', '比利时']),
    ('CH', [r'swiss', r'switzerland', r'\bch\b', '\U0001F1E8\U0001F1ED', '瑞士']),
    ('AT', [r'austria', r'\bat\b', '\U0001F1E6\U0001F1F9', '奥地利']),
    ('IT', [r'italy', r'\bit\b', '\U0001F1EE\U0001F1F9', '意大利', '米兰', '罗马']),
    ('ES', [r'spain', r'\bes\b', '\U0001F1EA\U0001F1F8', '西班牙', '马德里', '巴塞罗那']),
    ('PT', [r'portugal', r'\bpt\b', '\U0001F1F5\U0001F1F9', '葡萄牙', '里斯本']),
    ('RU', [r'russia', r'\bru\b', '\U0001F1F7\U0001F1FA', '俄罗斯', '莫斯科']),
    ('UA', [r'ukraine', r'\bua\b', '\U0001F1FA\U0001F1E6', '乌克兰']),
    ('TR', [r'turkey', r'turkiye', r'\btr\b', '\U0001F1F9\U0001F1F7', '土耳其', '伊斯坦布尔']),
    ('AE', [r'uae', r'dubai', r'\bae\b', '\U0001F1E6\U0001F1EA', '阿联酋', '迪拜']),
    ('SA', [r'saudi', r'\bsa\b', '\U0001F1F8\U0001F1E6', '沙特']),
    ('IL', [r'israel', r'\bil\b', '\U0001F1EE\U0001F1F1', '以色列', '特拉维夫']),
    ('EG', [r'egypt', r'\beg\b', '\U0001F1EA\U0001F1EC', '埃及']),
    ('ZA', [r'south ?africa', r'\bza\b', '\U0001F1FF\U0001F1E6', '南非']),
    ('AU', [r'australia', r'\bau\b', '\U0001F1E6\U0001F1FA', '澳大利亚', '澳洲', '悉尼', '墨尔本']),
    ('NZ', [r'new ?zealand', r'\bnz\b', '\U0001F1F3\U0001F1FF', '新西兰', '奥克兰']),
    ('IN', [r'india', r'\bin\b', '\U0001F1EE\U0001F1F3', '印度', '孟买']),
    ('ID', [r'indonesia', r'indo', r'\bid\b', '\U0001F1EE\U0001F1E9', '印尼', '印度尼西亚', '雅加达']),
    ('MY', [r'malaysia', r'\bmy\b', '\U0001F1F2\U0001F1FE', '马来西亚', '大马', '吉隆坡']),
    ('PH', [r'philippines', r'\bph\b', '\U0001F1F5\U0001F1ED', '菲律宾', '马尼拉']),
    ('VN', [r'vietnam', r'\bvn\b', '\U0001F1FB\U0001F1F3', '越南', '胡志明', '河内']),
    ('TH', [r'thailand', r'\bth\b', '\U0001F1F9\U0001F1ED', '泰国', '曼谷']),
    ('MM', [r'myanmar', r'burma', '\U0001F1F2\U0001F1F2', '缅甸']),
    ('KH', [r'cambodia', r'\bkh\b', '\U0001F1F0\U0001F1ED', '柬埔寨']),
    ('MN', [r'mongolia', r'\bmn\b', '\U0001F1F2\U0001F1F3', '蒙古']),
    ('KZ', [r'kazakhstan', r'\bkz\b', '\U0001F1F0\U0001F1FF', '哈萨克']),
    ('PL', [r'poland', r'\bpl\b', '\U0001F1F5\U0001F1F1', '波兰']),
    ('SE', [r'sweden', r'\bse\b', '\U0001F1F8\U0001F1EA', '瑞典', '斯德哥尔摩']),
    ('NO', [r'norway', r'\bno\b', '\U0001F1F3\U0001F1F4', '挪威', '奥斯陆']),
    ('FI', [r'finland', r'\bfi\b', '\U0001F1EB\U0001F1EE', '芬兰', '赫尔辛基']),
    ('DK', [r'denmark', r'\bdk\b', '\U0001F1E9\U0001F1F0', '丹麦', '哥本哈根']),
    ('CZ', [r'czech', r'\bcz\b', '\U0001F1E8\U0001F1FF', '捷克', '布拉格']),
    ('HU', [r'hungary', r'\bhu\b', '\U0001F1ED\U0001F1FA', '匈牙利', '布达佩斯']),
    ('RO', [r'romania', r'\bro\b', '\U0001F1F7\U0001F1F4', '罗马尼亚']),
    ('GR', [r'greece', r'\bgr\b', '\U0001F1EC\U0001F1F7', '希腊', '雅典']),
    ('IE', [r'ireland', r'\bie\b', '\U0001F1EE\U0001F1EA', '爱尔兰', '都柏林']),
    ('NG', [r'nigeria', r'\bng\b', '\U0001F1F3\U0001F1EC', '尼日利亚']),
]

def clean(raw):
    n = raw
    n = re.sub(r'[\U0001F1E6-\U0001F1FF]{2}', '', n)        # flag emojis
    n = re.sub(r'[\U0001F000-\U0001FAFF\u2600-\u27BF]', '', n)  # other emojis
    n = re.sub(r'[\u2700-\u27BF\uFE00-\uFE0F\U0001F900-\U0001F9FF]', '', n)
    n = n.split('|')[0]                                     # |实验|1倍|V1 suffix
    n = re.sub(r'\[[^\]]*\]', ' ', n)                       # [一倍电信]
    n = re.sub(r'(?i)(cloudfront|telecom|unicom|mobile|experiment|native|ipv6|ipv4|倍率|流量|解锁|家宽|实验|优化|专线|中转|机场|官网|线路|节点)', ' ', n)
    n = re.sub(r'[\d.]*\s*倍', ' ', n)                      # 0.7倍 / 一倍
    n = re.sub(r'\s+', ' ', n).strip(' -|·')
    return n

def region_of(cleaned):
    low = cleaned.lower()
    for canon, pats in ALIASES:
        if canon.lower() == low or re.search(r'\b%s\b' % re.escape(canon.lower()), low):
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
            entries.append((region_of(cleaned), cleaned, text, os.path.basename(pf)[:-5], raw_name))
            continue
        i += 1

if not entries:
    print('池内无任何节点 (订阅全部失败?)', file=sys.stderr)
    sys.exit(1)

# ---- normalize: sequential numbering per canonical region (deterministic) ----
from collections import defaultdict
by_canon = defaultdict(list)
for canon, cleaned, text, source, original in entries:
    by_canon[canon].append((cleaned, text, source, original))
baseline_renames = {}
source_renames = defaultdict(dict)
node_sources = {}
numbered = []       # (canon, final_name, text)
used = set()
for canon in sorted(by_canon, key=lambda c: (c == '', c)):
    lst = sorted(by_canon[canon], key=lambda x: x[0].lower())
    for idx, (cleaned, text, source, original) in enumerate(lst, 1):
        final = ('%s%02d' % (canon, idx)) if canon else cleaned
        if final in used:                       # unnamed collision -> suffix
            k = 2
            while '%s-%d' % (final, k) in used:
                k += 1
            final = '%s-%d' % (final, k)
        used.add(final)
        numbered.append((canon, final, text))
        source_renames[source][original] = final
        node_sources[final] = source
        if source == baseline:
            baseline_renames[original] = final

# ---- rename the name field in each entry text ----
def rename(text, new):
    return re.sub(r'(name:\s*)(["\']?)(.*?)\2(?=\s*[,}\n]|$)',
                  lambda m: m.group(1) + m.group(2) + new + m.group(2),
                  text, count=1)

proxies_out = []
for canon, final, text in numbered:
    renamed = rename(text, final)
    refs = source_renames[node_sources[final]]
    dialer = routing_entry(renamed).get('dialer-proxy')
    if dialer in refs:
        renamed = re.sub(r'(dialer-proxy:\s*)([^,}\n]+)', lambda m: m[1] + json.dumps(refs[dialer], ensure_ascii=False), renamed)
    indent = len(re.match(r'^([ \t]*)-', renamed)[1])
    proxies_out.append(''.join('    ' + line[indent:] if line.strip() else line
                               for line in renamed.splitlines(keepends=True)))

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
    gn = '%s-Auto' % g
    chain.append(gn)
    group_lines.append('    - name: %s' % gn)
    group_lines.append('      type: url-test')
    group_lines.append('      url: %s' % test_url)
    group_lines.append('      interval: %s' % interval)
    group_lines.append('      tolerance: 50')
    group_lines.append('      lazy: true')
    group_lines.append('      include-all: true')
    group_lines.append('      filter: %s' % sq(gregex[g].pattern))
    if xre:
        group_lines.append('      exclude-filter: %s' % sq(xre.pattern))
other_name = None
if other:
    other_name = 'Other-Auto'
    chain.append(other_name)
    group_lines.append('    - name: %s' % other_name)
    group_lines.append('      type: url-test')
    group_lines.append('      url: %s' % test_url)
    group_lines.append('      interval: %s' % interval)
    group_lines.append('      tolerance: 50')
    group_lines.append('      lazy: true')
    group_lines.append('      proxies:')
    for nm in other:
        group_lines.append('        - %s' % nm)

member = '\n'.join('      - %s' % c for c in chain)
entry_groups = '\n'.join('        - %s' % c for c in ['AUTO'] + chain)

proxies_section = 'proxies:\n' + ''.join(proxies_out).rstrip('\n') + '\n'
groups = ['proxy-groups:',
          '    - name: 节点选择',
          '      type: select',
          '      include-all: true']
if xre:
    groups.append('      exclude-filter: %s' % sq(xre.pattern))
groups.extend([
          '      proxies:',
          entry_groups,
          '    - name: AUTO',
          '      type: fallback',
          '      url: %s' % test_url,
          '      interval: %s' % interval,
          '      proxies:',
          member])
groups.extend(group_lines)
groups_section = '\n'.join(groups).rstrip('\n') + '\n'

def replace_top_section(text, key, section):
    lines = text.splitlines(keepends=True)
    start = end = None
    for i, line in enumerate(lines):
        if re.match(r'^%s\s*:' % re.escape(key), line):
            start = i
            end = i + 1
            while end < len(lines):
                cur = lines[end]
                if cur.strip() and re.match(r'^[A-Za-z0-9_-]+\s*:', cur):
                    break
                end += 1
            break
    replacement = section.splitlines(keepends=True)
    if start is None:
        if lines and lines[-1].strip():
            lines.append('\n')
        lines.extend(replacement)
    else:
        lines[start:end] = replacement
    return ''.join(lines)

if old.strip():
    rendered = replace_top_section(old, 'proxies', proxies_section)
    rendered = replace_top_section(rendered, 'proxy-groups', groups_section)
else:
    rendered = (port_keys + 'mode: rule\nlog-level: info\n'
                'external-controller: %s\n' % ctrl)
    rendered += proxies_section
# The active source owns routing; other subscriptions contribute nodes only.
rendered = apply_profile(rendered, profile, baseline_renames, '\n'.join(groups[1:]) + '\n', '节点选择', exclude)
rendered = re.sub(r'(?m)^x-proxy-node-regions:.*\n?', '', rendered)
rendered += 'x-proxy-node-regions: ' + json.dumps({final: canon for canon, final, _ in numbered if canon}, ensure_ascii=False) + '\n'
open(outpath, 'w').write(rendered)
print('merged %d nodes from %d entries' % (len(numbered), len(entries)))
PY
}

# --- build the pool: fetch all subs, assemble, validate, replace, apply ---
pool_refresh() { (
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

    local work; work=$(mktemp -d) || die "无法创建节点池临时目录"
    trap 'rm -rf "$work"' EXIT
    local i okn=0
    for i in "${!names[@]}"; do
        info "拉取 '${names[$i]}' ..."
        _pool_fetch "${names[$i]}" "${urls[$i]}" "$ua" "$work"
        case $? in
            0) okn=$((okn+1)) ;;
            2) okn=$((okn+1)) ;;   # stale but usable
        esac
    done

    local baseline; baseline=$(conf_get pool_rules_source)
    [[ -n "$baseline" ]] || baseline=$(conf_get active_sub)
    # Legacy caches stored only nodes. Recover the explicit baseline profile when available.
    if [[ -n "$baseline" && ! -f "$work/$baseline.raw" && -f "$CONF_DIR/config.$baseline.yaml" ]]; then
        cp -f "$CONF_DIR/config.$baseline.yaml" "$work/$baseline.raw"
    fi
    local out="$work/pool.yaml"
    if ! _pool_assemble "$work" "$out"; then
        die "池配置生成失败 (无任何订阅可用?)"
    fi
    # Compose local overrides in the candidate before automatic policy expansion.
    if [[ -f "$MERGE_FILE" ]]; then
        source "$SCRIPT_DIR/lib/merge.sh"
        ( CONFIG="$out" PRESERVE_BAK=1 DEFER_APPLY=1 merge_apply ) || return 1
    fi
    source "$SCRIPT_DIR/lib/auto.sh"
    _adaptive_replay "$out" || return 1
    if ! mihomo_test "$out"; then
        warn "池配置校验失败, 未替换 config.yaml, mihomo 未受影响:"
        "$bin" -t -d "$CONF_DIR" -f "$out" 2>&1 | tail -4 >&2
        return 1
    fi
    local fresh fname
    for fresh in "$work"/*.fresh; do
        [[ -f "$fresh" ]] || continue
        fname=$(basename "$fresh" .fresh)
        cp -f "$work/$fname.prox" "$POOL_STATE_DIR/$fname.prox" \
            || die "无法提交节点池缓存: $fname"
        cp -f "$work/$fname.raw" "$POOL_STATE_DIR/$fname.profile" \
            || die "无法提交订阅规则缓存: $fname"
    done
    cp -f "$CONFIG" "$BAK" || die "无法备份当前配置，节点池未替换"
    mv -f "$out" "$CONFIG" || die "无法替换 config.yaml"
    ok "节点池已构建: $okn/${#names[@]} 个订阅生效"
    date +%s > "$POOL_STATE_DIR/.built"

    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    if ! ( svc_apply ); then
        cp -f "$BAK" "$CONFIG"
        warn "节点池配置无法应用，磁盘配置已回滚"
        ( svc_apply ) >/dev/null 2>&1 || true
        return 1
    fi
    pool_status
); }

pool_status() {
    # shellcheck source=region.sh   (REGIONS_FILE 定义在此)
    source "$SCRIPT_DIR/lib/region.sh"
    local mode; mode=$(conf_get pool)
    say "${C_B}=== 节点池状态 (Pool Mode) ===${C_N}"
    if [[ "$mode" == "on" ]]; then
        ok "  模式状态:    ● on (已开启 · 聚合全部订阅)"
    else
        info "  模式状态:    ○ off (单订阅模式; 可运行 proxy pool on 开启)"
        return 0
    fi
    local built; built=$(cat "$POOL_STATE_DIR/.built" 2>/dev/null)
    if [[ -n "$built" ]]; then
        local build_time
        build_time=$(date -d @"$built" '+%F %T' 2>/dev/null || echo 未知)
        say "  上次构建:    $build_time"
    fi

    # Subscriptions & node counts
    local sub_files=("$POOL_STATE_DIR"/*.prox)
    local total_nodes=0 total_subs=0
    say ""
    say "  ${C_B}📦 聚合订阅源:${C_N}"
    if [[ -f "${sub_files[0]}" ]]; then
        local i=0 n_subs=${#sub_files[@]} f count sub_name branch
        for f in "${sub_files[@]}"; do
            [[ -f "$f" ]] || continue
            i=$((i + 1))
            total_subs=$((total_subs + 1))
            sub_name=$(basename "$f" .prox)
            count=$(grep -cE '^[ \t]+- ' "$f" 2>/dev/null || true)
            count=${count:-0}
            total_nodes=$((total_nodes + count))
            if (( i == n_subs )); then branch="└─"; else branch="├─"; fi
            printf '    %s %-16s %4s 节点\n' "$branch" "$sub_name" "$count"
        done
        printf '    %s %s\n' "  " "${C_D}─────────────────────────${C_N}"
        printf '    %s %s\n' "  " "共计: ${C_G}${total_subs}${C_N} 个订阅 · ${C_G}${total_nodes}${C_N} 个节点"
    else
        info "    (无已缓存的订阅节点，可运行: proxy pool refresh)"
    fi

    if ctrl_up; then
        local g now; g=$(node_group)
        if [[ -n "$g" ]]; then
            now=$(ctrl_get "/proxies/$(jq_uri "$g")" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('now',''))" 2>/dev/null)
            say ""
            say "  ${C_B}🎯 当前出口:${C_N}  $g → ${C_G}${now:-?}${C_N}"
        fi

        say ""
        say "  ${C_B}🌐 地区自动测速/故障转移组 (实时状态):${C_N}"
        python3 - <<'PY'
import sys, json, urllib.request

def fetch_proxies():
    try:
        req = urllib.request.Request("http://127.0.0.1:9090/proxies")
        with urllib.request.urlopen(req, timeout=3) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return {}

d = fetch_proxies()
proxies = d.get('proxies', {})
groups = []
if 'AUTO' in proxies:
    v = proxies['AUTO']
    groups.append(('AUTO', v.get('type', ''), v.get('now', '-'), len(v.get('all', []))))
elif '🚀 自动' in proxies:
    v = proxies['🚀 自动']
    groups.append(('AUTO', v.get('type', ''), v.get('now', '-'), len(v.get('all', []))))

for name, v in sorted(proxies.items()):
    if name in ('AUTO', '🚀 自动', 'GLOBAL', 'DIRECT', 'REJECT', '节点选择'):
        continue
    gtype = v.get('type', '')
    if gtype in ('URLTest', 'Fallback', 'Selector') and (name.endswith('-Auto') or name.endswith('-自动')):
        groups.append((name, gtype, v.get('now', '-'), len(v.get('all', []))))

n_groups = len(groups)
for idx, (name, gtype, now, count) in enumerate(groups):
    branch = '└─' if idx == n_groups - 1 else '├─'
    cnt_str = f"({count} 地区组)" if name in ('AUTO', '🚀 自动') else f"({count} 节点)"
    print(f"    {branch} \033[1m{name:<12}\033[0m 当前: \033[32m{now:<14}\033[0m \033[2m{cnt_str}\033[0m")
PY
    else
        say ""
        info "  (控制器未在运行，启动后可查看实时故障转移状态: proxy start)"
    fi
    say "${C_D}──────────────────────────────────────────${C_N}"
}
