#!/usr/bin/env bash
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Use Bash 4 or newer.' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-forward-gre.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

test_type() (
    source "$script_dir/tunnel-forward.sh"
    local link_kind=gre
    ip() {
        printf '7: ip6gre-test@NONE: <POINTOPOINT,NOARP> mtu 1450\n'
        printf '    link/%s 192.0.2.1 peer 192.0.2.2\n' "$link_kind"
    }
    [[ $(get_tunnel_type ip6gre-test) == gre ]] || fail 'interface name overrode IPv4 GRE type'
    link_kind=gre6
    [[ $(get_tunnel_type ip6gre-test) == ip6gre ]] || fail 'IPv6 GRE was not identified'
    link_kind=ether
    [[ $(get_tunnel_type ip6gre-test) == unknown ]] || fail 'unrelated interface was identified as GRE'
)

test_route() (
    source "$script_dir/tunnel-forward.sh"
    BASE_DIR="$test_dir/route"
    mkdir -p "$BASE_DIR"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    GRE_CONF="$BASE_DIR/gre-forward.conf"
    : > "$FORWARD_CONF"
    printf '61000|10.2.0.2|1|oldgre\n' > "$GRE_CONF"
    cp "$GRE_CONF" "$BASE_DIR/original"
    printf '61010|10.10.1.2|1|tunnelB\n' > "$BASE_DIR/candidate"
    local mock_route_dev=tunnelB
    ip() {
        [[ "$*" == '-4 route get 10.10.1.2' ]] || return 1
        [[ -n "$mock_route_dev" ]] || return 2
        printf '10.10.1.2 dev %s src 10.10.1.1\n' "$mock_route_dev"
    }
    validate_gre_config "$BASE_DIR/candidate" || fail 'correct tunnel route was rejected'
    nft() { touch "$BASE_DIR/kernel-changed"; }
    iptables() { touch "$BASE_DIR/kernel-changed"; }
    iptables-restore() { touch "$BASE_DIR/kernel-changed"; }
    for mock_route_dev in tunnelA ens5 lo ''; do
        if rebuild_nftables "$BASE_DIR/candidate" > "$BASE_DIR/output" 2>&1; then
            fail "wrong or missing route was accepted: $mock_route_dev"
        fi
        [[ ! -e "$BASE_DIR/kernel-changed" ]] || fail 'route rejection changed kernel rules'
        cmp -s "$GRE_CONF" "$BASE_DIR/original" || fail 'route rejection changed saved rules'
    done
)

test_concurrent_creation() (
    source "$script_dir/tunnel-forward.sh"
    BASE_DIR="$test_dir/concurrent"
    mkdir -p "$BASE_DIR/interfaces"
    TUNNEL_CONF="$BASE_DIR/tunnels.conf"
    : > "$TUNNEL_CONF"
    get_local_ipv4() { echo 192.0.2.1; }
    modprobe() { :; }
    ask_persist_tunnel() { :; }
    ip() {
        case "$1 $2" in
        'link show') [[ -f "$BASE_DIR/interfaces/$3" ]] ;;
        'tunnel add') touch "$BASE_DIR/interfaces/$3" ;;
        'link del') rm -f "$BASE_DIR/interfaces/$3" ;;
        *) return 0 ;;
        esac
    }
    # Keeping this section busy makes an unlocked read/modify/write overlap observable.
    awk() {
        mkdir "$BASE_DIR/updating" || return 1
        command awk "$@"
        sleep 0.1
        rmdir "$BASE_DIR/updating"
    }
    create_gre_tunnel gre <<< $'one\n192.0.2.1\n192.0.2.2\n10.10.1.1/24\n1450\n' > "$BASE_DIR/one.log" 2>&1 &
    local first=$!
    create_gre_tunnel gre <<< $'two\n192.0.2.1\n192.0.2.3\n10.11.1.1/24\n1450\n' > "$BASE_DIR/two.log" 2>&1 &
    local second=$!
    wait "$first" || fail 'first concurrent creation failed'
    wait "$second" || fail 'second concurrent creation failed'
    [[ $(wc -l < "$TUNNEL_CONF") == 2 ]] || fail 'concurrent creation lost a record'
    grep -q '^one|' "$TUNNEL_CONF" && grep -q '^two|' "$TUNNEL_CONF" || fail 'expected tunnel records are missing'
    if with_forward_lock create_gre_tunnel_unlocked gre one 192.0.2.1 192.0.2.4 10.12.1.1/24 1450 > "$BASE_DIR/duplicate.log" 2>&1; then
        fail 'duplicate interface passed the locked existence check'
    fi
    [[ $(wc -l < "$TUNNEL_CONF") == 2 ]] || fail 'duplicate interface changed records'
)

test_deleted_before_persistence() (
    source "$script_dir/tunnel-forward.sh"
    BASE_DIR="$test_dir/deleted"
    mkdir -p "$BASE_DIR"
    ip() { return 1; }
    systemctl() { touch "$BASE_DIR/persistence-changed"; }
    if ask_persist_tunnel vanished gre 192.0.2.1 192.0.2.2 10.10.1.1/24 1450 <<< 1 > "$BASE_DIR/output" 2>&1; then
        fail 'deleted tunnel was persisted'
    fi
    [[ ! -e "$BASE_DIR/persistence-changed" ]] || fail 'deleted tunnel changed persistence'
)

test_type
test_route
test_concurrent_creation
test_deleted_before_persistence
printf 'PASS: GRE type, route validation, concurrent creation, and persistence/delete coordination\n'
