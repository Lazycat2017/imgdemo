#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Use Bash 4 or newer.' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-gre-service-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Redirect the service directory to a fixture; all files and service state stay in /tmp.
sed "s|/etc/systemd/system|$test_dir/systemd|g" "$script_dir/tunnel-forward.sh" > "$test_dir/script.sh"
source "$test_dir/script.sh"

systemctl() {
    printf '%s\n' "$*" >> "$trace"
    case $1 in
        show-environment) return 0 ;;
        is-enabled)
            command cat "$state"
            [[ "$(command cat "$state")" == enabled* ]]
            ;;
        daemon-reload)
            if [[ "$scenario" == reload && ! -e "$case_dir/failed-once" ]]; then
                touch "$case_dir/failed-once"; return 1
            fi
            ;;
        enable)
            if [[ "$scenario" == enable && ! -e "$case_dir/failed-once" ]]; then
                touch "$case_dir/failed-once"; return 1
            fi
            if [[ " $* " == *' --runtime '* ]]; then
                echo enabled-runtime > "$state"
            else
                echo enabled > "$state"
            fi
            ;;
        disable) echo disabled > "$state" ;;
    esac
}

cat() {
    local writer_pid=$BASHPID output_file
    output_file=$(readlink "/proc/$writer_pid/fd/1")
    if [[ "$scenario" == stage && "$output_file" == */unit.new ]]; then
        printf '[Unit]\n'
        return 1
    fi
    command cat "$@"
}

mv() {
    if [[ "$scenario" == commit && "${2:-}" == */unit.new && ! -e "$case_dir/failed-once" ]]; then
        touch "$case_dir/failed-once"
        return 1
    fi
    command mv "$@"
}

test_install() (
    local scenario=$1 previous=$2 existing=${3:-yes} operation=${4:-setup}
    local case_dir="$test_dir/$scenario-$previous-$existing-$operation"
    local state="$case_dir/enabled" trace="$case_dir/trace" result
    mkdir -p "$case_dir" "$test_dir/systemd"
    BASE_DIR="$case_dir/config"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    GRE_CONF="$BASE_DIR/gre-forward.conf"
    mkdir -p "$BASE_DIR"
    : > "$trace"
    printf '%s\n' "$previous" > "$state"
    local loader="$BASE_DIR/load-gre-forward.sh" unit="$test_dir/systemd/tunnel-gre-nft.service"
    rm -f -- "$unit"
    if [[ "$existing" == yes ]]; then
        printf 'OLD-LOADER\n' > "$loader"
        printf '[Unit]\nDescription=Original GRE service\n[Service]\nExecStart=/bin/true\n' > "$unit"
        cp "$loader" "$case_dir/loader.before"
        cp "$unit" "$case_dir/unit.before"
    fi

    if [[ "$operation" == rebuild ]]; then
        : > "$FORWARD_CONF"
        printf '10000|10.10.1.2|1|test-gre\n' > "$GRE_CONF"
        printf 'OLD-NFT\n' > "$BASE_DIR/nftables-gre.conf"
        printf 'OLD-FILTER\n' > "$BASE_DIR/gre-forward-filter.rules"
        validate_gre_route() { return 0; }
        enable_ip_forward() { return 0; }
        nft() { [[ "$1" != list ]]; }
        iptables() { return 1; }
        iptables-restore() { command cat >/dev/null; }
        if rebuild_nftables "$GRE_CONF" > "$case_dir/output" 2>&1; then result=0; else result=$?; fi
    else
        if setup_gre_nft_service > "$case_dir/output" 2>&1; then result=0; else result=$?; fi
    fi

    if [[ "$scenario" == success ]]; then
        [[ "$result" == 0 ]] || fail 'successful install failed'
        [[ "$(command cat "$state")" == enabled ]] || fail 'service not enabled'
        "$BASH" -n "$loader"
        grep -q 'sysctl -w net.ipv4.ip_forward=1' "$loader" || fail 'loader does not enable forwarding'
        grep -q 'sysctl -n net.ipv4.ip_forward' "$loader" || fail 'loader does not verify forwarding'
    else
        [[ "$result" != 0 ]] || fail "$scenario failure returned success"
        [[ "$(command cat "$state")" == "$previous" ]] || fail "$scenario changed enable state"
        if [[ "$existing" == yes ]]; then
            cmp -s "$loader" "$case_dir/loader.before" || fail "$scenario did not restore loader"
            cmp -s "$unit" "$case_dir/unit.before" || fail "$scenario did not restore unit"
        else
            [[ ! -e "$loader" && ! -e "$unit" ]] || fail 'failed new install left service files'
        fi
        if [[ "$operation" == rebuild ]]; then
            [[ "$(command cat "$BASE_DIR/nftables-gre.conf")" == OLD-NFT ]] || fail 'rebuild did not restore nft file'
            [[ "$(command cat "$BASE_DIR/gre-forward-filter.rules")" == OLD-FILTER ]] || fail 'rebuild did not restore filter file'
        fi
    fi
    printf 'PASS: GRE service %s (previous=%s, existing=%s, operation=%s)\n' "$scenario" "$previous" "$existing" "$operation"
)

test_loader() (
    local scenario=success
    local case_dir="$test_dir/loader" state="$test_dir/loader/enabled" trace="$test_dir/loader/trace"
    mkdir -p "$case_dir" "$test_dir/systemd"
    BASE_DIR="$case_dir/config"
    mkdir -p "$BASE_DIR"
    echo disabled > "$state"
    : > "$trace"
    setup_gre_nft_service
    sysctl() {
        if [[ "$1" == -w ]]; then
            echo 1 > "$TF_TEST_RUNTIME"
        elif [[ "${TF_TEST_BAD_READ:-0}" == 1 ]]; then
            echo 0
        else
            command cat "$TF_TEST_RUNTIME"
        fi
    }
    nft() {
        [[ "$(command cat "$TF_TEST_RUNTIME")" == 1 ]] || return 1
        echo nft >> "$TF_TEST_CALLS"
    }
    export -f sysctl nft
    export TF_TEST_RUNTIME="$case_dir/runtime" TF_TEST_CALLS="$case_dir/loader-calls"
    echo 0 > "$TF_TEST_RUNTIME"
    "$BASH" "$BASE_DIR/load-gre-forward.sh"
    [[ "$(command cat "$TF_TEST_RUNTIME")" == 1 ]] || fail 'loader left forwarding disabled'
    [[ "$(command cat "$TF_TEST_CALLS")" == nft ]] || fail 'loader did not apply rules after enabling forwarding'
    : > "$TF_TEST_CALLS"
    if TF_TEST_BAD_READ=1 "$BASH" "$BASE_DIR/load-gre-forward.sh"; then
        fail 'loader ignored failed forwarding verification'
    fi
    [[ ! -s "$TF_TEST_CALLS" ]] || fail 'loader applied rules after forwarding verification failed'
    echo 'PASS: GRE loader enables and verifies IPv4 forwarding before applying rules'
)

test_install stage enabled
test_install commit enabled
test_install reload disabled
test_install enable enabled
test_install enable enabled-runtime
test_install enable disabled
test_install enable disabled no
test_install enable enabled yes rebuild
test_install success disabled
test_loader
