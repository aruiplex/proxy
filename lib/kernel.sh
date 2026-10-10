# shellcheck shell=bash
# Version selection never restarts a core. Changes require a stopped instance.
kernel_run() {
    require python3
    python3 "$SCRIPT_DIR/libexec/kernel_manager.py" --root "$CONF_DIR" "$@"
}

kernel_cmd() {
    local sub=${1:-status}; shift || true
    case "$sub" in
        prepare|activate|rollback) kernel_run "$sub" "$@" ;;
        status)
            if [[ "${1:-}" == --json ]]; then kernel_run status; return; fi
            kernel_run status | python3 -c '
import json,sys
s=json.load(sys.stdin)
for key,label in (("active","当前"),("prepared","待启用"),("previous","可回退")):
 r=s.get(key) or (s.get("legacy") if key=="active" else None)
 if r: print("%s: %s · %s (%s)" % (label,r["version"],r["source"]["id"],r["source"]["kind"]))
 else: print(label+": 无")
print("准备版本不影响运行中的连接；启用/回退后需要手动 proxy start。")'
            ;;
        -h|--help|help)
            say '用法: proxy kernel prepare --manifest FILE | --official VERSION | --bin PATH'
            say '      [--config FILE] [--source ID --kind custom|manual|gz|brew|existing] [--switch-source]'
            say '      proxy kernel activate | rollback | status [--json]'
            say 'prepare 只下载/校验；activate 和 rollback 要求内核已停止，不自动启动。'
            ;;
        *) die "proxy kernel: 未知子命令 $sub" ;;
    esac
}

# Hold the same lock as activation until the service has established its PID.
kernel_start() {
    kernel_run start --cli "$SCRIPT_DIR/proxy"
}
