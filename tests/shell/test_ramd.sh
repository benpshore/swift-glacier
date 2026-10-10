#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/../.." && pwd)
ramd=$repo_root/scripts/ramd
test_root=$(mktemp -d "${TMPDIR:-/tmp}/ramd-tests.XXXXXX")
mock_bin=$test_root/bin
mkdir -p "$mock_bin"
trap 'rm -rf "$test_root"' 0 HUP INT TERM

cat >"$mock_bin/uname" <<'MOCK'
#!/bin/sh
if [ "${MOCK_SCENARIO:-}" = linux ]; then
    printf '%s\n' Linux
else
    printf '%s\n' Darwin
fi
MOCK

cat >"$mock_bin/sysctl" <<'MOCK'
#!/bin/sh
if [ "$1" != -n ]; then exit 2; fi
case $2 in
    hw.memsize)
        [ "${MOCK_SCENARIO:-}" != sysctl_failure ] || exit 1
        printf '%s\n' 17179869184
        ;;
    kern.memorystatus_vm_pressure_level)
        case ${MOCK_SCENARIO:-} in
            pressure_failure) exit 1 ;;
            pressure_warning) printf '%s\n' 2 ;;
            pressure_critical) printf '%s\n' 4 ;;
            pressure_unknown) printf '%s\n' 0 ;;
            pressure_malformed) printf '%s\n' '2 warning' ;;
            *) printf '%s\n' 1 ;;
        esac
        ;;
    *) exit 1 ;;
esac
MOCK

cat >"$mock_bin/vm_stat" <<'MOCK'
#!/bin/sh
case ${MOCK_SCENARIO:-} in
    vm_stat_failure) exit 1 ;;
    vm_stat_malformed) printf '%s\n' 'not vm statistics' ;;
    *)
        cat <<'STATS'
Mach Virtual Memory Statistics: (page size of 4096 bytes)
Pages free:                               300000.
Pages inactive:                          1000000.
Pages speculative:                      100000.
Pages purgeable:                         100000.
STATS
        ;;
esac
MOCK

cat >"$mock_bin/ioreg" <<'MOCK'
#!/bin/sh
printf 'ioreg %s\n' "$*" >>"$MOCK_DEVICE_CALLS"
if [ "${MOCK_SCENARIO:-}" = cross_object ]; then
    cat <<'REGISTRY'
+-o AttemptTokenNode <IOService>
    "ramd-owner-token" = "11111111-1111-4111-8111-111111111111"
+-o UnrelatedMediaNode <IOMedia>
    "BSD Name" = "disk7"
REGISTRY
else
    printf '%s\n' '+-o no matching object'
fi
MOCK

cat >"$mock_bin/blocked-command" <<'MOCK'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$MOCK_DEVICE_CALLS"
exit 99
MOCK

for blocked_command in hdiutil diskutil newfs_hfs mount umount dd mktemp mkdir rm touch chmod \
    curl wget nc netcat ssh scp sftp ftp python python3 perl ruby osascript launchctl logger \
    installer brew defaults open; do
    ln -s blocked-command "$mock_bin/$blocked_command"
done
chmod +x "$mock_bin/blocked-command" "$mock_bin/uname" "$mock_bin/sysctl" "$mock_bin/vm_stat" "$mock_bin/ioreg"

pass() { printf 'PASS: %s\n' "$1"; }
new_case() {
    case_name=$1
    case_dir=$test_root/$case_name
    mkdir -p "$case_dir"
    device_calls=$case_dir/device-calls.log
    : >"$device_calls"
}
run_ramd() {
    scenario=$1
    shift
    MOCK_SCENARIO=$scenario \
    MOCK_DEVICE_CALLS=$device_calls \
    PATH=$mock_bin:$PATH \
    sh "$ramd" "$@"
}
expect_failure() {
    scenario=$1
    shift
    if run_ramd "$scenario" "$@" >"$case_dir/output" 2>&1; then
        cat "$case_dir/output" >&2
        printf 'FAIL: expected command failure in %s\n' "$case_name" >&2
        exit 1
    fi
}
assert_output_has() {
    needle=$1
    grep -F "$needle" "$case_dir/output" >/dev/null 2>&1 || {
        cat "$case_dir/output" >&2
        printf 'FAIL: output did not contain: %s\n' "$needle" >&2
        exit 1
    }
}
assert_no_device_calls() {
    [ ! -s "$device_calls" ] || {
        cat "$device_calls" >&2
        printf 'FAIL: device command was invoked in %s\n' "$case_name" >&2
        exit 1
    }
}

