# shellcheck shell=bash
# proxy/lib/menu.sh — Interactive console menu for quick management.

proxy_menu() {
    json_guard
    while true; do
        local pid up=0 ver="" envstate tun now g asub
        # shellcheck source=service.sh
        source "$SCRIPT_DIR/lib/service.sh"
        pid=$(svc_pid 2>/dev/null)
        if [[ -n "$pid" ]] && ctrl_up; then
            up=1
            ver=$(ctrl_get /version 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin).get('version',''))" 2>/dev/null)
            g=$(node_group 2>/dev/null)
            if [[ -n "$g" ]]; then
                now=$(ctrl_get "/proxies/$(jq_uri "$g")" 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('now',''))" 2>/dev/null)
            fi
        fi
        envstate=$(cat "$ENV_STATE" 2>/dev/null)
        asub=$(conf_get active_sub 2>/dev/null)

        say ""
        say "${C_B}${C_Y}=== proxy 快捷交互面板 ===${C_N}"
        if (( up )); then
            say "核心状态: ${C_G}● 运行中${C_N} (pid $pid · ${ver:-mihomo})  |  出口节点: ${C_G}${now:-未选}${C_N}"
        else
            say "核心状态: ${C_R}○ 未运行${C_N}  |  出口节点: -"
        fi
        say "代理环境: $( [[ "$envstate" == "on" ]] && printf '%son (开启)%s' "$C_G" "$C_N" || printf '%soff (关闭)%s' "$C_D" "$C_N" )  |  活跃订阅: ${asub:-default}"
        say "${C_D}──────────────────────────────────────────${C_N}"
        say "  ${C_B}1)${C_N} 🚀 切换出口节点     (proxy use)"
        say "  ${C_B}2)${C_N} ⚡ 节点延迟测速     (proxy test)"
        say "  ${C_B}3)${C_N} 🔄 切换终端代理环境 ($( [[ "$envstate" == "on" ]] && echo "当前: 开启 -> 点击关闭" || echo "当前: 关闭 -> 点击开启" ))"
        say "  ${C_B}4)${C_N} 📦 刷新/管理订阅    (proxy refresh / sub)"
        say "  ${C_B}5)${C_N} 🔍 连通性测试与诊断 (proxy check)"
        say "  ${C_B}6)${C_N} 📊 实时流量监控     (proxy monitor)"
        say "  ${C_B}7)${C_N} ⚙️ 服务启停与重载   (proxy start / stop / restart)"
        say "  ${C_B}8)${C_N} 🌐 地区分组预设     (proxy region preset)"
        say "  ${C_B}0)${C_N} 退出"
        say ""

        local opt
        printf '请选择操作 [0-8] (q 退出): ' >&2
        read -r opt </dev/tty 2>/dev/null || return 0
        case "$opt" in
            1)
                # shellcheck source=node.sh
                source "$SCRIPT_DIR/lib/node.sh"
                node_use ;;
            2)
                # shellcheck source=node.sh
                source "$SCRIPT_DIR/lib/node.sh"
                node_test ;;
            3)
                # shellcheck source=env.sh
                source "$SCRIPT_DIR/lib/env.sh"
                env_cmd toggle ;;
            4)
                # shellcheck source=sub.sh
                source "$SCRIPT_DIR/lib/sub.sh"
                say ""
                say "1) 刷新当前活跃订阅"
                say "2) 切换活跃订阅"
                say "3) 查看订阅列表"
                printf '请选择 [1-3] (q 返回): ' >&2
                local sopt
                read -r sopt </dev/tty 2>/dev/null
                case "$sopt" in
                    1) sub_refresh ;;
                    2) sub_use ;;
                    3) sub_list ;;
                    *) ;;
                esac
                ;;
            5)
                # shellcheck source=check.sh
                source "$SCRIPT_DIR/lib/check.sh"
                proxy_check ;;
            6)
                # shellcheck source=monitor.sh
                source "$SCRIPT_DIR/lib/monitor.sh"
                monitor_cmd ;;
            7)
                # shellcheck source=service.sh
                source "$SCRIPT_DIR/lib/service.sh"
                say ""
                say "1) 启动 mihomo (start)"
                say "2) 停止 mihomo (stop)"
                say "3) 重启 mihomo (restart)"
                say "4) 查看最近日志 (log)"
                printf '请选择 [1-4] (q 返回): ' >&2
                local copt
                read -r copt </dev/tty 2>/dev/null
                case "$copt" in
                    1) svc_start ;;
                    2) svc_stop ;;
                    3) svc_restart ;;
                    4) svc_log -n 30 ;;
                    *) ;;
                esac
                ;;
            8)
                # shellcheck source=region.sh
                source "$SCRIPT_DIR/lib/region.sh"
                region_preset ;;
            0|q|Q|exit)
                return 0 ;;
            *)
                warn "无效选项: $opt"
                ;;
        esac
        say ""
        printf '%s按 Enter 键返回菜单 (q 退出): %s' "${C_D}" "${C_N}" >&2
        local cont
        read -r cont </dev/tty 2>/dev/null || return 0
        [[ "$cont" == "q" || "$cont" == "Q" ]] && return 0
    done
}
