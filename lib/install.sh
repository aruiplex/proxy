# shellcheck shell=bash
# proxy/lib/install.sh — tiered install, config bootstrap, .bashrc hook, lifecycle.
# Install order: detect an existing mihomo first, then download a GitHub release,
# then fall back to brew. Never assumes the binary already exists.

# Decompress and validate before atomically replacing the destination. Writing
# directly to a running executable can fail with ETXTBSY, and a failed gunzip
# must not truncate a previously working binary.
_install_gz_file() {
    local gz=$1 bindest=$2 tmp version
    has gunzip || { warn "缺少依赖: gunzip"; return 1; }
    mkdir -p "$(dirname "$bindest")"
    tmp=$(mktemp "${bindest}.tmp.XXXXXX") || { warn "无法创建安装临时文件"; return 1; }
    if ! gunzip -c -- "$gz" > "$tmp"; then
        rm -f "$tmp"
        warn "解压失败: $gz"
        return 1
    fi
    chmod +x "$tmp" || { rm -f "$tmp"; warn "无法设置可执行权限"; return 1; }
    version=$("$tmp" -v 2>/dev/null) || version=
    if [[ "$version" != Mihomo\ Meta\ * ]]; then
        rm -f "$tmp"
        warn "压缩包不是当前系统可运行的 mihomo: $gz"
        return 1
    fi
    mv -f "$tmp" "$bindest" || { rm -f "$tmp"; warn "无法安装到 $bindest"; return 1; }
}