for spec in '2g:2147483648' '2G:2147483648' '2Gb:2147483648' \
            '512mb:536870912' '512MB:536870912' '512mB:536870912'; do
    size=${spec%%:*}
    bytes=${spec#*:}
    new_case "dry-$size"
    run_ramd normal "$size" --dry-run >"$case_dir/output" 2>&1
    assert_output_has "Dry run OK: $bytes bytes"
    assert_no_device_calls
done
pass 'dry-run parses case-insensitive binary size forms and calls no device tools'

new_case dry-reversed
run_ramd normal --dry-run 2G >"$case_dir/output" 2>&1
assert_output_has 'Dry run OK: 2147483648 bytes'
assert_no_device_calls
pass 'dry-run accepts the flag before the positional size'

new_case short-alias-after
run_ramd normal 2G -n >"$case_dir/output" 2>&1
assert_output_has 'Dry run OK: 2147483648 bytes'
assert_no_device_calls
pass '-n is equivalent to --dry-run after the size'

new_case short-alias-before
run_ramd normal -n 2G >"$case_dir/output" 2>&1
assert_output_has 'Dry run OK: 2147483648 bytes'
assert_no_device_calls
pass '-n is equivalent to --dry-run before the size'

new_case invalid-size
expect_failure normal 1.5GiB --dry-run
assert_output_has 'invalid or unsupported size'
assert_no_device_calls
pass 'malformed size is rejected before system or device operations'

new_case pressure-warning
expect_failure pressure_warning 512MB --dry-run
assert_output_has 'memory pressure is warning'
assert_no_device_calls
pass 'warning pressure rejects the read-only plan'

new_case pressure-malformed
expect_failure pressure_malformed 512MB --dry-run
assert_output_has 'unknown or malformed'
assert_no_device_calls
pass 'malformed pressure output rejects the read-only plan'

new_case sysctl-failure
expect_failure sysctl_failure 512MB --dry-run
assert_output_has 'cannot read physical memory size'
assert_no_device_calls
pass 'failed physical-memory query rejects the read-only plan'

new_case vm-stat-failure
expect_failure vm_stat_malformed 512MB --dry-run
assert_output_has 'vm_stat output was malformed'
assert_no_device_calls
pass 'malformed available-memory output rejects the read-only plan'

new_case unsupported-linux
expect_failure linux 512MB --dry-run
assert_output_has 'only the macOS sizing prototype is supported'
assert_no_device_calls
pass 'Linux is rejected without a tmpfs fallback or device command'

new_case real-disabled
expect_failure normal 512MB
assert_output_has 'real provisioning is disabled'
assert_output_has 'no device commands were invoked'
assert_no_device_calls
pass 'real provisioning is explicitly disabled before any disk or registry command'

new_case cross-object
MOCK_SCENARIO=cross_object MOCK_DEVICE_CALLS=$case_dir/fixture-calls.log \
    "$mock_bin/ioreg" -r -k ramd-owner-token -l -w0 >"$case_dir/registry.txt"
grep -F '"ramd-owner-token" = "11111111-1111-4111-8111-111111111111"' \
    "$case_dir/registry.txt" >/dev/null
grep -F '"BSD Name" = "disk7"' "$case_dir/registry.txt" >/dev/null
expect_failure cross_object 512MB
assert_output_has 'real provisioning is disabled'
assert_no_device_calls
pass 'cross-object token and BSD-name output cannot reach any mutation command'

new_case no-arguments
expect_failure normal
assert_output_has 'Usage: ramd SIZE [--dry-run|-n]'
assert_no_device_calls
pass 'missing size prints usage without device commands'

printf '%s\n' 'All RAM-disk sizing prototype mock tests passed. No disk operations were performed.'
