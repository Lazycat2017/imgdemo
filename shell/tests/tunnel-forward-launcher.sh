#!/usr/bin/env bash
# The sourced implementation reads configuration variables and serializes test callbacks.
# shellcheck disable=SC1090,SC2034
set -euo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo 'Use Bash 4 or newer.' >&2; exit 1; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/tunnel-launcher-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

prepare() {
    mkdir -p "$folder/bin" "$folder/config"
    sed -e "s|/usr/local/lib/tunnel-forward|$folder/lib|g" \
        -e "s|/usr/local/bin|$folder/bin|g" \
        "$script_dir/tunnel-forward.sh" > "$folder/source.sh"
    # The descriptor closes before installation, as with a downloaded process substitution.
    source <(cat "$folder/source.sh")
    BASE_DIR="$folder/config"
    FORWARD_CONF="$BASE_DIR/forward.conf"
    GRE_CONF="$BASE_DIR/gre-forward.conf"
    TUNNEL_CONF="$BASE_DIR/tunnels.conf"
    export PATH="$folder/bin:/usr/bin:/bin"
    export TF_TEST_LOG="$folder/calls"
    initialize() { printf 'initialize\n' >> "$TF_TEST_LOG"; }
    main_menu() {
        flock -n "$BASE_DIR/launcher.lock" true || return 1
        printf 'menu\n' >> "$TF_TEST_LOG"
    }
    run_forward_daemon() { printf 'daemon\n' >> "$TF_TEST_LOG"; }
}

test_install() (
    local folder="$test_dir/install" manager inode
    prepare
    manager="$folder/lib/manager.sh"
    run_tunnel_forward > "$folder/first-output"
    [[ -x "$manager" && -L "$folder/bin/r" ]] || fail 'first run did not install manager and r'
    [[ "$(readlink "$folder/bin/r")" == "$manager" ]] || fail 'r points to a different manager'
    "$BASH" -n "$manager"
    inode=$(stat -c %i "$manager")
    install_local_command > "$folder/repeat-output"
    [[ "$(stat -c %i "$manager")" == "$inode" ]] || fail 'identical manager was rewritten'
    [[ ! -s "$folder/repeat-output" ]] || fail 'identical registration announced a reinstall'

    : > "$TF_TEST_LOG"
    "$folder/bin/r"
    printf 'initialize\nmenu\n' > "$folder/expected"
    cmp -s "$TF_TEST_LOG" "$folder/expected" || fail 'independent r did not initialize and open the menu'
    [[ "$(stat -c %i "$manager")" == "$inode" ]] || fail 'r rewrote an unchanged manager'

    rm "$folder/bin/r"
    install_local_command > /dev/null
    [[ -L "$folder/bin/r" && "$(readlink "$folder/bin/r")" == "$manager" ]] || fail 'missing r link was not repaired'
    [[ "$(stat -c %i "$manager")" == "$inode" ]] || fail 'link repair rewrote manager'
    rm "$manager"
    install_local_command > /dev/null
    [[ -x "$manager" && -L "$folder/bin/r" ]] || fail 'owned dangling link was not repaired'
    printf 'PASS: process substitution, independent r menu, idempotence, and missing-link repair\n'
)

test_conflict() (
    local kind=$1 folder="$test_dir/conflict-$1"
    prepare
    case "$kind" in
    regular) printf 'existing application\n' > "$folder/bin/r" ;;
    directory) mkdir "$folder/bin/r" ;;
    dangling) ln -s "$folder/missing-foreign-manager" "$folder/bin/r" ;;
    path)
        mkdir "$folder/other-bin"
        printf '#!/bin/sh\nexit 0\n' > "$folder/other-bin/r"
        chmod 755 "$folder/other-bin/r"
        export PATH="$folder/other-bin:$PATH"
        ;;
    esac
    if install_local_command > "$folder/output" 2>&1; then
        fail "$kind r conflict was overwritten"
    fi
    [[ ! -e "$folder/lib/manager.sh" ]] || fail "$kind conflict installed an orphan manager"
    grep -q 'r 命令已被其他程序占用' "$folder/output" || fail "$kind conflict was not explained"
    case "$kind" in
    regular) [[ "$(cat "$folder/bin/r")" == 'existing application' ]] || fail 'regular r changed' ;;
    directory) [[ -d "$folder/bin/r" && ! -L "$folder/bin/r" ]] || fail 'r directory changed' ;;
    dangling) [[ "$(readlink "$folder/bin/r")" == "$folder/missing-foreign-manager" ]] || fail 'foreign link changed' ;;
    path) [[ ! -e "$folder/bin/r" && -x "$folder/other-bin/r" ]] || fail 'existing PATH command was shadowed' ;;
    esac
    printf 'PASS: protect %s r conflict\n' "$kind"
)

test_daemon() (
    local folder="$test_dir/daemon"
    prepare
    write_forward_service_script > "$folder/daemon.sh"
    "$BASH" "$folder/daemon.sh" --forward-daemon
    printf 'initialize\ndaemon\n' > "$folder/expected"
    cmp -s "$TF_TEST_LOG" "$folder/expected" || fail 'daemon entry opened menu or skipped initialization'
    [[ ! -e "$folder/lib/manager.sh" && ! -L "$folder/bin/r" ]] || fail 'daemon registered r'
    printf 'PASS: daemon entry does not register r\n'
)

test_concurrent_install() (
    local folder="$test_dir/concurrent" first second
    prepare
    install_local_command > "$folder/first-output" &
    first=$!
    install_local_command > "$folder/second-output" &
    second=$!
    wait "$first"
    wait "$second"
    [[ -x "$folder/lib/manager.sh" && -L "$folder/bin/r" ]] || fail 'concurrent install left an incomplete launcher'
    [[ "$(readlink "$folder/bin/r")" == "$folder/lib/manager.sh" ]] || fail 'concurrent install linked the wrong manager'
    "$folder/bin/r"
    flock -n "$BASE_DIR/launcher.lock" true || fail 'installer retained its lock'
    printf 'PASS: concurrent registration and released install lock\n'
)

test_install
test_conflict regular
test_conflict directory
test_conflict dangling
test_conflict path
test_daemon
test_concurrent_install