# --- tier-3: download the right GitHub asset for this arch/cpu ---
install_github() {
    local os arch var pat tag ver api asset url bindest tmpgz
    require python3
    os=$(uname -s 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$os" in linux|darwin) ;; *) die "暂不支持自动下载 os=$os; 用 proxy install --bin <path>" ;; esac
    arch=$(detect_arch)
    case "$arch" in
        amd64)
            var=$(detect_amd64_variant)
            if [[ "$var" == "v3" ]]; then pat="mihomo-${os}-amd64-v%s.gz"
            else pat="mihomo-${os}-amd64-compatible-v%s.gz"; fi ;;
        arm64) pat="mihomo-${os}-arm64-v%s.gz" ;;
        armv7)
            [[ "$os" == linux ]] || die "Darwin 不支持 armv7 自动安装"
            pat="mihomo-linux-armv7-v%s.gz" ;;
        *) die "暂不支持自动下载 arch=$arch; 用 proxy install --bin <path>" ;;
    esac
    info "查询 GitHub 最新 release ..." >&2
    api=$(curl -fsSL --max-time 20 https://api.github.com/repos/MetaCubeX/mihomo/releases/latest 2>/dev/null) \
        || die "无法访问 GitHub API (网络/被墙? 可先设代理或用 --via brew)"
    tag=$(printf '%s' "$api" | python3 -c "import sys,json;print(json.load(sys.stdin)['tag_name'])" 2>/dev/null)
    [[ -n "$tag" ]] || die "解析 release tag 失败"
    ver=${tag#v}; asset=$(printf "$pat" "$ver")
    url="https://github.com/MetaCubeX/mihomo/releases/download/$tag/$asset"
    bindest="$HOME/.local/bin/mihomo"
    tmpgz=$(mktemp "${TMPDIR:-/tmp}/mihomo.gz.XXXXXX") || die "无法创建下载临时文件"
    info "下载 $url" >&2
    curl -fSL --max-time 180 -o "$tmpgz" "$url" \
        || { rm -f "$tmpgz"; die "下载失败"; }
    _install_gz_file "$tmpgz" "$bindest" \
        || { rm -f "$tmpgz"; die "mihomo 安装失败"; }
    rm -f "$tmpgz"
    printf '%s' "$bindest"
}

# --- tier-2: brew (formula exists in homebrew-core) ---
install_brew() {
    has brew || return 1
    brew info mihomo >/dev/null 2>&1 || return 1
    info "brew install mihomo ..." >&2
    brew install mihomo >&2 || die "brew install 失败"
    command -v mihomo 2>/dev/null || printf '%s' "$HOME/.brew/bin/mihomo"
}

proxy_install() {
    local via= bin=
    require python3
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bin)
                [[ $# -ge 2 && -n "$2" ]] || die "--bin 缺少 PATH"
                bin="$2"; shift 2 ;;
            --via)
                [[ $# -ge 2 && -n "$2" ]] || die "--via 缺少安装方式"
                via="$2"; shift 2 ;;
            -h|--help) say "用法: proxy install [--bin PATH] [--via brew|github|gz:FILE]"; return 0 ;;
            *) die "proxy install: 未知参数 $1" ;;
        esac
    done
    mkdir -p "$CONF_DIR"

    if [[ -n "$bin" ]]; then
        bin="$(cd -P "$(dirname "$bin")" 2>/dev/null && pwd)/$(basename "$bin")"
        [[ -x "$bin" ]] || die "指定的二进制不可执行: $bin"
        [[ "$("$bin" -v 2>/dev/null)" == Mihomo\ Meta\ * ]] || die "指定文件不是可运行的 mihomo: $bin"
        conf_set bin "$bin"; conf_set install_method manual
    elif [[ "$via" == gz:* ]]; then
        local gz="${via#gz:}"; [[ -f "$gz" ]] || die "gz 文件不存在: $gz"
        local bindest="$HOME/.local/bin/mihomo"
        _install_gz_file "$gz" "$bindest" || die "mihomo 安装失败"
        conf_set bin "$bindest"; conf_set install_method gz
    elif [[ "$via" == brew ]]; then
        local b; b=$(install_brew) || die "brew 安装失败"
        conf_set bin "$b"; conf_set install_method brew
    elif [[ "$via" == github ]]; then
        local b
        b=$(install_github) || die "GitHub 安装失败"
        conf_set bin "$b"; conf_set install_method github
    elif [[ -n "$via" ]]; then
        [[ "$via" == gz ]] \
            && die "gz 安装需要指定文件: proxy install --via gz:/path/to/mihomo.gz"
        die "不支持的安装方式: $via (可选 brew|github|gz:FILE)"
    else
        # auto tiered: existing -> github -> brew
        local found b previous_bin previous_method
        if found=$(mihomo_bin 2>/dev/null) && [[ -x "$found" ]]; then
            previous_bin=$(conf_get bin); previous_method=$(conf_get install_method)
            info "已检测到 mihomo: $found"
            conf_set bin "$found"
            if [[ "$found" == "$previous_bin" && "$previous_method" =~ ^(github|gz|brew)$ ]]; then
                conf_set install_method "$previous_method"
            else
                conf_set install_method existing
            fi
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
    require python3
    local bin; bin=$(conf_get bin)
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        bin=$(mihomo_bin) || die "未设置 mihomo 二进制 (先 proxy install)"
        conf_set bin "$bin"
        [[ -n "$(conf_get install_method)" ]] || conf_set install_method existing
    fi
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

    if [[ -z "$(conf_get controller)" ]]; then
        local controller
        controller=$(awk -F':[[:space:]]*' '/^external-controller:/{sub(/^[^:]*:[[:space:]]*/,""); gsub(/^["'\'']|["'\'']$/,""); print; exit}' "$CONFIG")
        controller=${controller/#0.0.0.0:/127.0.0.1:}
        conf_set controller "${controller:-127.0.0.1:9090}"
    fi
    if [[ -z "$(conf_get secret)" ]]; then
        local config_secret
        config_secret=$(awk '/^secret:/{sub(/^[^:]*:[[:space:]]*/,""); gsub(/^["'\'']|["'\'']$/,""); print; exit}' "$CONFIG")
        [[ -n "$config_secret" ]] && conf_set secret "$config_secret"
    fi
    mihomo_test "$CONFIG" || die "配置校验未通过; 检查 $CONFIG"
    install_symlink
    bashrc_hook_install
    ok "配置校验通过"

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
    local link="$HOME/.local/bin/proxy"
    mkdir -p "$HOME/.local/bin" || die "无法创建 ~/.local/bin"
    [[ ! -e "$link" || -L "$link" ]] || die "$link 已存在且不是软链，拒绝覆盖"
    ln -sfn "$SCRIPT_DIR/proxy" "$link" || die "创建 proxy 软链失败"
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
command -v complete >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/lib/complete.sh" ] && _PROXY_COMPLETE_DIR="$SCRIPT_DIR" source "$SCRIPT_DIR/lib/complete.sh"
[[ \$- == *i* ]] && [ -f "\$HOME/.config/mihomo/env.state" ] && [ "\$(cat "\$HOME/.config/mihomo/env.state" 2>/dev/null)" = "on" ] && [ -x "$SCRIPT_DIR/proxy" ] && eval "\$( "$SCRIPT_DIR/proxy" _login 2>/dev/null )"
# <<< proxy (auto) <<<
EOF
)

    local rc
    for rc in "${rcs[@]}"; do
        touch "$rc" || die "无法写入 shell 配置: $rc"
        if grep -q '^# >>> proxy (auto) >>>' "$rc" 2>/dev/null; then
            python3 - "$rc" "$hook" <<'PY' || die "更新 shell 钩子失败: $rc"
import os, sys, re, tempfile
rc, hook = sys.argv[1], sys.argv[2]
t = open(rc).read()
t = re.sub(r'\n?# >>> proxy \(auto\) >>>.*?# <<< proxy \(auto\) <<<\n?', hook, t, flags=re.S)
fd, tmp = tempfile.mkstemp(prefix='.proxy-hook.', dir=os.path.dirname(rc) or '.')
with os.fdopen(fd, 'w') as f: f.write(t)
os.chmod(tmp, os.stat(rc).st_mode & 0o777)
os.replace(tmp, rc)
PY
        else
            printf '%s\n' "$hook" >> "$rc" || die "写入 shell 钩子失败: $rc"
        fi
        info "已管理 $rc 钩子 (proxy 函数包装 + 登录自启 + 0 毫秒启动优化)"
    done
}

bashrc_hook_remove() {
    local rcs=("$HOME/.bashrc" "$HOME/.zshrc")
    local rc
    for rc in "${rcs[@]}"; do
        [[ -f "$rc" ]] || continue
        python3 - "$rc" <<'PY' || die "移除 shell 钩子失败: $rc"
import os, sys, re, tempfile
rc = sys.argv[1]
t = open(rc).read()
t = re.sub(r'\n?# >>> proxy \(auto\) >>>.*?# <<< proxy \(auto\) <<<\n?', '\n', t, flags=re.S)
fd, tmp = tempfile.mkstemp(prefix='.proxy-hook.', dir=os.path.dirname(rc) or '.')
with os.fdopen(fd, 'w') as f: f.write(t)
os.chmod(tmp, os.stat(rc).st_mode & 0o777)
os.replace(tmp, rc)
PY
        info "已从 $rc 移除 proxy 钩子"
    done
}

proxy_doctor() { detect_all; }

proxy_upgrade() {
    local m; m=$(conf_get install_method)
    case "$m" in
        brew) brew upgrade mihomo || die "brew upgrade 失败" ;;
        github|gz)
            local b
            b=$(install_github) || die "GitHub 升级失败"
            conf_set bin "$b"
            ;;
        existing|manual) warn "当前二进制非本工具安装 (method=$m); 用 proxy install --via github 重装" ;;
        *) die "未知 install_method=$m (先 proxy install)" ;;
    esac
    ok "升级流程完成"
}

