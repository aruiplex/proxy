# shellcheck shell=bash
# proxy/lib/check.sh — proxy environment and connectivity check.

proxy_check() {
    local os_type ip envstate tun_state pid running=0 test_url code time_ms
    os_type=$(uname -s)
    
    say "${C_B}--- Proxy Status & Diagnostics ($os_type) ---${C_N}"
    
    # 1. Check Core & Node State
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    pid=$(svc_pid 2>/dev/null)
    if [[ -n "$pid" ]] && ctrl_up; then
        running=1
        local g now
        g=$(node_group 2>/dev/null)
        [[ -n "$g" ]] && now=$(ctrl_get "/proxies/$(jq_uri "$g")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
        ok "核心运行状态:   ✅ 运行中 (pid $pid · 节点: ${now:-未选})"
    elif [[ -n "$pid" ]]; then
        running=1
        warn "核心运行状态:   ⚠️ 运行中 (pid $pid) 但控制器无响应"
    else
        warn "核心运行状态:   ❌ 未运行 (运行 proxy start 启动)"
    fi

    # 2. Check System & Environment Settings
    envstate=$(cat "$ENV_STATE" 2>/dev/null)
    tun_state=$(awk '/^tun:/{f=1} f&&/enable:/{print;exit}' "$CONFIG" 2>/dev/null | grep -o 'true\|false')
    
    if [[ "$tun_state" == "true" ]]; then
        ok "透明 TUN:        ✅ 开启 (系统全局流量托管)"
    else
        info "透明 TUN:        ⚪ 关闭"
    fi

    if [[ -n "$http_proxy" || -n "$HTTP_PROXY" ]]; then
        ok "Shell 代理环境:  ✅ 已生效 (http_proxy=${http_proxy:-$HTTP_PROXY})"
    elif [[ "$envstate" == "on" ]]; then
        warn "Shell 代理环境:  ⚠️ 已配置为 on 但当前 Shell 尚未载入 (在新终端生效或执行 proxy on)"
    else
        info "Shell 代理环境:  ⚪ 未开启 (可执行 proxy on 开启当前终端代理)"
    fi

    # 3. Connectivity Test
    printf "外网连通性测试:  "
    local success=0 test_urls=("https://www.google.com/generate_204" "https://cloudflare.com" "https://youtube.com")
    for test_url in "${test_urls[@]}"; do
        local raw
        raw=$(curl -o /dev/null -s -w '%{http_code} %{time_total}' --connect-timeout 3 --max-time 6 "$test_url" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            read -r code time_ms <<< "$raw"
            if [[ -n "$code" && "$code" != "000" ]]; then
                success=1
                break
            fi
        fi
    done

    if (( success )); then
        ip=$(curl -fsS --connect-timeout 2 --max-time 4 https://ifconfig.me/ip 2>/dev/null)
        local ms_fmt
        ms_fmt=$(python3 -c "import sys; print(int(float(sys.argv[1])*1000))" "$time_ms" 2>/dev/null || echo "$time_ms")
        if [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
            ok "✅ 连通正常 (${ms_fmt}ms · 出口 IP: $ip)"
        else
            ok "✅ 连通正常 (${ms_fmt}ms)"
        fi
    else
        warn "❌ 测试失败 (连接超时或被拒绝)"
        say ""
        say "${C_B}${C_Y}💡 故障排查建议:${C_N}"
        if (( ! running )); then
            say "  1. mihomo 核心未启动 👉 运行: ${C_B}proxy start${C_N}"
        elif [[ "$envstate" != "on" && "$tun_state" != "true" && -z "$http_proxy" ]]; then
            say "  1. 核心已在运行，但当前 Shell 未开启代理环境 👉 运行: ${C_B}proxy on${C_N} (或开启 TUN: ${C_B}proxy tun on${C_N})"
        else
            say "  1. 节点可能超时或不可用 👉 运行测速选择: ${C_B}proxy test${C_N} 或 ${C_B}proxy use${C_N}"
            say "  2. 查看核心运行日志排查 👉 运行: ${C_B}proxy log -n 20${C_N}"
        fi
    fi
    say "${C_D}──────────────────────────────────────────${C_N}"
}
