# shellcheck shell=bash
# proxy/lib/node.sh — exit-node management via the controller API.
# Picking is convenient: `node list` numbers nodes; `node use` accepts a
# number, a substring (unique->switch, ambiguous->menu), or nothing (interactive:
# fzf if available, else a numbered menu).

node_cmd() {
    local sub=${1:-}; shift || true
    case "$sub" in
        list|ls) node_list "$@" ;;
        test)    node_test "$@" ;;
        use)     node_use "$@" ;;
        "")      if [[ -t 0 ]]; then node_use "$@"; else say "用法: proxy node list | test [GROUP] | use [<#|子串>]   (无参=交互选择)"; fi ;;
        -h|--help) say "用法: proxy node list | test [GROUP] | use [<#|子串>]   (快捷指令: proxy use / proxy test / proxy ls)" ;;
        *) die "proxy node: 未知子命令 $sub" ;;
    esac
}

_resolve_group() {
    local target=$1
    if [[ -z "$target" ]]; then
        node_group
        return
    fi
    local all_groups
    all_groups=$(ctrl_get /proxies 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for n, v in d.get('proxies', {}).items():
        if v.get('type') in ('Selector', 'URLTest', 'Fallback', 'Select'):
            print(n)
except Exception:
    pass
" 2>/dev/null)
    # 1. exact match (case-insensitive)
    if printf '%s\n' "$all_groups" | grep -qxi "$target"; then
        printf '%s\n' "$all_groups" | grep -xi "$target" | head -1
        return
    fi
    # 2. alias resolution
    local code=""
    case "$(printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" in
        auto|自动) code="AUTO" ;;
        hk|hongkong|香港) code="HK-Auto" ;;
        sg|singapore|新加坡) code="SG-Auto" ;;
        jp|japan|日本) code="JP-Auto" ;;
        us|usa|america|美国) code="US-Auto" ;;
        tw|taiwan|台湾) code="TW-Auto" ;;
        kr|korea|韩国) code="KR-Auto" ;;
        uk|gb|london|英国) code="UK-Auto" ;;
        de|germany|德国) code="DE-Auto" ;;
        fr|france|法国) code="FR-Auto" ;;
        ca|canada|加拿大) code="CA-Auto" ;;
        au|australia|澳大利亚) code="AU-Auto" ;;
        nl|netherlands|荷兰) code="NL-Auto" ;;
    esac
    if [[ -n "$code" ]] && printf '%s\n' "$all_groups" | grep -qx "$code"; then
        printf '%s' "$code"
        return
    fi
    # 3. substring match
    local match
    match=$(printf '%s\n' "$all_groups" | grep -iF "$target" | head -1)
    if [[ -n "$match" ]]; then
        printf '%s' "$match"
        return
    fi
    printf '%s' "$target"
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
    g=$(_resolve_group "${1:-}")
    [[ -n "$g" ]] || die "config.yaml 里没有 Selector/URLTest 节点组 (订阅是否含 proxy-groups? proxy sub refresh 后 proxy restart)"
    local now
    now=$(ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
    say "${C_B}组: $g${C_N}  当前: ${C_G}$now${C_N}  ${C_D}(切: proxy use <序号/子串> 或 proxy use 交互选择)${C_N}"
    local i=1 n
    while IFS= read -r n; do
        if [[ "$n" == "$now" ]]; then
            printf '%s* %2d) %s  [当前]%s\n' "${C_G}${C_B}" "$i" "$n" "${C_N}"
        else
            printf '  %2d) %s\n' "$i" "$n"
        fi
        i=$((i+1))
    done < <(_node_members "$g")
}