proxy_uninstall() {
    # shellcheck source=service.sh
    source "$SCRIPT_DIR/lib/service.sh"
    bashrc_hook_remove
    local link="$HOME/.local/bin/proxy"
    if [[ -L "$link" && "$(readlink "$link")" == "$SCRIPT_DIR/proxy" ]]; then
        rm -f "$link" || die "无法移除 $link"
    elif [[ -e "$link" ]]; then
        warn "$link 不属于本项目，已保留"
    fi
    if [[ -e /etc/sudoers.d/proxy-mihomo ]]; then
        sudo -n rm -f /etc/sudoers.d/proxy-mihomo 2>/dev/null \
            || warn "检测到旧 sudoers 规则，请手动移除: sudo rm -f /etc/sudoers.d/proxy-mihomo"
    fi
    info "已移除 .bashrc 钩子与本项目软链; 配置目录 $CONF_DIR 保留"
    local a=n method bin
    method=$(conf_get install_method); bin=$(conf_get bin)
    if [[ "$method" =~ ^(github|gz)$ && "$bin" == "$HOME/.local/bin/mihomo" && -t 0 ]]; then
        read -r -p "[proxy] 同时停止 mihomo 并删除本工具安装的二进制 $bin? [y/N] " a
    fi
    if [[ "$a" == y || "$a" == Y ]]; then
        svc_stop >/dev/null 2>&1 || die "mihomo 停止失败，未删除二进制"
        rm -f "$bin" || die "无法删除二进制: $bin"
        ok "已停止并删除本工具安装的二进制"
    fi
}
