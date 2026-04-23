#!/usr/bin/env bash

set -u
set -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
MESHCLI_BASE_ARGS=(-c off)
MESHCLI_CONNECT_ARGS=()
MESHCLI_SCAN_ARGS=()

PATH_FILE="$SCRIPT_DIR/paths.txt"
RUNS=10
DELAY=2
OUTPUT_DIR="$SCRIPT_DIR"
LIST_DEVICES=0
TCP_HOST=""
SERIAL_PORT=""
TCP_PORT_SET=0
BAUDRATE_SET=0
ADDRESS_SET=0
DEVICE_FILTER_SET=0
PAIR_SET=0
COMPANION_RADIO_FREQ=""
COMPANION_RADIO_BW=""
COMPANION_RADIO_SF=""
COMPANION_RADIO_CR=""

usage() {
    cat <<'EOF'
Usage: ./meshcore-trace.sh [options]

Options:
  --path-file <file>   Path list file. Default: ./paths.txt
  --runs <number>      Number of trace attempts per path. Default: 10
  --delay <seconds>    Delay between runs. Default: 2
  --output-dir <dir>   Directory for CSV and summary files. Default: current directory
  --list-devices       Run meshcli -l and exit
  --scan-timeout <s>   BLE scan timeout for --list-devices. Maps to meshcli -T
  --address <value>    BLE address or device name. Maps to meshcli -a
  --device-filter <v>  Filter MeshCore devices by name/address. Maps to meshcli -d
  --tcp-host <host>    Connect over TCP/IP. Maps to meshcli -t
  --tcp-port <port>    TCP port for --tcp-host. Maps to meshcli -p
  --serial-port <p>    Connect over serial. Maps to meshcli -s
  --baudrate <rate>    Baudrate for --serial-port. Maps to meshcli -b
  --pair               Force OS pairing for BLE. Maps to meshcli -P
  --debug              Enable meshcli debug output. Maps to meshcli -D
  --help               Show this help text
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --path-file)
            PATH_FILE="$2"
            shift 2
            ;;
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --delay)
            DELAY="$2"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --list-devices)
            LIST_DEVICES=1
            shift
            ;;
        --scan-timeout)
            MESHCLI_SCAN_ARGS+=("-T" "$2")
            shift 2
            ;;
        --address)
            MESHCLI_CONNECT_ARGS+=("-a" "$2")
            ADDRESS_SET=1
            shift 2
            ;;
        --device-filter)
            MESHCLI_SCAN_ARGS+=("-d" "$2")
            MESHCLI_CONNECT_ARGS+=("-d" "$2")
            DEVICE_FILTER_SET=1
            shift 2
            ;;
        --tcp-host)
            MESHCLI_CONNECT_ARGS+=("-t" "$2")
            TCP_HOST="$2"
            shift 2
            ;;
        --tcp-port)
            MESHCLI_CONNECT_ARGS+=("-p" "$2")
            TCP_PORT_SET=1
            shift 2
            ;;
        --serial-port)
            MESHCLI_CONNECT_ARGS+=("-s" "$2")
            SERIAL_PORT="$2"
            shift 2
            ;;
        --baudrate)
            MESHCLI_CONNECT_ARGS+=("-b" "$2")
            BAUDRATE_SET=1
            shift 2
            ;;
        --pair)
            MESHCLI_CONNECT_ARGS+=("-P")
            PAIR_SET=1
            shift
            ;;
        --debug)
            MESHCLI_BASE_ARGS+=("-D")
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v meshcli >/dev/null 2>&1; then
    echo "meshcli was not found in PATH." >&2
    exit 1
fi

if [ -n "$TCP_HOST" ] && [ -n "$SERIAL_PORT" ]; then
    echo "Choose only one transport: --tcp-host or --serial-port." >&2
    exit 1
fi

if [ "$TCP_PORT_SET" -eq 1 ] && [ -z "$TCP_HOST" ]; then
    echo "--tcp-port requires --tcp-host." >&2
    exit 1
fi

if [ "$BAUDRATE_SET" -eq 1 ] && [ -z "$SERIAL_PORT" ]; then
    echo "--baudrate requires --serial-port." >&2
    exit 1
fi

if [ -n "$TCP_HOST" ] && { [ "$ADDRESS_SET" -eq 1 ] || [ "$PAIR_SET" -eq 1 ] || [ "$DEVICE_FILTER_SET" -eq 1 ]; }; then
    echo "BLE-specific options (--address, --device-filter, --pair) cannot be combined with --tcp-host." >&2
    exit 1
fi

