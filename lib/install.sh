# shellcheck shell=bash
# proxy/lib/install.sh — tiered install, config bootstrap, .bashrc hook, lifecycle.
# Install order, per the user's requirement: detect an existing mihomo first,
# then brew (if available and the formula exists), then fall back to a GitHub
# release download (arch-aware). Never assumes the binary already exists.

# --- tier-3: download the right GitHub asset for this arch/cpu ---
install_github() {
    local arch var tag ver api asset url bindest=/tmp/mihomo.gz
    arch=$(detect_arch)
    case "$arch" in
        amd64)
            var=$(detect_amd64_variant)
            if [[ "$var" == "v3" ]]; then pat="mihomo-linux-amd64-v%s.gz"
            else pat="mihomo-linux-amd64-compatible-v%s.gz"; fi ;;
        arm64) pat="mihomo-linux-arm64-v%s.gz" ;;
        armv7) pat="mihomo-linux-armv7-v%s.gz" ;;
        *) die "暂不支持自动下载 arch=$arch; 用 proxy install --bin <path>" ;;
    esac
    info "查询 GitHub 最新 release ..."
    api=$(curl -fsSL --max-time 20 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null) \
        || die "无法访问 GitHub API (网络/被墙? 可先设代理或用 --via brew)"
    tag=$(printf '%s' "$api" | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
    [[ -n "$tag" ]] || die "解析 release tag 失败"
    ver=${tag#v}; asset=$(printf "$pat" "$ver")
    url="https://github.com/MetaCubeX/mihomo/releases/download/$tag/$asset"
    bindest="$HOME/.local/bin/mihomo"
    info "下载 $url"
    curl -fSL --max-time 180 -o /tmp/mihomo.gz "$url" || die "下载失败"
    mkdir -p "$(dirname "$bindest")"
    gunzip -f /tmp/mihomo.gz || die "解压失败"
    mv /tmp/mihomo "$bindest"; chmod +x "$bindest"
    printf '%s' "$bindest"
}

# --- tier-2: brew (formula exists in homebrew-core) ---
install_brew() {
    has brew || return 1
    brew info mihomo >/dev/null 2>&1 || return 1
    info "brew install mihomo ..."
    brew install mihomo || die "brew install 失败"
    command -v mihomo 2>/dev/null || printf '%s' "$HOME/.brew/bin/mihomo"
}

proxy_install() {
    local via= bin=
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bin) bin="$2"; shift 2 ;;
            --via) via="$2"; shift 2 ;;
            -h|--help) say "用法: proxy install [--bin PATH] [--via brew|github|gz:FILE]"; return 0 ;;
            *) die "proxy install: 未知参数 $1" ;;
        esac
    done
    mkdir -p "$CONF_DIR"

    if [[ -n "$bin" ]]; then
        [[ -x "$bin" ]] || die "指定的二进制不可执行: $bin"
        conf_set bin "$bin"; conf_set install_method manual
    elif [[ "$via" == gz:* ]]; then
        local gz="${via#gz:}"; [[ -f "$gz" ]] || die "gz 文件不存在: $gz"
        local bindest="$HOME/.local/bin/mihomo"; mkdir -p "$(dirname "$bindest")"
        gunzip -c "$gz" > "$bindest" || die "解压失败"; chmod +x "$bindest"
        conf_set bin "$bindest"; conf_set install_method gz
    elif [[ "$via" == brew ]]; then
        local b; b=$(install_brew) || die "brew 安装失败"
        conf_set bin "$b"; conf_set install_method brew
    elif [[ "$via" == github ]]; then
        local b; b=$(install_github); conf_set bin "$b"; conf_set install_method github
    else
        # auto tiered: existing -> github -> brew
        local found b
        if found=$(mihomo_bin 2>/dev/null) && [[ -x "$found" ]]; then
            info "已检测到 mihomo: $found"; conf_set bin "$found"; conf_set install_method existing
        elif b=$(install_github 2>/dev/null); then
            conf_set bin "$b"; conf_set install_method github
        elif install_brew >/dev/null 2>&1; then
            b=$(command -v mihomo 2>/dev/null || printf '%s' "$HOME/.brew/bin/mihomo")
            conf_set bin "$b"; conf_set install_method brew
        else
            die "自动安装失败: 无法通过 GitHub 或 Brew 下载安装 mihomo"
        fi
    fi
    proxy_init
}

