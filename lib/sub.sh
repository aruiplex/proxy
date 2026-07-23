# shellcheck shell=bash
# proxy/lib/sub.sh — subscription management. Refresh re-pulls the subscription,
# validates, replaces config, then re-applies merge so prepend-rules survive.

sub_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        set)     sub_set "$@" ;;
        refresh) sub_refresh "$@" ;;
        -h|--help|"") say "用法: proxy sub set <URL> | refresh" ;;
        *) die "proxy sub: 未知子命令 $sub" ;;
    esac
}

sub_set() {
    local url=$1
    [[ -n "$url" ]] || die "用法: proxy sub set <URL>"
    conf_set sub_url "$url"
    ok "订阅 URL 已保存到 proxy.conf (mode 600)"
}

sub_refresh() {
    local bin url ua
    bin=$(mihomo_bin) || die "未找到 mihomo 二进制"
    url=$(conf_get sub_url)
    [[ -n "$url" ]] || die "未配置订阅 URL (先: proxy sub set <URL>)"
    [[ -f "$CONFIG" ]] || die "无 $CONFIG (先: proxy init)"
    ua=$(conf_get sub_ua)
    [[ -n "$ua" ]] || ua="clash-meta/$("$bin" -v 2>/dev/null | awk '{print $3;exit}')"

    info "拉取订阅 (UA: $ua) ..."
    if ! curl -fsSL --max-time 30 -A "$ua" "$url" -o "$CONFIG.new" 2>/dev/null; then
        die "拉取失败 (URL/UA/网络?), 配置未改动"
    fi
    if ! mihomo_test "$CONFIG.new"; then
        warn "新订阅校验失败, 未替换; 末尾:"
        "$bin" -t -d "$CONF_DIR" -f "$CONFIG.new" 2>&1 | tail -3 >&2
        rm -f "$CONFIG.new"; return 1
    fi
    cp -f "$CONFIG" "$BAK"; mv -f "$CONFIG.new" "$CONFIG"
    ok "订阅已更新, 备份 → $BAK"

    # re-apply merge so prepend-rules survive the subscription refresh
    if [[ -f "$MERGE_FILE" ]]; then
        # shellcheck source=merge.sh
        source "$SCRIPT_DIR/lib/merge.sh"
        if _merge_rules >/dev/null 2>&1; then
            info "重新应用 merge 规则 ..."
            merge_apply
        fi
    fi

    local code; code=$(ctrl_reload "$CONFIG")
    case "$code" in
        204|200) ok "已热重载" ;;
        000)     warn "控制器无响应 (mihomo 未运行?); 配置已更新, 下次 proxy start 生效" ;;
        *)       warn "热重载 HTTP $code; 可 proxy restart" ;;
    esac
}
