# shellcheck shell=bash
health_cmd() {
    require python3
    python3 "$SCRIPT_DIR/libexec/health.py" --root "$CONF_DIR" "$@"
}