if [ -n "$SERIAL_PORT" ] && { [ "$ADDRESS_SET" -eq 1 ] || [ "$PAIR_SET" -eq 1 ] || [ "$DEVICE_FILTER_SET" -eq 1 ]; }; then
    echo "BLE-specific options (--address, --device-filter, --pair) cannot be combined with --serial-port." >&2
    exit 1
fi

if [ "$LIST_DEVICES" -eq 1 ]; then
    meshcli "${MESHCLI_BASE_ARGS[@]}" "${MESHCLI_SCAN_ARGS[@]}" -l
    exit $?
fi

if [ ! -f "$PATH_FILE" ]; then
    echo "Path file not found: $PATH_FILE" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

TEST_DATE=$(date "+%Y-%m-%d")
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")
CSV_FILE="$OUTPUT_DIR/meshcore-trace-$TIMESTAMP.csv"
SUMMARY_FILE="$OUTPUT_DIR/meshcore-trace-$TIMESTAMP-summary.txt"

timestamp() {
    date "+%H:%M:%S"
}

clean_output() {
    sed -E 's/\x1B\[[0-9;?]*[[:alpha:]]//g'
}

run_meshcli() {
    meshcli "${MESHCLI_BASE_ARGS[@]}" "${MESHCLI_CONNECT_ARGS[@]}" "$@"
}

extract_json_block() {
    printf '%s\n' "$1" | awk 'found || /^[[:space:]]*{/ { found=1; print }'
}

extract_json_value() {
    local key="$1"
    local json="$2"

    printf '%s\n' "$json" |
        sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p" |
        head -n 1 |
        sed -E 's/^"//; s/"$//'
}

capture_companion_settings() {
    local raw json

    raw=$(run_meshcli -j infos 2>&1 | clean_output)
    json=$(extract_json_block "$raw")

    echo "Companion settings snapshot:" >> "$SUMMARY_FILE"
    if [ -n "$json" ]; then
        COMPANION_RADIO_FREQ=$(extract_json_value "radio_freq" "$json")
        COMPANION_RADIO_BW=$(extract_json_value "radio_bw" "$json")
        COMPANION_RADIO_SF=$(extract_json_value "radio_sf" "$json")
        COMPANION_RADIO_CR=$(extract_json_value "radio_cr" "$json")

        [ -n "$COMPANION_RADIO_FREQ" ] && echo "radio_freq: $COMPANION_RADIO_FREQ" >> "$SUMMARY_FILE"
        [ -n "$COMPANION_RADIO_BW" ] && echo "radio_bw: $COMPANION_RADIO_BW" >> "$SUMMARY_FILE"
        [ -n "$COMPANION_RADIO_SF" ] && echo "radio_sf: $COMPANION_RADIO_SF" >> "$SUMMARY_FILE"
        [ -n "$COMPANION_RADIO_CR" ] && echo "radio_cr: $COMPANION_RADIO_CR" >> "$SUMMARY_FILE"
        echo >> "$SUMMARY_FILE"

        echo "Companion settings: freq=${COMPANION_RADIO_FREQ:-unknown}, bw=${COMPANION_RADIO_BW:-unknown}, sf=${COMPANION_RADIO_SF:-unknown}, cr=${COMPANION_RADIO_CR:-unknown}"
    else
        echo "unavailable" >> "$SUMMARY_FILE"
        echo >> "$SUMMARY_FILE"

        echo "Companion settings: unavailable"
    fi
}

format_average_snr() {
    awk -v value="$1" 'BEGIN { printf "%+.0fdb", value }'
}

build_average_snr_summary() {
    local sums_name="$1"
    local counts_name="$2"
    local -n sums_ref="$sums_name"
    local -n counts_ref="$counts_name"
    local parts=()
    local index average

    for index in "${!sums_ref[@]}"; do
        if [ -n "${counts_ref[$index]:-}" ] && [ "${counts_ref[$index]}" -gt 0 ]; then
            average=$(awk -v sum="${sums_ref[$index]}" -v count="${counts_ref[$index]}" 'BEGIN { printf "%.6f", sum / count }')
            parts+=("$(format_average_snr "$average")")
        fi
    done

    if [ "${#parts[@]}" -eq 0 ]; then
        echo "Average SNR unavailable"
        return
    fi

    local joined=""
    for index in "${!parts[@]}"; do
        if [ "$index" -gt 0 ]; then
            joined+=", "
        fi
        joined+="${parts[$index]}"
    done

    printf 'Average SNR %s' "$joined"
}

radio_settings_csv_value() {
    printf '%s,%s,%s,%s' \
        "$COMPANION_RADIO_FREQ" \
        "$COMPANION_RADIO_BW" \
        "$COMPANION_RADIO_SF" \
        "$COMPANION_RADIO_CR"
}

