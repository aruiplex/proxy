# shellcheck shell=bash
# proxy/lib/route.sh — URL routing test: check whether a given URL reaches
# the internet through the proxy, directly, or both, with latency comparison.
#
#   proxy route <URL>            test proxy vs direct connectivity
#   proxy route <URL> --json     machine-readable output (for scripting)

# proxy_addr() is in env.sh
# shellcheck source=env.sh
source "$SCRIPT_DIR/lib/env.sh"

route_cmd() {
    local url=${1:-}
    case "$url" in
        -h|--help|"")
            say "用法: proxy route <URL> [--json]"
            say ""
            say "测试一个 URL 走代理还是直连，比较两端连通性和延迟。"
            say ""
            say "示例:"
            say "  proxy route https://api.deepseek.com/anthropic"
            say "  proxy route https://www.google.com --json"
            ;;
        *) route_test_url "$@" ;;
    esac
}

# test a single URL via the given proxy (or direct); prints "code time size" or "FAIL reason"
_route_curl() {
    local url=$1 proxy=$2
    local out curl_exit
    # proxy: set via -x; empty means direct (--noproxy '*')
    if [[ -n "$proxy" ]]; then
        out=$(curl -x "$proxy" -o /dev/null -s -w '%{http_code} %{time_total} %{size_download}' \
            --connect-timeout 5 --max-time 15 "$url" 2>&1)
        curl_exit=$?
    else
        out=$(curl --noproxy '*' -o /dev/null -s -w '%{http_code} %{time_total} %{size_download}' \
            --connect-timeout 5 --max-time 15 "$url" 2>&1)
        curl_exit=$?
    fi
    if (( curl_exit == 0 )); then
        printf '%s' "$out"
    elif (( curl_exit == 6 )); then
        printf 'FAIL DNS 解析失败'
    elif (( curl_exit == 7 )); then
        printf 'FAIL 连接被拒绝'
    elif (( curl_exit == 28 )); then
        printf 'FAIL 连接超时'
    elif (( curl_exit == 35 )); then
        printf 'FAIL SSL/TLS 握手失败'
    else
        printf 'FAIL curl 错误码 %d' "$curl_exit"
    fi
}

# format a "code time size" result line for human display
_route_fmt() {
    local raw=$1
    local code time size
    if [[ "$raw" == FAIL* ]]; then
        printf '%s' "${C_R}${raw}${C_N}"
        return
    fi
    read -r code time size <<< "$raw"
    local color="$C_G"
    (( code >= 400 && code < 600 )) && color="$C_Y"
    printf '%sHTTP %s%s  %s%0.3fs%s  %s%dB%s' \
        "$color" "$code" "$C_N" \
        "${C_D}" "$time" "$C_N" \
        "${C_D}" "$size" "$C_N"
}

route_test_url() {
    local url=$1 json_out=0
    [[ "$2" == "--json" ]] && json_out=1

    [[ -n "$url" ]] || die "用法: proxy route <URL>  (例: proxy route https://api.deepseek.com/anthropic)"
    # basic URL sanity check: must have a scheme
    [[ "$url" =~ ^https?:// ]] || die "URL 必须以 http:// 或 https:// 开头"

    local addr domain
    addr=$(proxy_addr)
    domain=$(printf '%s' "$url" | awk -F/ '{print $3}')

    if (( ! json_out )); then
        say "${C_B}=== URL 路由测试 ===${C_N}"
        say "URL:     $url"
        say "域名:    $domain"
        say "代理地址: http://$addr"
        say ""
    fi

    # --- proxy test ---
    local proxy_raw proxy_code proxy_time
    proxy_raw=$(_route_curl "$url" "http://$addr")
    read -r proxy_code proxy_time _ <<< "$proxy_raw"

    # --- direct test ---
    local direct_raw direct_code direct_time
    direct_raw=$(_route_curl "$url" "")
    read -r direct_code direct_time _ <<< "$direct_raw"

    if (( json_out )); then
        json_guard
        python3 -c "
import json
def p(raw):
    parts = raw.split()
    if parts[0] == 'FAIL':
        return {'ok': False, 'error': ' '.join(parts[1:])}
    return {'ok': True, 'http_code': int(parts[0]), 'time_s': float(parts[1]), 'size_bytes': int(parts[2])}
print(json.dumps({
    'url': '${url//\'/\\\'}',
    'domain': '${domain//\'/\\\'}',
    'proxy_addr': 'http://${addr//\'/\\\'}',
    'proxy': p('${proxy_raw//\'/\\\'}'),
    'direct': p('${direct_raw//\'/\\\'}')
}, indent=2))
"
        return
    fi

    # --- human output ---
    say "${C_B}▶ 代理连接${C_N}"
    printf '   %s\n' "$(_route_fmt "$proxy_raw")"

    say "${C_B}▶ 直连${C_N}"
    printf '   %s\n' "$(_route_fmt "$direct_raw")"

    say ""
    say "${C_B}=== 结论 ===${C_N}"

    local proxy_ok=0 direct_ok=0
    [[ "$proxy_code" =~ ^[0-9]+$ ]] && proxy_ok=1
    [[ "$direct_code" =~ ^[0-9]+$ ]] && direct_ok=1

    if (( proxy_ok && direct_ok )); then
        ok "代理和直连均可访问"
        local cmp
        cmp=$(python3 -c "
pt = float($proxy_time)
dt = float($direct_time)
if pt < dt:
    print('代理更快 (代理 {:.3f}s vs 直连 {:.3f}s)'.format(pt, dt))
elif dt < pt:
    print('直连更快 (直连 {:.3f}s vs 代理 {:.3f}s)'.format(dt, pt))
else:
    print('延迟相当 (均 {:.3f}s)'.format(pt))
" 2>/dev/null)
        [[ -n "$cmp" ]] && info "  $cmp"
    elif (( proxy_ok )); then
        ok "该 URL 需要通过代理访问 (直连不可达)"
    elif (( direct_ok )); then
        ok "该 URL 可以直连访问 (代理不可达)"
    else
        warn "该 URL 代理和直连均不可达，请检查网络和 URL"
    fi
}
