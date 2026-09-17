# shellcheck shell=bash
# proxy/lib/detect.sh — environment probing. Never assumes anything; probes first.
# Sourced by main entry (always), since detection underlies every command.

# print the mihomo binary path + version if found; silent + return 1 if not.
detect_bin() {
    local bin
    bin=$(mihomo_bin) || return 1
    printf '%s' "$bin"
}

# CPU architecture as mihomo asset suffix: amd64 | arm64 | 386 | armv7 ...
detect_arch() {
    local m
    m=$(uname -m 2>/dev/null)
    case "$m" in
        x86_64|amd64)  printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        i?86)          printf '386' ;;
        armv7l)        printf 'armv7' ;;
        *) printf '%s' "$m" ;;
    esac
}

# Whether this amd64 CPU supports the v3 microarch (AVX2 + ...). Used to pick the
# right GitHub asset; unsupported CPUs must use the 'compatible' build.
detect_amd64_variant() {
    [[ "$(detect_arch)" == "amd64" ]] || { printf 'compatible'; return; }
    if [[ -r /proc/cpuinfo ]]; then
        local flags need
        flags=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null)
        for need in avx avx2 bmi1 bmi2 f16c fma movbe xsave; do
            printf '%s' "$flags" | grep -qw "$need" || { printf 'compatible'; return; }
        done
        printf '%s' "$flags" | grep -Eqw 'abm|lzcnt' || { printf 'compatible'; return; }
        printf 'v3'; return
    fi
    printf 'compatible'
}

# sudo capability: 'none' | 'password' | 'nopasswd'
detect_sudo() {
    [[ $(id -u) -eq 0 ]] && { printf 'root'; return; }
    has sudo || { printf 'none'; return; }
    sudo -n true 2>/dev/null && { printf 'nopasswd'; return; } || { printf 'password'; return; }
}

# JSON tool available? 'python3' | 'jq' | 'none'
detect_json() {
    has jq && { printf 'jq'; return; }
    has python3 && { printf 'python3'; return; }
    printf 'none'
}

# does a usable config.yaml already exist?
detect_existing_config() {
    [[ -f "$CONFIG" ]] || return 1
    grep -qE '^(mixed-port|port|socks-port|external-controller):' "$CONFIG" 2>/dev/null
}

# is mihomo currently running (our instance or any)?
detect_running() {
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    svc_pid >/dev/null 2>&1
}

detect_all() {
    local bin arch sudo json run bininfo ctrl_status asub envstate
    bin=$(detect_bin 2>/dev/null) && bininfo=$("$bin" -v 2>/dev/null | head -1) || bininfo='-'
    arch=$(detect_arch); [[ "$arch" == "amd64" ]] && arch="$arch/$(detect_amd64_variant)"
    sudo=$(detect_sudo); json=$(detect_json)
    detect_running && run=1 || run=0
    ctrl_get /version >/dev/null 2>&1 && ctrl_status=1 || ctrl_status=0
    asub=$(conf_get active_sub)
    envstate=$(cat "$ENV_STATE" 2>/dev/null)

    say "${C_B}${C_Y}=== proxy 环境体检 (Doctor) ===${C_N}"
    
    # 1. Binary & Environment
    if [[ -n "$bin" && -x "$bin" ]]; then
        ok "  核心二进制:    ✅ $bin (${bininfo:-ok})"
    else
        warn "  核心二进制:    ❌ 未找到 (运行 proxy install 安装)"
    fi
    say "  系统架构:      $arch  (sudo 权限: $sudo, JSON 工具: $json)"

    # 2. Config & Files
    if detect_existing_config; then
        ok "  配置文件:      ✅ config.yaml 就绪"
    else
        warn "  配置文件:      ❌ config.yaml 缺失 (运行 proxy init)"
    fi
    say "  持久化状态:    proxy.conf $([[ -f "$PROXY_CONF" ]] && echo "✅" || echo "⚪")  |  merge.yaml $([[ -f "$MERGE_FILE" ]] && echo "✅" || echo "⚪")  |  subs.conf $([[ -f "$CONF_DIR/subs.conf" ]] && echo "✅" || echo "⚪")"
    if [[ "$(conf_get pool)" == "on" ]]; then
        local sub_files=("$POOL_STATE_DIR"/*.prox)
        local pool_sub_cnt=0 pool_node_cnt=0
        if [[ -f "${sub_files[0]}" ]]; then
            pool_sub_cnt=${#sub_files[@]}
            pool_node_cnt=$(grep -chE '^[ \t]+- ' "${sub_files[@]}" 2>/dev/null | awk '{s+=$1} END{print s}')
        fi
        ok "  订阅模式:      ✅ 节点池 (pool on · 聚合 ${pool_sub_cnt} 个订阅 / ${pool_node_cnt:-0} 节点)"
    elif [[ -n "$asub" ]]; then
        say "  当前活跃订阅:  $asub (单订阅模式)"
    fi

    # 3. Runtime & Controller
    if (( run )); then
        ok "  运行状态:      ✅ mihomo 进程在运行 (pid $(svc_pid 2>/dev/null))"
    else
        info "  运行状态:      ⚪ 未运行 (运行 proxy start 启动)"
    fi

    if (( ctrl_status )); then
        ok "  控制器接口:    ✅ http://$(controller_addr) 响应正常"
    elif (( run )); then
        warn "  控制器接口:    ❌ http://$(controller_addr) 无法访问 (检查端口或 secret)"
    else
        info "  控制器接口:    ⚪ http://$(controller_addr) (等待核心启动)"
    fi

    # 4. Proxy Env
    if [[ "$envstate" == "on" ]]; then
        ok "  终端代理环境:  ✅ on (已开启)"
    else
        info "  终端代理环境:  ⚪ off (已关闭)"
    fi
    say "${C_D}──────────────────────────────────────────${C_N}"
}
