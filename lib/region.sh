# shellcheck shell=bash
# proxy/lib/region.sh — region-scoped auto groups generated into config.yaml.
#
# Problem: subscriptions ship one giant flat group; you want per-region
# failover (stay in SG, fall to US only if SG is dead), certain regions
# banned (HK), and a shorter health-check interval for flaky uplinks.
#
# Model (same safety contract as merge.sh): build a marked block of
# proxy-groups + filter banned nodes out of the subscription's own groups,
# validate with `mihomo -t` BEFORE replacing, then hot-reload. A rejected
# config never kills the running core. Re-applied automatically by
# `sub refresh` (same hook as merge), so groups survive subscription updates.
#
# Region definitions live in $CONF_DIR/regions.conf as `name<TAB>regex` lines
# (regex matched against node names; RE2 syntax, mihomo side). Nothing is
# hardcoded: regions, the ban list, and the check interval are all set via the
# CLI (region add/rm/set) and stored in regions.conf / proxy.conf keys
# (region_interval, region_url, region_exclude).
#
#   proxy region apply                  (re)generate region groups into config.yaml
#   proxy region list                   regions, settings, live group state
#   proxy region add <name> '<regex>'   add/update a region
#   proxy region rm <name>              remove
#   proxy region set interval|url|exclude <value>

REGION_MARK_BEGIN="# >>> local-region (auto) >>>"
REGION_MARK_END="# <<< local-region (auto) <<<"
REGIONS_FILE="$CONF_DIR/regions.conf"
REGION_MASTER="🚀 自动"

_region_ensure() {
    if [[ ! -f "$REGIONS_FILE" ]]; then
        mkdir -p "$CONF_DIR"
        cat > "$REGIONS_FILE" <<'EOF'
# proxy region 定义, 每行: name<TAB>regex   (regex 匹配节点名, RE2 语法)
# 用 proxy region add <name> '<regex>' 添加, 例: proxy region add 日本 '(?i)(japan|🇯🇵)'
EOF
    fi
}

_region_interval() { local v; v=$(conf_get region_interval); printf '%s' "${v:-60}"; }
_region_url()      { local v; v=$(conf_get region_url);      printf '%s' "${v:-http://www.gstatic.com/generate_204}"; }
# ban list (empty = ban nothing): removed from subscription groups' member lists
# AND exclude-filter'ed out of our include-all region groups. Set via
# `proxy region set exclude '<regex>'`.
_region_exclude()  { conf_get region_exclude; }

_region_names() { awk -F'\t' 'NF && $1 !~ /^#/ {print $1}' "$REGIONS_FILE"; }
_region_regex() { awk -F'\t' -v n="$1" '$1==n {print $2; exit}' "$REGIONS_FILE"; }
_region_group() { printf '%s-自动' "$1"; }   # region name -> group name

# first Selector group in config.yaml's proxy-groups section (the one rules
# point at, e.g. 节点选择); text-parse so this works with the controller down.
_region_select_group() {
    python3 - "$CONFIG" <<'PY' 2>/dev/null
import sys, re
names, cur, is_sel = [], None, False
in_groups = False
for line in open(sys.argv[1], encoding='utf-8'):
    if re.match(r'^proxy-groups:\s*$', line): in_groups = True; continue
    if in_groups and re.match(r'^[A-Za-z]', line): break
    if not in_groups: continue
    m = re.match(r'^\s*-\s+name:\s*(.+?)\s*$', line)
    if m:
        if cur and is_sel: print(cur); sys.exit(0)
        cur, is_sel = m.group(1).strip("'\""), False
        continue
    if cur and re.match(r'^\s+type:\s*select\s*$', line): is_sel = True
if cur and is_sel: print(cur)
PY
}

