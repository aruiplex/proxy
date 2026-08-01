# shellcheck shell=bash
# proxy/lib/merge.sh — manage prepend-rules merged into config.yaml.
# Safe model (proven in apply-merge.sh v2): detect the original rules-list indent,
# text-prepend our block, then validate with `mihomo -t` BEFORE replacing, then
# hot-reload via the controller API. A rejected config never kills the running core.
# Pure bash + awk + mihomo self-validation — no python dependency on the write path.

MERGE_MARK_BEGIN="# >>> local-merge (auto) >>>"
MERGE_MARK_END="# <<< local-merge (auto) <<<"

merge_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        list)  merge_list "$@" ;;
        add)   merge_add "$@" ;;
        rm)    merge_rm "$@" ;;
        diff)  merge_diff "$@" ;;
        apply) merge_apply "$@" ;;
        -h|--help|"") say "用法: proxy merge list | add '<RULE>' | rm '<PAT>' | diff | apply" ;;
        *) die "proxy merge: 未知子命令 $sub" ;;
    esac
}

# parse prepend-rules from merge.yaml -> stdout, one rule per line
_merge_rules() {
    [[ -f "$MERGE_FILE" ]] || return 1
    awk '
        /^prepend-rules:[[:space:]]*$/ { in_r=1; next }
        /^[A-Za-z][A-Za-z0-9_-]*:/      { in_r=0 }
        in_r && /^[[:space:]]*-/ {
            line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line);
            sub(/[[:space:]]+#.*$/,"",line);
            if (line !~ /^[[:space:]]*$/) print line
        }
    ' "$MERGE_FILE"
}

merge_list() {
    [[ -f "$MERGE_FILE" ]] || die "无 $MERGE_FILE (先: proxy merge add '<RULE>')"
    say "${C_B}merge.yaml ($MERGE_FILE) prepend-rules:${C_N}"
    _merge_rules | sed 's/^/  - /'
}

merge_add() {
    local rule=$1 target=$2
    if [[ -n "$target" ]]; then
        case "$(printf '%s' "$rule" | tr '[:upper:]' '[:lower:]')" in
            direct|d) rule="DOMAIN-SUFFIX,$target,DIRECT" ;;
            proxy|p)  rule="DOMAIN-SUFFIX,$target,PROXIES" ;;
            reject|r) rule="DOMAIN-SUFFIX,$target,REJECT" ;;
            *) die "快捷语法形式: proxy merge add direct|proxy|reject <domain>" ;;
        esac
    fi
    [[ -n "$rule" ]] || die "用法: proxy merge add '<RULE>' 或 proxy merge add direct|proxy|reject <domain>"
    mkdir -p "$CONF_DIR"
    if [[ ! -f "$MERGE_FILE" ]]; then
        if [[ -f "$SCRIPT_DIR/templates/merge.yaml" ]]; then cp "$SCRIPT_DIR/templates/merge.yaml" "$MERGE_FILE"
        else printf 'prepend-rules:\n' > "$MERGE_FILE"; fi
    fi
    # ensure the header exists
    grep -q '^prepend-rules:' "$MERGE_FILE" || printf 'prepend-rules:\n' >> "$MERGE_FILE"
    printf '  - %s\n' "$rule" >> "$MERGE_FILE"
    ok "已添加: $rule"
    merge_apply
}

merge_rm() {
    local pat=$1
    [[ -n "$pat" ]] || die "用法: proxy merge rm '<子串>'  (按子串匹配整行删除)"
    [[ -f "$MERGE_FILE" ]] || die "无 $MERGE_FILE"
    grep -vF -- "$pat" "$MERGE_FILE" > "$MERGE_FILE.tmp" || true
    mv -f "$MERGE_FILE.tmp" "$MERGE_FILE"
    ok "已移除匹配 '$pat' 的行"
    merge_apply
}

merge_diff() {
    [[ -f "$MERGE_FILE" ]] || die "无 $MERGE_FILE"
    [[ -f "$CONFIG" ]]    || die "无 $CONFIG"
    local injected merged
    injected=$(awk '
        /^[[:space:]]*# >>> local-merge \(auto\) >>>/ { f=1; next }
        /^[[:space:]]*# <<< local-merge \(auto\) <<</ { f=0; next }
        f && /^[[:space:]]*-/ { line=$0; sub(/^[[:space:]]*-[[:space:]]*/,"",line); print line }
    ' "$CONFIG")
    merged=$(_merge_rules)
    if [[ "$injected" == "$merged" ]]; then
        ok "一致: merge.yaml 与 config.yaml 中已注入的规则相同"
    else
        warn "不一致 (左=merge.yaml 期望, 右=config.yaml 实际):"
        diff <(printf '%s\n' "$merged") <(printf '%s\n' "$injected") | sed 's/^/  /'
    fi
}

merge_apply() {
    [[ -f "$MERGE_FILE" ]] || die "无 $MERGE_FILE (先: proxy merge add '<RULE>')"
    [[ -f "$CONFIG" ]]    || die "无 $CONFIG (先: proxy init)"

    local RULES=()
    mapfile -t RULES < <(_merge_rules)
    (( ${#RULES[@]} > 0 )) || die "merge.yaml 未解析到 prepend-rules 条目"

    # 1) detect original rules-list indent
    local INDENT SPACES
    INDENT=$(awk '
        /^rules:[[:space:]]*$/ { f=1; next }
        f && /^[[:space:]]*#/  { next }
        f && /^[[:space:]]*$/  { next }
        f && /[[:space:]]*-/   { match($0,/^[[:space:]]*/); print RLENGTH; exit }
        f                      { exit }
    ' "$CONFIG")
    INDENT=${INDENT:-0}
    SPACES=$(printf '%*s' "$INDENT" '')

    # 2) build the block (same indent as the original list; no leading blank line)
    local BLOCK r
    BLOCK="${SPACES}${MERGE_MARK_BEGIN}"$'\n'
    for r in "${RULES[@]}"; do BLOCK+="${SPACES}- $r"$'\n'; done
    BLOCK+="${SPACES}${MERGE_MARK_END}"$'\n'

    # 3) strip any old block, insert new one right after `rules:`
    local tmp="$CONFIG.merge-tmp"
    awk -v block="$BLOCK" '
        BEGIN { skipping=0 }
        /^[[:space:]]*# >>> local-merge \(auto\) >>>/ { skipping=1; next }
        /^[[:space:]]*# <<< local-merge \(auto\) <<</ { skipping=0; next }
        skipping { next }
        /^rules:[[:space:]]*$/ { print; printf "%s", block; next }
        { print }
    ' "$CONFIG" > "$tmp"

    # 4) validate before replacing; never touch the running core on failure
    if ! mihomo_test "$tmp"; then
        warn "合并后配置校验失败，未替换 config.yaml，mihomo 未受影响:"
        local bin; bin=$(mihomo_bin) 2>/dev/null
        [[ -n "$bin" ]] && "$bin" -t -d "$CONF_DIR" -f "$tmp" 2>&1 | tail -4 >&2
        rm -f "$tmp"; return 1
    fi

    cp -f "$CONFIG" "$BAK"; mv -f "$tmp" "$CONFIG"
    info "已注入 ${#RULES[@]} 条规则 (缩进=${INDENT} 空格) 到 rules: 顶部; 备份 → $BAK"

    # 5) apply the on-disk config: hot-reload, or restart if controller is down
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply
}
