#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Use Bash 4 or newer to match tunnel-forward.sh.' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$script_dir/tunnel-forward.sh"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-forward-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Exercise the real menu action while replacing every operation that touches the host.
test_add() (
    source "$script"
    local update_result=$1 install_result=$2 expected_result=$3
    local trace="$test_dir/calls" output="$test_dir/output" result
    : > "$trace"
    ensure_forward_service_current() { echo ensure >> "$trace"; }
    enable_ip_forward() { echo forward >> "$trace"; }
    with_forward_lock() { "$@"; }
    update_forward_configuration() {
        printf 'update %s\n' "$*" >> "$trace"
        return "$update_result"
    }
    setup_forward_service() {
        echo install >> "$trace"
        return "$install_result"
    }

    if add_iptables_forward <<< $'10000-60000\n14.137.235.206\n\n' > "$output" 2>&1; then
        result=0
    else
        result=$?
    fi
    [[ "$result" == "$expected_result" ]] || fail "add returned $result, expected $expected_result"
    printf 'ensure\nforward\nupdate add 10000-60000 14.137.235.206 10000-60000\n' > "$test_dir/expected"
    if [[ "$update_result" == 0 ]]; then
        echo install >> "$test_dir/expected"
    fi
    cmp -s "$trace" "$test_dir/expected" || fail 'add/install calls or order differ'
    if [[ "$expected_result" == 0 ]]; then
        grep -q '已启用开机恢复' "$output" || fail 'successful add did not confirm persistence'
    else
        if grep -q '已启用开机恢复' "$output"; then
            fail 'failed add claimed persistence succeeded'
        fi
        if [[ "$update_result" == 0 ]]; then
            grep -q '开机恢复未完成' "$output" || fail 'installation failure was not explained'
        fi
    fi
)

test_generation() (
    # The source descriptor is gone before generation, as with bash <(curl ...).
    source <(cat "$script")
    BASE_DIR="$test_dir/config"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    GRE_CONF="$BASE_DIR/gre-forward.conf"
    TUNNEL_CONF="$BASE_DIR/tunnels.conf"
    initialize() { echo initialize >> "$TF_TEST_LOG"; }
    run_forward_daemon() {
        [[ "$BASE_DIR" == "$TF_TEST_BASE" && "$FORWARD_CONF" == "$BASE_DIR/forward.conf" ]] || exit 1
        is_valid_forward_mapping 10000-60000 10000-60000 || exit 1
        echo daemon >> "$TF_TEST_LOG"
    }

    write_forward_service_script > "$test_dir/daemon-a.sh"
    write_forward_service_script > "$test_dir/daemon-b.sh"
    "$BASH" -n "$test_dir/daemon-a.sh"
    cmp -s "$test_dir/daemon-a.sh" "$test_dir/daemon-b.sh" || fail 'generation is not deterministic'
    TF_TEST_LOG="$test_dir/daemon-calls" TF_TEST_BASE="$BASE_DIR" \
        "$BASH" "$test_dir/daemon-a.sh" --forward-daemon
    printf 'initialize\ndaemon\n' > "$test_dir/expected"
    cmp -s "$test_dir/daemon-calls" "$test_dir/expected" || fail 'independent daemon did not initialize and run'

    "$BASH" -c 'source "$1"; write_forward_service_script > "$2"' _ \
        "$test_dir/daemon-a.sh" "$test_dir/daemon-regenerated.sh"
    cmp -s "$test_dir/daemon-a.sh" "$test_dir/daemon-regenerated.sh" || fail 'installed daemon cannot regenerate identical content'
)

test_add 0 0 0
test_add 0 1 1
test_add 1 0 1
test_generation
printf 'PASS: automatic persistence, failure handling, and process-substitution daemon generation\n'