# build the marked proxy-groups block (master fallback chain + one fallback
# group per region). Indented to match the existing proxy-groups entries.
_region_block() {
    local G="$1" I U X name gname regex esc
    I=$(_region_interval); U=$(_region_url); X=$(_region_exclude)
    local F="${G}  "   # field/member indent = group indent + 2
    # master: sticky fallback across regions, in regions.conf order
    local members=() n
    while IFS= read -r n; do members+=("$(_region_group "$n")"); done < <(_region_names)
    (( ${#members[@]} > 0 )) || return 1
    esc=${U//\'/\'\'}
    printf '%s%s\n' "$G" "$REGION_MARK_BEGIN"
    printf '%s- name: %s\n%s  type: fallback\n%s  proxies:\n' "$G" "$REGION_MASTER" "$G" "$G"
    local m
    for m in "${members[@]}"; do printf '%s- %s\n' "$F" "$m"; done
    printf '%s  url: %s\n%s  interval: %s\n' "$G" "$U" "$G" "$I"
    # per-region: include-all + filter, so renamed/re-added nodes just work
    while IFS= read -r name; do
        gname=$(_region_group "$name")
        regex=$(_region_regex "$name")
        [[ -n "$regex" ]] || { warn "region '$name' 无 regex, 跳过"; continue; }
        esc=${regex//\'/\'\'}
        printf '%s- name: %s\n%s  type: fallback\n%s  include-all: true\n' "$G" "$gname" "$G" "$G"
        printf "%s  filter: '%s'\n" "$G" "$esc"
        if [[ -n "$X" ]]; then
            esc=${X//\'/\'\'}
            printf "%s  exclude-filter: '%s'\n" "$G" "$esc"
        fi
        printf '%s  url: %s\n%s  interval: %s\n' "$G" "$U" "$G" "$I"
    done < <(_region_names)
    printf '%s%s\n' "$G" "$REGION_MARK_END"
}

region_apply() {
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    json_guard   # surgery is python3-based: unicode/regex-safe, unlike awk
    _region_ensure

    # group-entry indent in this file (e.g. "- name:" at col 0)
    local G
    G=$(awk '/^proxy-groups:[[:space:]]*$/ {f=1; next}
             f && /^[[:space:]]*-[[:space:]]/ { match($0,/^[[:space:]]*/); print RLENGTH; exit }
             f && /^[A-Za-z]/ { exit }' "$CONFIG")
    G=$(printf '%*s' "${G:-0}" '')

    local BLOCK SEL
    BLOCK=$(_region_block "$G") || BLOCK=""   # no regions defined -> strip our groups (cleanup)
    SEL=$(_region_select_group)
    [[ -n "$SEL" ]] || warn "未在 config 中找到 select 组, 只注入地区组, 不改动现有组成员"

    # group names we manage (to strip stale refs before re-injecting); the
    # surgery additionally strips refs to any group found in the OLD block,
    # so `region rm` + apply never leaves dangling references.
    local OURS="$REGION_MASTER" n
    while IFS= read -r n; do OURS+=$'\n'"$(_region_group "$n")"; done < <(_region_names)

    local tmp="$CONFIG.region-tmp" btmp="$CONFIG.region-block"
    if [[ -n "$BLOCK" ]]; then printf '%s\n' "$BLOCK" > "$btmp"; else : > "$btmp"; fi
    python3 - "$CONFIG" "$SEL" "$(_region_exclude)" "$OURS" "$btmp" > "$tmp" <<'PY'
import sys, re
path, sel, exclude, ours, bpath = sys.argv[1], sys.argv[2], sys.argv[3], set(filter(None, sys.argv[4].split('\n'))), sys.argv[5]
block = open(bpath, encoding='utf-8').read().splitlines(keepends=True)
xre = re.compile(exclude) if exclude else None
lines = open(path, encoding='utf-8').read().splitlines(keepends=True)

out, skipping, in_groups = [], False, False
cur_group = None
inserted_block = inserted_refs = False
for line in lines:
    if re.match(r'^\s*# >>> local-region \(auto\) >>>', line): skipping = True; continue
    if re.match(r'^\s*# <<< local-region \(auto\) <<<', line): skipping = False; continue
    if skipping:
        m = re.match(r'^\s*-\s+name:\s*(.+?)\s*$', line)
        if m: ours.add(m.group(1).strip("'\""))   # stale refs to old groups must go too
        continue
    if re.match(r'^proxy-groups:\s*$', line):
        in_groups = True
        out.append(line)
        if not inserted_block: out.extend(block); inserted_block = True
        continue
    if in_groups and re.match(r'^[A-Za-z]', line): in_groups = False
    if in_groups:
        m = re.match(r'^\s*-\s+name:\s*(.+?)\s*$', line)
        if m: cur_group = m.group(1).strip("'\"")
        m = re.match(r'^\s*-\s+(.*?)\s*$', line)
        if m and 'name:' not in line:
            member = m.group(1).strip("'\"")
            if member in ours or (xre and xre.search(member)): continue   # stale ref / banned node
        # inject our group refs at the top of the select group's member list
        # (only when there are groups to inject — empty block = cleanup mode)
        if sel and block and not inserted_refs and cur_group == sel and re.match(r'^\s+proxies:\s*$', line):
            out.append(line)
            indent = re.match(r'^(\s*)', line).group(1)
            for g in sys.argv[4].split('\n'):
                if g: out.append('%s- %s\n' % (indent, g))
            inserted_refs = True
            continue
    out.append(line)
sys.stdout.write(''.join(out))
PY
    local rc=$?
    rm -f "$btmp"
    (( rc == 0 )) && [[ -s "$tmp" ]] || { rm -f "$tmp"; die "生成配置失败 (python 处理)"; }

    if ! mihomo_test "$tmp"; then
        warn "注入 region 组后配置校验失败, 未替换 config.yaml, mihomo 未受影响:"
        local bin; bin=$(mihomo_bin 2>/dev/null)
        [[ -n "$bin" ]] && "$bin" -t -d "$CONF_DIR" -f "$tmp" 2>&1 | tail -4 >&2
        rm -f "$tmp"; return 1
    fi
    cp -f "$CONFIG" "$BAK"; mv -f "$tmp" "$CONFIG"
    if [[ -n "$BLOCK" ]]; then
        ok "已注入 region 组 (间隔 $(_region_interval)s$([[ -n "$(_region_exclude)" ]] && printf ', 排除: %s' "$(_region_exclude)")); 备份 → $BAK"
    else
        ok "已无地区定义, 已从配置移除 region 组; 备份 → $BAK"
    fi

    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply

    # if the select group currently points at a node we just removed, re-pin
    # it to the master group so traffic isn't left on a stale choice
    if [[ -n "$BLOCK" && -n "$SEL" ]] && ctrl_up; then
        local enc now
        enc=$(jq_uri "$SEL")
        now=$(ctrl_get "/proxies/$enc" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
now=d.get('now','')
print('STALE' if now and now not in (d.get('all') or []) else '')" 2>/dev/null)
        if [[ "$now" == STALE ]]; then
            local code; code=$(ctrl_put "/proxies/$enc" "{\"name\":\"$REGION_MASTER\"}")
            [[ "$code" == 204 ]] && ok "选择组 '$SEL' 原选中节点已被屏蔽, 已切到 '$REGION_MASTER'" \
                                 || warn "切换 '$SEL' → '$REGION_MASTER' 失败 (HTTP $code); 手动: proxy node use '$REGION_MASTER'"
        fi
    fi
}

region_list() {
    _region_ensure
    say "${C_B}regions ($REGIONS_FILE):${C_N}"
    if [[ -z "$(_region_names)" ]]; then
        info "  (空; 用 proxy region add <name> '<regex>' 添加, 例: proxy region add SG '(?i)(singapore|🇸🇬)')"
    fi
    local name regex g enc
    while IFS=$'\t' read -r name regex; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        g=$(_region_group "$name")
        printf '  %-8s %-40s → %s' "$name" "$regex" "$g"
        if ctrl_up; then
            enc=$(jq_uri "$g")
            ctrl_get "/proxies/$enc" 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print('  [now: %s, %d nodes]' % (d.get('now','-'), len(d.get('all') or [])))
except Exception: print()
" 2>/dev/null || printf '\n'
        else
            printf '\n'
        fi
    done < "$REGIONS_FILE"
    say "settings: interval=$(_region_interval)s  url=$(_region_url)"
    local x; x=$(_region_exclude)
    say "exclude:  ${x:-(空 — 不屏蔽任何节点)}"
    ctrl_up || info "(控制器未启动, 仅显示静态配置)"
}

_region_preset_regex() {
    local n; n=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$n" in
        hk|hongkong|香港)     printf '(?i)(hong[ -]?kong|🇭🇰|\\bhk\\b)' ;;
        sg|singapore|新加坡)  printf '(?i)(singapore|🇸🇬|\\bsg\\b|狮城)' ;;
        us|usa|america|美国) printf '(?i)(united states|🇺🇸|america|\\bus\\b|美)' ;;
        jp|japan|日本)       printf '(?i)(japan|🇯🇵|\\bjp\\b|东京|大阪)' ;;
        tw|taiwan|台湾)      printf '(?i)(taiwan|🇹🇼|\\btw\\b|台北)' ;;
        kr|korea|韩国)       printf '(?i)(korea|🇰🇷|\\bkr\\b|首尔)' ;;
        uk|london|英国)      printf '(?i)(united kingdom|🇬🇧|\\buk\\b|伦敦)' ;;
        *) return 1 ;;
    esac
}

