#!/bin/sh

# Read-only macOS RAM-disk sizing prototype. Keep this POSIX sh.
set -eu
LC_ALL=C
export LC_ALL

usage() {
    printf '%s\n' 'Usage: ramd SIZE [--dry-run|-dr]' 'Example: ramd 2g' '         ramd 512MB --dry-run' '         ramd 512MB -dr' >&2
}

fail() {
    printf 'ramd: %s\n' "$*" >&2
    exit 1
}

is_decimal() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

normalize_decimal() {
    decimal_value=$1
    is_decimal "$decimal_value" || return 1
    while [ "$decimal_value" != "${decimal_value#0}" ]; do
        decimal_value=${decimal_value#0}
    done
    [ -n "$decimal_value" ] || decimal_value=0
    [ "${#decimal_value}" -le 18 ] || return 1
    printf '%s\n' "$decimal_value"
}

parse_size() {
    size_input=$1
    case $size_input in
        ''|*[!0-9A-Za-z]*) return 1 ;;
    esac

    size_number=${size_input%%[!0-9]*}
    [ -n "$size_number" ] || return 1
    size_unit=${size_input#"$size_number"}
    size_unit=$(printf '%s' "$size_unit" | tr '[:upper:]' '[:lower:]')

    case $size_unit in
        b|byte|bytes) size_multiplier=1; size_limit=1099511627776 ;;
        k|kb|kib) size_multiplier=1024; size_limit=1073741824 ;;
        m|mb|mib) size_multiplier=1048576; size_limit=1048576 ;;
        g|gb|gib) size_multiplier=1073741824; size_limit=1024 ;;
        t|tb|tib) size_multiplier=1099511627776; size_limit=1 ;;
        *) return 1 ;;
    esac

    while [ "$size_number" != "${size_number#0}" ]; do
        size_number=${size_number#0}
    done
    [ -n "$size_number" ] || size_number=0
    is_decimal "$size_number" || return 1
    [ "${#size_number}" -le 13 ] || return 1
    [ "$size_number" -le "$size_limit" ] || return 1

    parsed_bytes=$((size_number * size_multiplier))
    [ "$parsed_bytes" -ge 16777216 ] || return 1
    [ $((parsed_bytes % 512)) -eq 0 ] || return 1
    parsed_sectors=$((parsed_bytes / 512))
    return 0
}

parse_args() {
    dry_run=0
    case $# in
        1) size_input=$1 ;;
        2)
            if [ "$1" = '--dry-run' ] || [ "$1" = '-dr' ]; then
                dry_run=1
                size_input=$2
            elif [ "$2" = '--dry-run' ] || [ "$2" = '-dr' ]; then
                dry_run=1
                size_input=$1
            else
                usage
                exit 64
            fi
            ;;
        *)
            usage
            exit 64
            ;;
    esac

    if ! parse_size "$size_input"; then
        usage
        fail "invalid or unsupported size: $size_input"
    fi
    requested_bytes=$parsed_bytes
    requested_sectors=$parsed_sectors
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

read_vm_stat() {
    vm_stat_output=$(vm_stat 2>/dev/null) || fail 'vm_stat failed; refusing to plan'
    vm_stat_values=$(printf '%s\n' "$vm_stat_output" | awk '
        /page size of/ {
            value = $0
            sub(/^.*page size of[[:space:]]*/, "", value)
            sub(/[[:space:]]*bytes.*$/, "", value)
            if (value ~ /^[0-9]+$/) page_size = value
            else bad = 1
        }
        /Pages free:/ { free_pages = $NF; sub(/\.$/, "", free_pages) }
        /Pages inactive:/ { inactive_pages = $NF; sub(/\.$/, "", inactive_pages) }
        /Pages speculative:/ { speculative_pages = $NF; sub(/\.$/, "", speculative_pages) }
        END {
            if (bad || page_size !~ /^[0-9]+$/ || free_pages !~ /^[0-9]+$/ ||
                inactive_pages !~ /^[0-9]+$/ || speculative_pages !~ /^[0-9]+$/) exit 1
            print page_size, free_pages, inactive_pages, speculative_pages
        }
    ') || fail 'vm_stat output was malformed; refusing to plan'

    # This is the four decimal fields emitted by the validating awk above.
    # shellcheck disable=SC2086
    set -- $vm_stat_values
    [ "$#" -eq 4 ] || fail 'vm_stat output was malformed; refusing to plan'
    page_size=$(normalize_decimal "$1") || fail 'invalid page size; refusing to plan'
    free_pages=$(normalize_decimal "$2") || fail 'invalid free-page count; refusing to plan'
    inactive_pages=$(normalize_decimal "$3") || fail 'invalid inactive-page count; refusing to plan'
    speculative_pages=$(normalize_decimal "$4") || fail 'invalid speculative-page count; refusing to plan'
    [ "$page_size" -gt 0 ] || fail 'page size must be positive; refusing to plan'

    maximum_pages=$((physical_bytes / page_size))
    [ "$maximum_pages" -gt 0 ] || fail 'page size exceeds physical memory; refusing to plan'
    available_pages=0
    for page_count in "$free_pages" "$inactive_pages" "$speculative_pages"; do
        [ "$page_count" -le "$maximum_pages" ] || fail 'vm_stat page count is inconsistent; refusing to plan'
        remaining_pages=$((maximum_pages - available_pages))
        if [ "$page_count" -gt "$remaining_pages" ]; then
            available_pages=$maximum_pages
            break
        fi
        available_pages=$((available_pages + page_count))
    done
    available_bytes=$((available_pages * page_size))
}

validate_request() {
    platform=$(uname -s 2>/dev/null) || fail 'cannot identify the operating system'
    [ "$platform" = Darwin ] || fail 'only the macOS sizing prototype is supported'

    require_command sysctl
    require_command vm_stat
    require_command awk
    require_command tr

    physical_raw=$(sysctl -n hw.memsize 2>/dev/null) || fail 'cannot read physical memory size'
    physical_bytes=$(normalize_decimal "$physical_raw") || fail 'physical memory size output was malformed'
    [ "$physical_bytes" -gt 0 ] || fail 'physical memory size must be positive'

    pressure_level=$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null) || fail 'cannot read macOS memory pressure level'
    case $pressure_level in
        1) : ;;
        2) fail 'memory pressure is warning; refusing to plan' ;;
        4) fail 'memory pressure is critical; refusing to plan' ;;
        *) fail 'memory pressure output was unknown or malformed; refusing to plan' ;;
    esac

    read_vm_stat

    max_by_physical=$((physical_bytes / 4))
    max_by_available=$((available_bytes / 2))
    [ "$requested_bytes" -le "$max_by_physical" ] || fail 'requested size exceeds one quarter of physical RAM'
    [ "$requested_bytes" -le "$max_by_available" ] || fail 'requested size exceeds half of the current reclaimable-memory estimate'
}

parse_args "$@"

if [ "$dry_run" -ne 1 ]; then
    fail 'real provisioning is disabled: safe macOS device targeting and the required UUID fields are unverified; no device commands were invoked'
fi

validate_request
printf 'Dry run OK: %s bytes (%s sectors of 512 bytes); would attach a RAM-backed device and format a Journaled HFS+ volume named RAMDisk.\n' "$requested_bytes" "$requested_sectors"
