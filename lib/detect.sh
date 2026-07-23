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
        # avx2 is the gating instruction for the v3 build
        if grep -qm1 '^flags' /proc/cpuinfo && grep -oE '^flags.*' /proc/cpuinfo | grep -qw avx2; then
            printf 'v3'; return
        fi
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
    local bin pid
    bin=$(mihomo_bin 2>/dev/null) || bin='mihomo'
    pgrep -f "$(printf '%s' "$bin" | sed 's/[].\\*[]/\\&/g') -d" >/dev/null 2>&1
}

# one-shot environment summary for `proxy doctor` / debugging
detect_all() {
    local bin arch sudo json run
    bin=$(detect_bin 2>/dev/null) && bininfo=$("$bin" -v 2>/dev/null | head -1) || bininfo='-'
    arch=$(detect_arch); [[ "$arch" == "amd64" ]] && arch="$arch/$(detect_amd64_variant)"
    sudo=$(detect_sudo); json=$(detect_json)
    detect_running && run='yes' || run='no'
    printf 'binary:        %s\n' "${bin:-<not found>}"
    printf 'version:       %s\n' "$bininfo"
    printf 'arch:          %s\n' "$arch"
    printf 'sudo:          %s\n' "$sudo"
    printf 'json tool:     %s\n' "$json"
    printf 'config.yaml:   %s\n' "$(detect_existing_config && echo present || echo absent)"
    printf 'proxy.conf:    %s\n' "$([[ -f "$PROXY_CONF" ]] && echo present || echo absent)"
    printf 'merge.yaml:    %s\n' "$([[ -f "$MERGE_FILE" ]] && echo present || echo absent)"
    printf 'running:       %s\n' "$run"
    printf 'controller:    %s\n' "$(controller_addr) $(ctrl_get /version >/dev/null 2>&1 && echo '↑' || echo '↓')"
}