region_add() {
    local name=$1 regex=$2
    [[ -n "$name" ]] || die "用法: proxy region add <name> ['<regex>']  (内置快捷别名: HK, SG, US, JP, TW, KR, UK)"
    if [[ -z "$regex" ]]; then
        regex=$(_region_preset_regex "$name") || die "未知地区简写 '$name'; 请提供正则表达式或使用内置别名: HK, SG, US, JP, TW, KR, UK"
        info "自动应用预设正则: $regex"
    fi
    [[ "$name" != *$'\t'* && "$name" != *$'\n'* ]] || die "地区名不能含制表符/换行"
    printf '%s' "$regex" | python3 -c "import sys,re; re.compile(sys.stdin.read())" 2>/dev/null \
        || die "regex 无法编译: $regex"
    _region_ensure
    awk -F'\t' -v n="$name" '$1!=n' "$REGIONS_FILE" > "$REGIONS_FILE.tmp"
    printf '%s\t%s\n' "$name" "$regex" >> "$REGIONS_FILE.tmp"
    mv -f "$REGIONS_FILE.tmp" "$REGIONS_FILE"
    ok "地区 '$name' 已保存 → $(_region_group "$name")"
    region_apply
}

region_rm() {
    local name=$1
    [[ -n "$name" ]] || die "用法: proxy region rm <name>"
    [[ -f "$REGIONS_FILE" ]] || die "无 $REGIONS_FILE"
    grep -q "^${name}	" "$REGIONS_FILE" || die "无此地区: $name"
    awk -F'\t' -v n="$name" '$1!=n' "$REGIONS_FILE" > "$REGIONS_FILE.tmp"
    mv -f "$REGIONS_FILE.tmp" "$REGIONS_FILE"
    ok "地区 '$name' 已移除"
    region_apply
}