# test every node in a group for latency; prints sorted ascending, then
# offers interactive node selection so the user can switch immediately.
node_test() {
    json_guard
    ctrl_require
    local g url timeout encoded_url now
    g=$(_resolve_group "${1:-}")
    [[ -n "$g" ]] || die "未找到节点组"
    now=$(ctrl_get "/proxies/$(jq_uri "$g")" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
    url=$(conf_get test_url); url=${url:-https://www.google.com}
    timeout=$(conf_get test_timeout); timeout=${timeout:-5000}
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || die "test_timeout 必须是正整数毫秒"
    encoded_url=$(jq_uri "$url")
    info "测延迟 (组: $g, 目标: $url, 超时: ${timeout}ms) ..."

    # collect node names, then test in batches of 20 concurrent requests
    # (each delay test is a controller call; mihomo runs them in parallel, so a
    # batch takes ~one timeout instead of 20×timeout)
    local nodes=() results=() n
    while IFS= read -r n; do nodes+=("$n"); done < <(_node_members "$g")

    local BATCH=20 idx=0 total=${#nodes[@]}
    while (( idx < total )); do
        local count_end=$(( idx + BATCH ))
        (( count_end > total )) && count_end=$total
        printf "\r${C_D}正在测速 [%d/%d] ...${C_N}" "$count_end" "$total" >&2
        local tmp; tmp=$(mktemp -d) || die "无法创建延迟测试临时目录"
        local pids=() j=0 nn
        for nn in "${nodes[@]:idx:BATCH}"; do
            ( local ms
              ms=$(ctrl_get "/proxies/$(jq_uri "$nn")/delay?url=${encoded_url}&timeout=${timeout}" 2>/dev/null \
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
    printf "\r\033[K" >&2

    (( ${#results[@]} > 0 )) || { warn "无可用节点"; return 1; }

    # print sorted ascending, numbered
    local sorted_lines=() line i
    while IFS= read -r line; do sorted_lines+=("$line"); done \
        < <(printf '%s\n' "${results[@]}" | sort -n)
    i=1
    for line in "${sorted_lines[@]}"; do
        local raw_ms node_name ms_val is_current=""
        raw_ms=$(printf '%s' "$line" | awk '{print $1}')
        node_name=$(printf '%s' "$line" | cut -d' ' -f2-)
        [[ "$node_name" == "$now" ]] && is_current=" ${C_G}[当前]${C_N}"
        if [[ "$raw_ms" == "999999" ]]; then
            printf '  %2d) %s%7s%s     %s%s\n' "$i" "${C_D}" "Timeout" "${C_N}" "$node_name" "$is_current"
        else
            ms_val=$((10#$raw_ms))
            local c_ms="$C_G"
            if (( ms_val > 500 )); then c_ms="$C_R"
            elif (( ms_val > 200 )); then c_ms="$C_Y"
            fi
            printf '  %2d) %s%6s ms%s  %s%s\n' "$i" "$c_ms" "$ms_val" "${C_N}" "$node_name" "$is_current"
        fi
        i=$((i+1))
    done

    # offer interactive selection (only when connected to a terminal)
    if [[ -t 0 ]]; then
        say ""
        local chosen_name=""
        if has fzf; then
            local fzf_list=()
            for line in "${sorted_lines[@]}"; do
                local raw_ms node_name
                raw_ms=$(printf '%s' "$line" | awk '{print $1}')
                node_name=$(printf '%s' "$line" | cut -d' ' -f2-)
                if [[ "$raw_ms" == "999999" ]]; then
                    fzf_list+=("Timeout  |  $node_name")
                else
                    fzf_list+=("$(printf '%4d ms  |  %s' "$((10#$raw_ms))" "$node_name")")
                fi
            done
            local sel
            sel=$(printf '%s\n' "${fzf_list[@]}" | fzf --prompt="切换节点(按延迟排序)> " --height=40% --reverse --info=inline 2>/dev/null)
            if [[ -n "$sel" ]]; then
                chosen_name=$(printf '%s' "$sel" | sed 's/.*|  //')
                node_use "$chosen_name"
            fi
        else
            local choice
            printf '选择节点序号 (Enter 跳过, q 取消): ' >&2
            read -r choice </dev/tty 2>/dev/null || { info "跳过"; return 0; }
            if [[ -z "$choice" ]]; then
                info "跳过"
                return 0
            fi
            [[ "$choice" == "q" || "$choice" == "Q" ]] && { info "取消"; return 0; }
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sorted_lines[@]} )); then
                chosen_name=$(printf '%s' "${sorted_lines[$((choice-1))]}" | cut -d' ' -f2-)
                node_use "$chosen_name"
            else
                warn "无效序号: $choice (范围 1-${#sorted_lines[@]})"
            fi
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
    local m=() member
    while IFS= read -r member; do m+=("$member"); done < <(_node_members "$g")
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
        local m=() member
        while IFS= read -r member; do m+=("$member"); done < <(_node_members "$g")
        (( name >= 1 && name <= ${#m[@]} )) || die "序号超出范围 (1-${#m[@]}); 运行 proxy node list"
        name="${m[$((name-1))]}"
    else
        # 1. exact match (case-insensitive, e.g. 'auto' -> 'AUTO', 'jp01' -> 'JP01')
        local exact
        exact=$(_node_members "$g" | grep -xiF -- "$name" | head -1)
        if [[ -n "$exact" ]]; then
            name="$exact"
        else
            # 2. substring match (case-insensitive, fixed string)
            local hits=() hit
            while IFS= read -r hit; do hits+=("$hit"); done < <(_node_members "$g" | grep -iF -- "$name")
            case ${#hits[@]} in
                0) die "无节点匹配 '$name' (运行 proxy node list 看可选名)";;
                1) name="${hits[0]}";;
                *) info "多个节点匹配 '$name', 选一个:"
                   name=$(_pick_from "${hits[@]}") || { info "取消"; return 0; }
                   ;;
            esac
        fi
    fi

    local code body
    body="{\"name\":$(_json_quote "$name")}"
    code=$(ctrl_put "/proxies/$(jq_uri "$g")" "$body")
    case "$code" in
        204|200) ok "已切换: $name (组 $g)" ;;
        *) die "切换失败 (HTTP $code)。节点名是否正确？运行 proxy node list" ;;
    esac
}
