# shellcheck shell=bash
# proxy/lib/node.sh — exit-node management via the controller API.

node_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        list) node_list "$@" ;;
        test) node_test "$@" ;;
        use)  node_use "$@" ;;
        -h|--help|"") say "用法: proxy node list | test [GROUP] | use <NAME>" ;;
        *) die "proxy node: 未知子命令 $sub" ;;
    esac
}

node_list() {
    json_guard
    local g
    g=$(node_group)
    [[ -n "$g" ]] || die "未找到可选节点组 (config.yaml 里没有 Selector/URLTest 组?)"
    local now
    now=$(ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
    say "${C_B}组: $g${C_N}  当前: ${C_G}$now${C_N}"
    ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for n in d.get('all',[]):
    print('  -',n)
" 2>/dev/null
}

# test every node in a group for latency; prints sorted ascending
node_test() {
    json_guard
    local g url timeout
    g=${1:-$(node_group)}
    [[ -n "$g" ]] || die "未找到节点组"
    url=$(conf_get test_url); url=${url:-https://www.google.com}
    timeout=$(conf_get test_timeout); timeout=${timeout:-5000}
    info "测延迟 (group=$g, url=$url, timeout=${timeout}ms) ..."
    ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(n) for n in d.get('all',[])]" 2>/dev/null | while read -r n; do
        local code ms
        out=$(ctrl_get "/proxies/$(jq_uri "$n")/delay?url=${url}&timeout=${timeout}" 2>/dev/null)
        ms=$(printf '%s' "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('delay',''))" 2>/dev/null)
        if [[ -n "$ms" ]]; then
            printf '%6s ms  %s\n' "$ms" "$n"
        else
            printf '%6s     %s\n' "x" "$n"
        fi
    done | sort -n
}

node_use() {
    json_guard
    local name=$1 g code
    [[ -n "$name" ]] || die "用法: proxy node use <NAME>"
    g=$(node_group)
    [[ -n "$g" ]] || die "未找到节点组"
    code=$(ctrl_put "/proxies/$(jq_uri "$g")" "{\"name\":\"$name\"}")
    case "$code" in
        204|200) ok "已切换: $name (组 $g)" ;;
        *) die "切换失败 (HTTP $code)。节点名是否正确？运行 proxy node list" ;;
    esac
}