region_set() {
    local k=$1 v=${2-}
    [[ -n "$k" ]] || die "用法: proxy region set interval|url|exclude <value>  (exclude 支持快捷预设: default | hk | clear)"
    case "$k" in
        interval) [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 10 )) || die "interval 需为 >=10 的秒数" ;;
        url)      [[ "$v" =~ ^https?:// ]] || die "url 需以 http(s):// 开头" ;;
        exclude)
            case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
                default|std|standard)
                    v='(?i)(hong[ -]?kong|🇭🇰|\bhk\b|剩余|重置|套餐|到期|流量|官网|中转|倍率|订阅|通知)'
                    info "应用默认排除规则 (HK 及机场流量/官网节点)" ;;
                hk)
                    v='(?i)(hong[ -]?kong|🇭🇰|\bhk\b|剩余|重置|套餐|到期|流量)'
                    info "应用 HK 及流量节点排除规则" ;;
                clear|none|off)
                    v=''
                    info "已清空排除规则" ;;
            esac
            [[ -z "$v" ]] || printf '%s' "$v" | python3 -c "import sys,re; re.compile(sys.stdin.read())" 2>/dev/null \
                          || die "regex 无法编译: $v" ;;
        *) die "未知设置项: $k (可选: interval|url|exclude)" ;;
    esac
    conf_set "region_$k" "$v"
    ok "region_$k = ${v:-(空, 不屏蔽)}"
    region_apply
}

region_preset() {
    _region_ensure
    say "${C_B}一键加载常用地区 (HK, SG, JP, US) 与默认排除规则...${C_N}"
    awk -F'\t' 'NF && $1 !~ /^#/ {print $1}' "$REGIONS_FILE" > "$REGIONS_FILE.bak" 2>/dev/null || true
    region_add HK >/dev/null 2>&1 || true
    region_add SG >/dev/null 2>&1 || true
    region_add JP >/dev/null 2>&1 || true
    region_add US >/dev/null 2>&1 || true
    conf_set "region_exclude" '(?i)(hong[ -]?kong|🇭🇰|\bhk\b|剩余|重置|套餐|到期|流量|官网|中转|倍率)'
    ok "一键预设应用完成 (包含 HK, SG, JP, US 分组与默认排除规则)"
    region_apply
}

region_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        apply) region_apply "$@" ;;
        list|ls) region_list "$@" ;;
        add)   region_add "$@" ;;
        rm)    region_rm "$@" ;;
        set)   region_set "$@" ;;
        preset) region_preset "$@" ;;
        -h|--help|"") say "用法: proxy region apply | list | preset | add <name> ['<regex>'] | rm <name> | set interval|url|exclude <value>" ;;
        *) die "proxy region: 未知子命令 $sub" ;;
    esac
}