parse_result() {
    local raw="$1"

    if printf '%s\n' "$raw" | grep -Eq "Timeout waiting trace|Traceback \\(most recent call last\\)|^Error:|Not Connected"; then
        echo "FAIL|"
        return
    fi

    local trace_line
    trace_line=$(printf '%s\n' "$raw" | grep '\[' | grep -vE 'File "|\[org\.bluez|Traceback' | tail -n 1 || true)

    if [ -z "$trace_line" ]; then
        echo "FAIL|"
        return
    fi

    local snrs
    snrs=$(printf '%s\n' "$trace_line" | grep -Eo -- '-?[0-9]+\.[0-9]+' || true)

    if [ -z "$snrs" ]; then
        echo "FAIL|"
        return
    fi

    local snr_values
    snr_values=$(printf '%s\n' "$snrs" | paste -sd "," -)
    echo "OK|$snr_values"
}

trimmed_paths=()
while IFS= read -r line || [ -n "$line" ]; do
    cleaned=$(printf '%s' "$line" | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//')
    if [ -n "$cleaned" ]; then
        trimmed_paths+=("$cleaned")
    fi
done < "$PATH_FILE"

if [ "${#trimmed_paths[@]}" -eq 0 ]; then
    echo "No valid paths found in $PATH_FILE" >&2
    exit 1
fi

{
    echo "MeshCore Trace Summary"
    echo "Date: $TEST_DATE"
    echo "Path file: $PATH_FILE"
    echo "Runs per path: $RUNS"
    echo "Delay between runs: ${DELAY}s"
    echo "CSV output: $CSV_FILE"
    echo
} > "$SUMMARY_FILE"

echo "date,time,radio_settings,label,path,run,status,snr_values" > "$CSV_FILE"
capture_companion_settings

run_traces() {
    local label="$1"
    local path_value="$2"
    local success=0
    local completed_at=""
    local -a snr_sums=()
    local -a snr_counts=()

    echo
    echo "=== $label | $path_value ==="

    for i in $(seq 1 "$RUNS"); do
        local now raw parsed status snr_values radio_settings
        now=$(timestamp)

        raw=$(run_meshcli trace "$path_value" 2>&1 | clean_output)
        parsed=$(parse_result "$raw")

        status="${parsed%%|*}"
        snr_values="${parsed#*|}"
        radio_settings=$(radio_settings_csv_value)

        if [ "$status" = "OK" ]; then
            local -a snr_parts=()
            local idx

            success=$((success + 1))
            IFS=',' read -r -a snr_parts <<< "$snr_values"
            for idx in "${!snr_parts[@]}"; do
                snr_sums[$idx]=$(awk -v current="${snr_sums[$idx]:-0}" -v value="${snr_parts[$idx]}" 'BEGIN { printf "%.6f", current + value }')
                snr_counts[$idx]=$(( ${snr_counts[$idx]:-0} + 1 ))
            done

            printf '%s,%s,"%s",%s,"%s",%s,%s,"%s"\n' \
                "$TEST_DATE" "$now" "$radio_settings" "$label" "$path_value" "$i" "$status" "$snr_values" >> "$CSV_FILE"
            echo "[$now] $label run $i/$RUNS | OK   | SNRs: $snr_values | success $success/$i"
        else
            printf '%s,%s,"%s",%s,"%s",%s,%s,"%s"\n' \
                "$TEST_DATE" "$now" "$radio_settings" "$label" "$path_value" "$i" "FAIL" \
                "" >> "$CSV_FILE"
            echo "[$now] $label run $i/$RUNS | FAIL | timeout/no trace | success $success/$i"
        fi

        if [ "$i" -lt "$RUNS" ]; then
            sleep "$DELAY"
        fi
    done

    local success_rate average_snr_summary
    success_rate=$(awk "BEGIN {printf \"%.1f\", ($success/$RUNS)*100}")
    average_snr_summary=$(build_average_snr_summary snr_sums snr_counts)
    completed_at=$(timestamp)
    echo "$completed_at | $label | $path_value | $success/$RUNS success (${success_rate}%) | $average_snr_summary" >> "$SUMMARY_FILE"
    echo "--- $label complete | $success/$RUNS success (${success_rate}%) | $average_snr_summary ---"
}

path_num=1
for path_value in "${trimmed_paths[@]}"; do
    run_traces "PATH${path_num}" "$path_value"
    path_num=$((path_num + 1))
done

echo
echo "CSV results: $CSV_FILE"
echo "Summary: $SUMMARY_FILE"
