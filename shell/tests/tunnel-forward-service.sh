#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Use Bash 4 or newer.' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-service-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_install() (
    local scenario=$1 folder="$test_dir/$1" fault_stage=$2 original=$3 expected=$4
    local bin_dir="$folder/bin" unit_dir="$folder/systemd"
    mkdir -p "$bin_dir" "$unit_dir" "$folder/config"
    # Redirect only installation destinations; the real installer and rollback logic run unchanged.
    sed -e "s|/usr/local/bin|$bin_dir|g" -e "s|/etc/systemd/system|$unit_dir|g" \
        "$script_dir/tunnel-forward.sh" > "$folder/source.sh"
    source "$folder/source.sh"
    BASE_DIR="$folder/config"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    GRE_CONF="$BASE_DIR/gre-forward.conf"
    TUNNEL_CONF="$BASE_DIR/tunnels.conf"
    touch "$FORWARD_CONF" "$GRE_CONF" "$TUNNEL_CONF"
    : > "$folder/trace"

    fault() {
        if [[ "$fault_stage" == "$1" && ! -e "$folder/fault-$1" ]]; then
            touch "$folder/fault-$1"
            return 0
        fi
        return 1
    }
    read_enablement() {
        if [[ -e "$folder/permanent-enabled" ]]; then
            printf '%s\n' enabled
        elif [[ -e "$folder/runtime-enabled" ]]; then
            printf '%s\n' enabled-runtime
        else
            printf '%s\n' disabled
        fi
    }
    systemctl() {
        printf '%s\n' "$*" >> "$folder/trace"
        case $1 in
        show-environment) return 0 ;;
        is-enabled)
            read_enablement
            [[ "$(read_enablement)" != disabled ]]
            ;;
        is-active) [[ -e "$folder/active" ]] ;;
        show)
            if [[ "$original" == legacy ]]; then
                printf 'ExecStart=/bin/bash %s/tunnel-forward-dnat.sh\n' "$bin_dir"
            else
                printf 'ExecStart=/bin/bash %s/tunnel-forward-dnat.sh --forward-daemon\n' "$bin_dir"
            fi
            ;;
        stop) rm -f "$folder/active" ;;
        restart)
            if [[ "$fault_stage" == restore && ! -e "$folder/start-failed" ]]; then
                touch "$folder/start-failed"
                return 1
            fi
            if fault restart; then return 1; fi
            touch "$folder/active"
            ;;
        daemon-reload) if fault daemon-reload; then return 1; fi ;;
        enable)
            if [[ "$*" == *--runtime* ]]; then
                touch "$folder/runtime-enabled"
            else
                touch "$folder/permanent-enabled"
            fi
            if fault enable; then return 1; fi
            ;;
        disable) rm -f "$folder/permanent-enabled" ;;
        *) fail "unexpected systemctl command: $*" ;;
        esac
    }
    enable_ip_forward() { :; }
    with_forward_lock() { "$@"; }
    sync_iptables_forward() {
        printf '%s\n' sync >> "$folder/trace"
        if fault sync; then return 1; fi
    }
    mv() {
        local destination=${!#}
        if [[ "$destination" == "$unit_dir/tunnel-forward.service" && "$*" == *'.tunnel-forward.'* ]] && fault publish; then
            return 1
        fi
        if [[ "$*" == *'/script.old '* ]] && fault restore; then return 1; fi
        command mv "$@"
    }

    if [[ "$original" != absent ]]; then
        touch "$folder/active"
        if [[ "$original" == runtime ]]; then
            touch "$folder/runtime-enabled"
        else
            touch "$folder/permanent-enabled"
        fi
        if [[ "$original" == legacy ]]; then
            printf '#!/bin/bash\n# legacy uncoordinated polling loop\n' > "$bin_dir/tunnel-forward-dnat.sh"
        else
            printf '#!/bin/bash\nsync_iptables_forward() { :; }\n# previous safe version\n' > "$bin_dir/tunnel-forward-dnat.sh"
        fi
        printf '[Service]\nExecStart=/bin/bash previous-version\n' > "$unit_dir/tunnel-forward.service"
        if [[ "$original" == identical ]]; then
            write_forward_service_script > "$bin_dir/tunnel-forward-dnat.sh"
            cat > "$unit_dir/tunnel-forward.service" <<UNIT
[Unit]
Description=Port forwarding with iptables and dynamic DNS
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/bin/bash $bin_dir/tunnel-forward-dnat.sh --forward-daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
        fi
        cp -p "$bin_dir/tunnel-forward-dnat.sh" "$folder/script.before"
        cp -p "$unit_dir/tunnel-forward.service" "$folder/unit.before"
    fi
    local result=0
    setup_forward_service > "$folder/output" 2>&1 || result=$?
    if [[ "$expected" == recovery-failed ]]; then
        local work_dirs=("$BASE_DIR"/.forward-service.*)
        [[ "$result" != 0 && ${#work_dirs[@]} == 1 && -f "${work_dirs[0]}/script.old" ]] || fail "$scenario deleted the recovery backup"
        cmp -s "$folder/script.before" "${work_dirs[0]}/script.old" || fail "$scenario corrupted the recovery backup"
        grep -Fq "备份保留在 ${work_dirs[0]}" "$folder/output" || fail "$scenario did not report the recovery path"
        printf 'PASS: %s\n' "$scenario"
        return 0
    fi
    if [[ "$expected" == success ]]; then
        [[ "$result" == 0 && -e "$folder/active" ]] || fail "$scenario did not start"
        [[ "$(read_enablement)" == enabled ]] || fail "$scenario was not enabled"
    else
        [[ "$result" != 0 ]] || fail "$scenario unexpectedly succeeded"
        if [[ "$original" == absent ]]; then
            [[ ! -e "$bin_dir/tunnel-forward-dnat.sh" && ! -e "$unit_dir/tunnel-forward.service" ]] || fail "$scenario left new files"
            [[ "$(read_enablement)" == disabled ]] || fail "$scenario left enablement behind"
        else
            cmp -s "$folder/script.before" "$bin_dir/tunnel-forward-dnat.sh" || fail "$scenario did not restore script"
            cmp -s "$folder/unit.before" "$unit_dir/tunnel-forward.service" || fail "$scenario did not restore unit"
        fi
        if [[ "$original" == safe || "$original" == identical || "$original" == runtime ]]; then
            [[ -e "$folder/active" ]] || fail "$scenario stopped the healthy service"
        else
            [[ ! -e "$folder/active" ]] || fail "$scenario restarted an unsafe or previously absent service"
        fi
        if [[ "$original" == runtime ]]; then
            [[ "$(read_enablement)" == enabled-runtime && ! -e "$folder/permanent-enabled" ]] || fail "$scenario left permanent enablement behind"
        fi
    fi
    if [[ "$original" == identical ]]; then
        if grep -Eq '^(stop|restart) ' "$folder/trace"; then
            fail "$scenario unnecessarily stopped the identical running service"
        fi
    fi
    printf 'PASS: %s\n' "$scenario"
)

test_no_newline() (
    source "$script_dir/tunnel-forward.sh"
    BASE_DIR="$test_dir/no-newline"
    mkdir -p "$BASE_DIR"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    printf '8080>192.0.2.1:8080' > "$FORWARD_CONF"
    iptables() { :; }
    ensure_forward_service_current() { :; }
    with_forward_lock() { "$@"; }
    update_forward_configuration() { printf '%s\n' "$*" > "$BASE_DIR/deleted"; }
    list_iptables_forward > "$BASE_DIR/list"
    grep -q '8080 → 192.0.2.1:8080' "$BASE_DIR/list" || fail 'list omitted the last line'
    del_iptables_forward <<< '1' > "$BASE_DIR/output"
    [[ "$(cat "$BASE_DIR/deleted")" == 'delete 8080' ]] || fail 'numbered deletion omitted the last line'
    printf 'PASS: menu reads and deletes a final line without newline\n'
)

test_install safe-sync-failure sync safe failure
test_install safe-publish-failure publish safe failure
test_install safe-reload-failure daemon-reload safe failure
test_install safe-enable-failure enable safe failure
test_install safe-start-failure restart safe failure
test_install legacy-not-restarted sync legacy failure
test_install failed-first-install restart absent failure
test_install runtime-enablement-restored restart runtime failure
test_install rollback-failure-keeps-backup restore safe recovery-failed
test_install safe-upgrade-success none safe success
test_install identical-service-sync-failure sync identical failure
test_install identical-service-success none identical success
test_no_newline
