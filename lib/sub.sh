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
    [[ -n "$ua" ]] || ua="clash-meta/$("$bin" -v 2>/dev/null | awk '{print $3;exit}')"

    info "拉取订阅 '$name' (UA: $ua) ..."
    if ! curl -fsSL --max-time 30 -A "$ua" "$url" -o "$CONFIG.new" 2>/dev/null; then
        die "拉取失败 (URL/UA/网络?), 配置未改动"
    fi
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

    # apply the on-disk config: hot-reload, or restart if controller is down
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_apply
}
