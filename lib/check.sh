# shellcheck shell=bash
# proxy/lib/check.sh — proxy environment and connectivity check.

proxy_check() {
    local os_type test_url ip sys_proxy host port mode
    os_type=$(uname -s)
    test_url="https://youtube.com"
    
    say "--- Proxy Status ($os_type) ---"
    
    # 1. Check OS-Level/System Settings
    if [[ "$os_type" == "Darwin" ]]; then
        # macOS specific system check
        sys_proxy=$(scutil --proxy | grep "HTTPEnable" | awk '{print $3}')
        if [[ "$sys_proxy" == "1" ]]; then
            host=$(scutil --proxy | grep "HTTPProxy" | awk '{print $3}')
            port=$(scutil --proxy | grep "HTTPPort" | awk '{print $3}')
            ok "System Settings: ✅ Enabled ($host:$port)"
        else
            warn "System Settings: ❌ Disabled"
        fi
    elif [[ "$os_type" == "Linux" ]]; then
        # Linux check (Checking GNOME settings as a common example)
        if command -v gsettings >/dev/null 2>&1; then
            mode=$(gsettings get org.gnome.system.proxy mode | tr -d "'")
            say "GNOME Settings:  mode: $mode"
        else
            info "System Settings: (No desktop-level manager detected)"
        fi
    fi

    # 2. Check Environment Variables
    if [[ -z "$http_proxy" && -z "$HTTP_PROXY" ]]; then
        warn "Environment:     ❌ Not Set"
    else
        ok "Environment:     ✅ Set"
        [[ -n "$http_proxy" ]] && info "  http_proxy:  $http_proxy"
        [[ -n "$HTTP_PROXY" ]] && info "  HTTP_PROXY:  $HTTP_PROXY"
    fi

    # 3. Connectivity Test
    printf "Routing Test:    "
    # -L follows redirects, -I gets headers, --connect-timeout prevents hanging
    if curl -IsL --connect-timeout 3 "$test_url" > /dev/null 2>&1; then
        ip=$(curl -s --connect-timeout 2 ifconfig.me)
        ok "✅ Success (IP: $ip)"
    else
        warn "❌ Failed (Connection Timeout/Refused)"
    fi
    say "------------------------------"
}
