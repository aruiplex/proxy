# shellcheck shell=bash
# proxy/lib/node.sh — exit-node management via the controller API.
# Picking is convenient: `node list` numbers nodes; `node use` accepts a
# number, a substring (unique->switch, ambiguous->menu), or nothing (interactive:
# fzf if available, else a numbered menu).

node_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        list) node_list "$@" ;;
        test) node_test "$@" ;;
        use)  node_use "$@" ;;
        -h|--help|"") say "用法: proxy node list | test [GROUP] | use [<#|子串>]   (无参=交互选择)" ;;
        *) die "proxy node: 未知子命令 $sub" ;;
    esac
}

# member names of a group, one per line (clean, for both listing and matching).
# Airport info pseudo-nodes (剩余流量/套餐到期/...) aren't real proxies and
# can't be selected/tested — filtered out so numbering in `list` matches `use`.
_node_members() {
    ctrl_get "/proxies/$(jq_uri "$1")" | python3 -c "import sys,json;d=json.load(sys.stdin);[print(n) for n in d.get('all',[])]" 2>/dev/null \
      | grep -vE '剩余流量|套餐到期|距离下次|到期|Traffic|Expire'
}

node_list() {
    json_guard
    ctrl_require            # distinguishes "controller down" from "no group"
    local g
    g=$(node_group)
    [[ -n "$g" ]] || die "config.yaml 里没有 Selector/URLTest 节点组 (订阅是否含 proxy-groups? proxy sub refresh 后 proxy restart)"
    local now
    now=$(ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
    say "${C_B}组: $g${C_N}  当前: ${C_G}$now${C_N}  ${C_D}(切: proxy node use <序号或子串>)${C_N}"
    local i=1 n
    while IFS= read -r n; do printf '%2d) %s\n' "$((i++))" "$n"; done < <(_node_members "$g")
}

# test every node in a group for latency; prints sorted ascending, then
# offers interactive node selection so the user can switch immediately.
node_test() {
    json_guard
    ctrl_require
    local g url timeout
    g=${1:-$(node_group)}
    [[ -n "$g" ]] || die "未找到节点组"
    url=$(conf_get test_url); url=${url:-https://www.google.com}
    timeout=$(conf_get test_timeout); timeout=${timeout:-5000}
    info "测延迟 (group=$g, url=$url, timeout=${timeout}ms) ..."

    # collect node names, then test in batches of 20 concurrent requests
    # (each delay test is a controller call; mihomo runs them in parallel, so a
    # batch takes ~one timeout instead of 20×timeout)
    local nodes=() results=() n
    while IFS= read -r n; do nodes+=("$n"); done < <(_node_members "$g")

    local BATCH=20 idx=0
    while (( idx < ${#nodes[@]} )); do
        local tmp; tmp=$(mktemp -d)
        local pids=() j=0 nn
        for nn in "${nodes[@]:idx:BATCH}"; do
            ( local ms
              ms=$(ctrl_get "/proxies/$(jq_uri "$nn")/delay?url=${url}&timeout=${timeout}" 2>/dev/null \
                   | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('delay',''))" 2>/dev/null)
              printf '%s\t%s\n' "${ms:-FAIL}" "$nn" > "$tmp/$j"
            ) &
            pids+=($!); j=$((j+1))
        done
        local pid
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null; done
        local f
        for f in "$tmp"/*; do
            [[ -f "$f" ]] || continue
            IFS=$'\t' read -r ms nn < "$f"
            if [[ "$ms" != "FAIL" && -n "$ms" ]]; then
                results+=("$(printf '%06d %s' "$ms" "$nn")")
            else
                results+=("$(printf '999999 %s' "$nn")")
            fi
        done
        rm -rf "$tmp"
        idx=$((idx + BATCH))
    done

    (( ${#results[@]} > 0 )) || { warn "无可用节点"; return 1; }

    # print sorted ascending, numbered
    local sorted sorted_lines i
    mapfile -t sorted_lines < <(printf '%s\n' "${results[@]}" | sort -n)
    i=1
    for line in "${sorted_lines[@]}"; do
        local raw_ms node_name
        raw_ms=$(printf '%s' "$line" | awk '{print $1}')
        node_name=$(printf '%s' "$line" | cut -d' ' -f2-)
        if [[ "$raw_ms" == "999999" ]]; then
            printf '%2d) %6s     %s\n' "$((i++))" "x" "$node_name"
        else
            printf '%2d) %6s ms  %s\n' "$((i++))" "$((10#$raw_ms))" "$node_name"
        fi
    done

    # offer interactive selection (only when connected to a terminal)
    if [[ -t 0 ]]; then
        say ""
        local choice chosen_name
        printf '选择节点序号 (Enter 跳过, q 取消): ' >&2
        read -r choice </dev/tty 2>/dev/null || { info "跳过"; return 0; }
        if [[ -z "$choice" ]]; then
            info "跳过"
            return 0
        fi
        [[ "$choice" == "q" || "$choice" == "Q" ]] && { info "取消"; return 0; }
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sorted_lines[@]} )); then
            # extract the actual node name from the sorted list (display order matches sorted_lines)
            chosen_name=$(printf '%s' "${sorted_lines[$((choice-1))]}" | cut -d' ' -f2-)
            node_use "$chosen_name"
        else
            warn "无效序号: $choice (范围 1-${#sorted_lines[@]})"
        fi
    fi
}

# numbered menu over given names (array); prints chosen name to stdout
_pick_from() {
    local i arr=("$@")
    for i in "${!arr[@]}"; do printf '%2d) %s\n' "$((i+1))" "${arr[$i]}" >&2; done
    local n
    printf '选择 [#] (q 取消): ' >&2
    read -r n </dev/tty 2>/dev/null || return 1
    [[ "$n" == q || "$n" == Q ]] && return 1
    [[ "$n" =~ ^[0-9]+$ ]] || return 1
    (( n >= 1 && n <= ${#arr[@]} )) || return 1
    printf '%s' "${arr[$((n-1))]}"
}

# interactive pick from a group's members; prints chosen name to stdout
_pick_interactive() {
    local g=$1
    mapfile -t m < <(_node_members "$g")
    (( ${#m[@]} > 0 )) || return 1
    if has fzf; then
        printf '%s\n' "${m[@]}" | fzf --prompt="节点($g)> " --height=40% --reverse --info=inline 2>/dev/null
    else
        _pick_from "${m[@]}"
    fi
}

node_use() {
    json_guard
    ctrl_require
    local name=$1 g
    g=$(node_group)
    [[ -n "$g" ]] || die "未找到节点组"

    if [[ -z "$name" ]]; then
        # no arg -> interactive (fzf or numbered menu)
        name=$(_pick_interactive "$g") || { info "取消"; return 0; }
    elif [[ "$name" =~ ^[0-9]+$ ]]; then
        # numeric -> by 1-based index in node-list order
        mapfile -t m < <(_node_members "$g")
        (( name >= 1 && name <= ${#m[@]} )) || die "序号超出范围 (1-${#m[@]}); 运行 proxy node list"
        name="${m[$((name-1))]}"
    else
        # substring match (case-insensitive, fixed string)
        mapfile -t hits < <(_node_members "$g" | grep -iF -- "$name")
        case ${#hits[@]} in
            0) die "无节点匹配 '$name' (运行 proxy node list 看可选名)";;
            1) name="${hits[0]}";;
            *) info "多个节点匹配 '$name', 选一个:"
               name=$(_pick_from "${hits[@]}") || { info "取消"; return 0; }
               ;;
        esac
    fi

    local code; code=$(ctrl_put "/proxies/$(jq_uri "$g")" "{\"name\":\"$name\"}")
    case "$code" in
        204|200) ok "已切换: $name (组 $g)" ;;
        *) die "切换失败 (HTTP $code)。节点名是否正确？运行 proxy node list" ;;
    esac
}
