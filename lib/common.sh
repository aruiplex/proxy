# shellcheck shell=bash
# proxy/lib/common.sh — shared helpers, sourced by the main entry.
# All code lives under ~/scripts/proxy/. This file defines paths, logging,
# proxy.conf I/O, and controller-API helpers used across modules.

set -o pipefail

# --- colors (disabled when stdout is not a tty, so _login/eval output stays clean) ---
if [[ -t 1 ]]; then
    C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_D=$'\e[2m'; C_B=$'\e[1m'; C_N=$'\e[0m'
else
    C_R=''; C_G=''; C_Y=''; C_D=''; C_B=''; C_N=''
fi

# --- runtime paths (no hardcoding of $HOME; overridable via env for tests) ---
: "${CONF_DIR:=$HOME/.config/mihomo}"
CONFIG="$CONF_DIR/config.yaml"
LOG="$CONF_DIR/mihomo.log"
MERGE_FILE="$CONF_DIR/merge.yaml"
PROXY_CONF="$CONF_DIR/proxy.conf"
ENV_STATE="$CONF_DIR/env.state"
BAK="$CONFIG.bak"

# --- logging ---
die()  { printf "${C_R}[proxy] %s${C_N}\n" "$*" >&2; exit 1; }
warn() { printf "${C_Y}[proxy] %s${C_N}\n" "$*" >&2; }
info() { printf "${C_D}%s${C_N}\n" "$*"; }
ok()   { printf "${C_G}%s${C_N}\n" "$*"; }
say()  { printf '%s\n' "$*"; }

has()  { command -v "$1" >/dev/null 2>&1; }
require() { has "$1" || die "缺少依赖: $1 (请先安装)"; }

# --- proxy.conf (simple key=value, mode 600 because it may hold a subscription token) ---
conf_get() {
    local k=$1
    [[ -f "$PROXY_CONF" ]] || return 0
    awk -F'=' -v k="$k" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$PROXY_CONF"
}
conf_set() {
    local k=$1 v=$2
    mkdir -p "$CONF_DIR"
    touch "$PROXY_CONF"; chmod 600 "$PROXY_CONF"
    # drop any existing key= line, then append the new value verbatim
    { grep -v "^${k}=" "$PROXY_CONF" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } > "$PROXY_CONF.tmp"
    mv -f "$PROXY_CONF.tmp" "$PROXY_CONF"; chmod 600 "$PROXY_CONF"
}

# resolve the configured mihomo binary path; fall back to a search
mihomo_bin() {
    local b
    b=$(conf_get bin)
    [[ -n "$b" && -x "$b" ]] && { printf '%s' "$b"; return 0; }
    # search common locations + PATH
    local cands=(
        "$HOME/.local/bin/mihomo" "$HOME/bin/mihomo"
        "$HOME/.brew/bin/mihomo" "/usr/local/bin/mihomo" "/opt/homebrew/bin/mihomo"
    )
    local c
    for c in "${cands[@]}"; do [[ -x "$c" ]] && { printf '%s' "$c"; return 0; }; done
    has mihomo && { command -v mihomo; return 0; }
    return 1
}

# --- controller (mihomo external-controller) ---
controller_addr() {
    local a; a=$(conf_get controller); printf '%s' "${a:-127.0.0.1:9090}"
}
_secret() { conf_get secret; }

# GET a controller path; prints body to stdout
ctrl_get() {
    local path=$1 s; s=$(_secret)
    curl -sS --max-time 8 ${s:+-H "Authorization: Bearer $s"} "http://$(controller_addr)$path"
}
# PUT a controller path with a JSON body; prints http code
ctrl_put() {
    local path=$1 body=$2 s; s=$(_secret)
    curl -sS --max-time 8 -X PUT ${s:+-H "Authorization: Bearer $s"} \
        -H 'Content-Type: application/json' -d "$body" -o /dev/null -w '%{http_code}' \
        "http://$(controller_addr)$path"
}
# hot-reload config from a given file path; prints http code (204/200 ok; 400 invalid, instance stays up)
ctrl_reload() {
    local f=$1 s; s=$(_secret)
    curl -sS --max-time 8 -X PUT ${s:+-H "Authorization: Bearer $s"} \
        -H 'Content-Type: application/json' -d "{\"path\":\"$f\"}" -o /dev/null -w '%{http_code}' \
        "http://$(controller_addr)/configs?force=true"
}

# true if the controller answers /version (i.e. external-controller is up)
ctrl_up() { ctrl_get /version >/dev/null 2>&1; }

# die with an actionable message when the controller is unreachable — most
# "no node group / empty status" reports are really this, not a missing group.
ctrl_require() {
    ctrl_up || die "控制器不可达 (http://$(controller_addr) ↓)。
  原因多为运行中的 mihomo 用了不带 external-controller 的旧配置 (热重载无法应用新配置 → 死循环)。
  修复: proxy restart   (用磁盘上带 external-controller 的 config 重起)
  若仍 ↓: grep external-controller ~/.config/mihomo/config.yaml  和  proxy log"
}

# --- JSON: prefer python3 (near-universal); degrade to a clear message if absent ---
json_guard() { has python3 || die "此命令需要 python3 解析 JSON (未安装)"; }

# mihomo config validation: exit 0 if the file parses, else nonzero; stderr captured
mihomo_test() {
    local f=$1 bin
    bin=$(mihomo_bin) || { warn "找不到 mihomo 二进制，无法校验配置"; return 2; }
    "$bin" -t -d "$CONF_DIR" -f "$f" >/dev/null 2>&1
}

# URL-encode a string for controller paths (proxies/<name>)
jq_uri() { has python3 && python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$1" 2>/dev/null || printf '%s' "$1"; }

# the selector group to operate on: configured name, else auto-detect first Selector/URLTest group
node_group() {
    local g; g=$(conf_get node_group)
    [[ -n "$g" ]] && { printf '%s' "$g"; return; }
    has python3 || return 0
    ctrl_get /proxies 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
proxies=d.get('proxies',{})
# prefer a Selector (the pool entry group 节点选择); fall back to URLTest for
# subs without one. First-by-name is unreliable: Go sorts group names by
# UTF-8 bytes, so 加拿大-自动 sorts before 节点选择.
for want in ('Selector','URLTest'):
    for n,v in proxies.items():
        if v.get('type')==want and n not in ('GLOBAL','DIRECT','REJECT') and v.get('all'):
            print(n);break
    else:
        continue
    break
" 2>/dev/null
}