proxy_init() {
    local bin; bin=$(conf_get bin)
    [[ -n "$bin" && -x "$bin" ]] || die "未设置 mihomo 二进制 (先 proxy install)"
    mkdir -p "$CONF_DIR"

    local first=0
    if [[ ! -f "$CONFIG" ]]; then
        first=1
        info "初始化 config.yaml (来自模板)"
        if [[ -f "$SCRIPT_DIR/templates/config.minimal.yaml" ]]; then
            cp "$SCRIPT_DIR/templates/config.minimal.yaml" "$CONFIG"
        else
            printf 'mixed-port: 7890\nexternal-controller: 127.0.0.1:9090\nrules:\n- MATCH,DIRECT\n' > "$CONFIG"
        fi
        if [[ -t 0 ]]; then
            local sub
            printf '[proxy] 粘贴订阅链接 (可留空跳过, 之后用 proxy sub add <name> <url>): '
            read -r sub
            [[ -n "$sub" ]] && conf_set sub_url "$sub"
        fi
    fi

    [[ -z "$(conf_get controller)" ]] && conf_set controller 127.0.0.1:9090
    install_symlink
    bashrc_hook_install
    if mihomo_test "$CONFIG"; then ok "配置校验通过"; else warn "配置校验未通过; 检查 $CONFIG"; fi

    # first-time init: if a subscription URL was given, pull it now so the config
    # is populated and mihomo starts in one shot (refresh starts it if down).
    if (( first )) && { [[ -n "$(conf_get sub_url)" ]] || [[ -f "$CONF_DIR/subs.conf" ]]; }; then
        info "首次初始化, 拉取订阅并启动 ..."
        ( source "$SCRIPT_DIR/lib/sub.sh"; sub_refresh ) || warn "订阅拉取未成功; 之后可: proxy sub refresh"
    else
        ok "完成。启动: proxy start   开当前 shell 代理: eval \"\$(proxy env show)\""
    fi
}

install_symlink() {
    mkdir -p "$HOME/.local/bin"
    ln -sfn "$SCRIPT_DIR/proxy" "$HOME/.local/bin/proxy"
    info "已链接 ~/.local/bin/proxy -> $SCRIPT_DIR/proxy"
}

bashrc_hook_install() {
    local rcs=("$HOME/.bashrc")
    [[ -f "$HOME/.zshrc" || "$SHELL" == *"zsh"* ]] && rcs+=("$HOME/.zshrc")

    local hook
    hook=$(cat <<EOF

# >>> proxy (auto) >>>
proxy() {
    if [[ "\$1" == "env" && ( "\$2" == "on" || "\$2" == "off" ) ]]; then
        "$SCRIPT_DIR/proxy" "\$@"
        eval "\$( "$SCRIPT_DIR/proxy" env show )"
    else
        "$SCRIPT_DIR/proxy" "\$@"
    fi
}
[[ \$- == *i* ]] && [ -f "\$HOME/.config/mihomo/env.state" ] && [ "\$(cat "\$HOME/.config/mihomo/env.state" 2>/dev/null)" = "on" ] && [ -x "$SCRIPT_DIR/proxy" ] && eval "\$( "$SCRIPT_DIR/proxy" _login 2>/dev/null )"
# <<< proxy (auto) <<<
EOF
)

    local rc
    for rc in "${rcs[@]}"; do
        touch "$rc"
        if grep -q '^# >>> proxy (auto) >>>' "$rc" 2>/dev/null; then
            python3 - "$rc" "$hook" <<'PY'
import sys, re
rc, hook = sys.argv[1], sys.argv[2]
t = open(rc).read()
t = re.sub(r'\n?# >>> proxy \(auto\) >>>.*?# <<< proxy \(auto\) <<<\n?', hook, t, flags=re.S)
open(rc, 'w').write(t)
PY
        else
            printf '%s\n' "$hook" >> "$rc"
        fi
        info "已管理 $rc 钩子 (proxy 函数包装 + 登录自启 + 0 毫秒启动优化)"
    done
}

bashrc_hook_remove() {
    local rcs=("$HOME/.bashrc" "$HOME/.zshrc")
    local rc
    for rc in "${rcs[@]}"; do
        [[ -f "$rc" ]] || continue
        python3 - "$rc" <<'PY'
import sys, re
rc = sys.argv[1]
t = open(rc).read()
t = re.sub(r'\n?# >>> proxy \(auto\) >>>.*?# <<< proxy \(auto\) <<<\n?', '\n', t, flags=re.S)
open(rc, 'w').write(t)
PY
        info "已从 $rc 移除 proxy 钩子"
    done
}

proxy_doctor() { detect_all; }

proxy_upgrade() {
    local m; m=$(conf_get install_method)
    case "$m" in
        brew) brew upgrade mihomo ;;
        github|gz) local b; b=$(install_github); conf_set bin "$b" ;;
        existing|manual) warn "当前二进制非本工具安装 (method=$m); 用 proxy install --via github 重装" ;;
        *) die "未知 install_method=$m (先 proxy install)" ;;
    esac
    ok "升级流程完成"
}

proxy_uninstall() {
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    bashrc_hook_remove
    rm -f "$HOME/.local/bin/proxy"
    info "已移除 .bashrc 钩子与软链; 配置目录 $CONF_DIR 保留"
    local a=n
    if [[ -t 0 ]]; then
        read -r -p "[proxy] 同时停止 mihomo 并删除二进制 $(conf_get bin)? [y/N] " a
    fi
    if [[ "$a" == y || "$a" == Y ]]; then
        svc_stop >/dev/null 2>&1
        rm -f "$(conf_get bin)"
        ok "已停止并删除二进制"
    fi
}
