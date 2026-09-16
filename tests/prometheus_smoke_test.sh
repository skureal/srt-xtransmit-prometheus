#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$ROOT_DIR/_build/bin/srt-xtransmit-prometheus}"

TMPDIR_TEST="$(mktemp -d)"
PIDS=()

cleanup()
{
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done

    for pid in "${PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done

    rm -rf "$TMPDIR_TEST"
}

stop_processes()
{
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null || true
    done

    for pid in "${PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done

    PIDS=()
}

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

pass()
{
    echo "PASS: $*"
}

wait_http()
{
    local port="$1"

    for _ in $(seq 1 50); do
        if curl -sf "http://127.0.0.1:${port}/metrics" >/dev/null 2>&1; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}

wait_metric()
{
    local port="$1"
    local pattern="$2"

    for _ in $(seq 1 50); do
        if curl -sf "http://127.0.0.1:${port}/metrics" \
            | grep -q "$pattern"; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}

wait_positive_metric()
{
    local port="$1"
    local pattern="$2"

    for _ in $(seq 1 50); do
        local value

        value="$(
            curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null \
                | grep "$pattern" \
                | head -1 \
                | awk '{print $2}'
        )"

        if [[ -n "${value}" ]] && awk -v v="${value}" 'BEGIN { exit !(v > 0) }'; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}

wait_zero_metric()
{
    local port="$1"
    local pattern="$2"

    for _ in $(seq 1 50); do
        local value

        value="$(
            curl -sf "http://127.0.0.1:${port}/metrics" 2>/dev/null \
                | grep "$pattern" \
                | head -1 \
                | awk '{print $2}'
        )"

        if [[ -n "${value}" ]] && \
           awk -v v="${value}" 'BEGIN { exit !(v == 0) }'; then
            return 0
        fi

        sleep 0.2
    done

    return 1
}


metric_must_not_exist()
{
    local port="$1"
    local pattern="$2"

    if curl -sf "http://127.0.0.1:${port}/metrics" \
        | grep -q "$pattern"; then
        return 1
    fi

    return 0
}

trap cleanup EXIT INT TERM


echo "========================================"
echo "srt-xtransmit-prometheus regression test"
echo "========================================"
echo

[[ -x "$BIN" ]] || fail "Binary not found: $BIN"

echo "Binary:"
"$BIN" --version
echo


#
# Test 1
# receive: automatic Prometheus port
#

echo "TEST 1: receive automatic Prometheus port"

"$BIN" receive \
    "srt://:4200" \
    >"$TMPDIR_TEST/receive-auto.log" 2>&1 &

PIDS+=("$!")

wait_http 4200 \
    || fail "Prometheus exporter did not start on TCP/4200"

wait_metric 4200 \
    'srt_active_connections{direction="input"} 0' \
    || fail "Initial receive connection count is not zero"

pass "receive exporter automatically uses TCP/4200"


#
# Connect generator
#

"$BIN" generate \
    -o "srt://127.0.0.1:4200" \
    --sendrate 10Mbps \
    --duration 10 \
    --stats-output-port 14201 \
    >"$TMPDIR_TEST/generate-test1.log" 2>&1 &

PIDS+=("$!")

wait_http 14201 \
    || fail "Generator Prometheus exporter did not start"

wait_metric 4200 \
    'srt_active_connections{direction="input"} 1' \
    || fail "Receive socket was not registered"

wait_metric 14201 \
    'srt_active_connections{direction="output"} 1' \
    || fail "Generate socket was not registered"

wait_positive_metric 4200 \
    '^srt_mbps_recv_rate{direction="input"' \
    || fail "Receive bitrate did not become positive"

wait_positive_metric 14201 \
    '^srt_mbps_send_rate{direction="output"' \
    || fail "Send bitrate did not become positive"

pass "receive and generate expose live SRT metrics"

stop_processes


#
# Test 2
# generate: automatic Prometheus port
#

echo
echo "TEST 2: generate automatic Prometheus port"

"$BIN" receive \
    "srt://:4220" \
    --stats-input-port 14220 \
    >"$TMPDIR_TEST/receive-test2.log" 2>&1 &

PIDS+=("$!")

wait_http 14220 \
    || fail "Test receiver did not start"

"$BIN" generate \
    -o "srt://127.0.0.1:4220" \
    --sendrate 10Mbps \
    --duration 10 \
    >"$TMPDIR_TEST/generate-auto.log" 2>&1 &

PIDS+=("$!")

wait_http 4220 \
    || fail "Generator did not automatically use TCP/4220"

wait_metric 4220 \
    'srt_active_connections{direction="output"} 1' \
    || fail "Output SRT socket not visible on automatic exporter"

wait_positive_metric 4220 \
    '^srt_mbps_send_rate{direction="output"' \
    || fail "Automatic generate exporter has no send rate"

pass "generate exporter automatically uses destination SRT port"

stop_processes


#
# Test 3
# Exclusive Prometheus TCP port
#

echo
echo "TEST 3: Prometheus TCP port collision"

"$BIN" receive \
    "srt://:4210" \
    --stats-input-port 14210 \
    >"$TMPDIR_TEST/collision-owner.log" 2>&1 &

PIDS+=("$!")

wait_http 14210 \
    || fail "First exporter did not start on TCP/14210"

set +e

COLLISION_OUTPUT="$(
    timeout 3 "$BIN" receive \
        "srt://:4211" \
        --stats-input-port 14210 \
        2>&1
)"

set -e

echo "$COLLISION_OUTPUT" \
    | grep -q 'Failed to bind Prometheus exporter TCP port 14210' \
    || fail "Second process was not rejected on occupied TCP/14210"

pass "Prometheus exporter ports are exclusive"

stop_processes


#
# Test 4
# route: independent input and output exporters
#

echo
echo "TEST 4: route input/output exporters"

#
# Final receiver for route output
#

"$BIN" receive \
    "srt://:4400" \
    --stats-input-port 14400 \
    >"$TMPDIR_TEST/route-receiver.log" 2>&1 &

PIDS+=("$!")

wait_http 14400 \
    || fail "Route destination receiver did not start"


#
# Router
#

"$BIN" route \
    -i "srt://:4300" \
    -o "srt://127.0.0.1:4400" \
    --stats-input-port 14301 \
    --stats-output-port 14302 \
    >"$TMPDIR_TEST/route.log" 2>&1 &

PIDS+=("$!")

wait_http 14301 \
    || fail "Route input exporter did not start"

wait_http 14302 \
    || fail "Route output exporter did not start"


#
# Generator feeding route input
#

"$BIN" generate \
    -o "srt://127.0.0.1:4300" \
    --sendrate 10Mbps \
    --duration 10 \
    --stats-output-port 14300 \
    >"$TMPDIR_TEST/route-generator.log" 2>&1 &

PIDS+=("$!")

wait_metric 14301 \
    'srt_active_connections{direction="input"} 1' \
    || fail "Route input socket was not registered"

wait_metric 14302 \
    'srt_active_connections{direction="output"} 1' \
    || fail "Route output socket was not registered"

wait_positive_metric 14301 \
    '^srt_mbps_recv_rate{direction="input"' \
    || fail "Route input has no receive bitrate"

wait_positive_metric 14302 \
    '^srt_mbps_send_rate{direction="output"' \
    || fail "Route output has no send bitrate"

pass "route exposes independent input and output statistics"

stop_processes

#
# Test 5
# xtransmit payload metrics
#

echo
echo "TEST 5: xtransmit payload metrics"


#
# Test 5a
# Payload metrics must NOT appear without --enable-metrics
#

echo "  5a: metrics disabled"

"$BIN" receive \
    "srt://:4500?latency=120" \
    --stats-input-port 14500 \
    >"$TMPDIR_TEST/metrics-disabled-receiver.log" 2>&1 &

PIDS+=("$!")

wait_http 14500 \
    || fail "Metrics-disabled receiver exporter did not start"


"$BIN" generate \
    -o "srt://127.0.0.1:4500?latency=120" \
    --sendrate 10Mbps \
    --duration 5 \
    --stats-output-port 14501 \
    >"$TMPDIR_TEST/metrics-disabled-generator.log" 2>&1 &

PIDS+=("$!")


wait_metric 14500 \
    'srt_active_connections{direction="input"} 1' \
    || fail "Metrics-disabled receiver did not get an SRT connection"


#
# Give the stream a moment to transfer packets.
#

sleep 1


metric_must_not_exist 14500 \
    '^srt_xtransmit_pkt_received_total{' \
    || fail "Payload metrics appeared although --enable-metrics was disabled"

metric_must_not_exist 14500 \
    '^srt_xtransmit_us_latency_avg{' \
    || fail "Latency metrics appeared although --enable-metrics was disabled"


pass "no payload metrics without --enable-metrics"

stop_processes


#
# Test 5b
# Payload metrics enabled
#

echo "  5b: metrics enabled"

"$BIN" receive \
    "srt://:4510?latency=120" \
    --enable-metrics \
    --stats-input-port 14510 \
    >"$TMPDIR_TEST/metrics-enabled-receiver.log" 2>&1 &

PIDS+=("$!")

wait_http 14510 \
    || fail "Metrics-enabled receiver exporter did not start"


"$BIN" generate \
    -o "srt://127.0.0.1:4510?latency=120" \
    --sendrate 10Mbps \
    --duration 10 \
    --enable-metrics \
    --stats-output-port 14511 \
    >"$TMPDIR_TEST/metrics-enabled-generator.log" 2>&1 &

PIDS+=("$!")


wait_http 14511 \
    || fail "Metrics-enabled generator exporter did not start"


wait_metric 14510 \
    'srt_active_connections{direction="input"} 1' \
    || fail "Metrics-enabled receiver did not get an SRT connection"


#
# Payload metrics must become available on receiver.
#

wait_positive_metric 14510 \
    '^srt_xtransmit_pkt_received_total{direction="input"' \
    || fail "xtransmit pkt_received_total did not become positive"


wait_positive_metric 14510 \
    '^srt_xtransmit_us_latency_avg{direction="input"' \
    || fail "xtransmit latency_avg did not become positive"


#
# Check that all expected metrics exist.
#

for metric in \
    srt_xtransmit_us_latency_min \
    srt_xtransmit_us_latency_max \
    srt_xtransmit_us_latency_avg \
    srt_xtransmit_us_jitter \
    srt_xtransmit_us_delay_factor \
    srt_xtransmit_pkt_received_total \
    srt_xtransmit_pkt_lost_total \
    srt_xtransmit_pkt_reordered_total \
    srt_xtransmit_pkt_reorder_distance \
    srt_xtransmit_pkt_checksum_error_total \
    srt_xtransmit_pkt_length_error_total
do

    wait_metric 14510 \
        "^${metric}{direction=\"input\"" \
        || fail "Expected payload metric missing: ${metric}"

done


#
# localhost test should normally be loss/error free.
#

wait_zero_metric 14510 \
    '^srt_xtransmit_pkt_lost_total{direction="input"' \
    || fail "Unexpected payload packet loss on localhost test"


wait_zero_metric 14510 \
    '^srt_xtransmit_pkt_checksum_error_total{direction="input"' \
    || fail "Unexpected checksum errors on localhost test"


wait_zero_metric 14510 \
    '^srt_xtransmit_pkt_length_error_total{direction="input"' \
    || fail "Unexpected payload length errors on localhost test"


#
# Payload analysis belongs to the receiver.
# The generator must not expose latency metrics itself.
#

metric_must_not_exist 14511 \
    '^srt_xtransmit_us_latency_avg{' \
    || fail "Generator unexpectedly exports receiver payload latency metrics"


pass "xtransmit payload metrics are exported by the receiver"

stop_processes


#
# Test 6
# Traditional metrics CSV + Prometheus in parallel
#

echo
echo "TEST 6: metricsfile + Prometheus compatibility"

METRICS_CSV="$TMPDIR_TEST/xtransmit-metrics.csv"

"$BIN" receive \
    "srt://:4520?latency=120" \
    --enable-metrics \
    --metricsfile "$METRICS_CSV" \
    --metricsfreq 1s \
    --stats-input-port 14520 \
    >"$TMPDIR_TEST/metricsfile-receiver.log" 2>&1 &

PIDS+=("$!")

wait_http 14520 \
    || fail "Metricsfile receiver exporter did not start"


"$BIN" generate \
    -o "srt://127.0.0.1:4520?latency=120" \
    --sendrate 10Mbps \
    --duration 8 \
    --enable-metrics \
    --stats-output-port 14521 \
    >"$TMPDIR_TEST/metricsfile-generator.log" 2>&1 &

PIDS+=("$!")


wait_metric 14520 \
    'srt_active_connections{direction="input"} 1' \
    || fail "Metricsfile test did not establish SRT connection"


#
# Prometheus payload metrics must work while metrics_writer is active.
#

wait_positive_metric 14520 \
    '^srt_xtransmit_pkt_received_total{direction="input"' \
    || fail "Prometheus payload metrics unavailable with --metricsfile"


wait_positive_metric 14520 \
    '^srt_xtransmit_us_latency_avg{direction="input"' \
    || fail "Prometheus latency unavailable with --metricsfile"


#
# Wait until the CSV writer has produced header + data rows.
#

for _ in $(seq 1 50); do
    if [[ -f "$METRICS_CSV" ]] && \
       [[ "$(wc -l < "$METRICS_CSV")" -ge 3 ]]; then
        break
    fi

    sleep 0.2
done


[[ -f "$METRICS_CSV" ]] \
    || fail "Metrics CSV file was not created"


[[ "$(wc -l < "$METRICS_CSV")" -ge 3 ]] \
    || fail "Metrics CSV did not contain enough samples"


#
# Validate CSV header.
#

head -1 "$METRICS_CSV" \
    | grep -q \
    'Timepoint,iConn,usLatencyMin,usLatencyMax,usLatencyAvg,usJitter,usDelayFactor,pktReceived,pktLost,pktReordered,pktReorderDist,pktChecksumError,pktLengthError' \
    || fail "Unexpected metrics CSV header"


#
# At least one CSV sample must contain received packets.
#

awk -F',' '
    NR > 1 && $8 > 0 {
        found=1
    }
    END {
        exit !found
    }
' "$METRICS_CSV" \
    || fail "Metrics CSV never reported received packets"


#
# Prometheus must still work after several CSV reporting intervals.
#

sleep 2

wait_positive_metric 14520 \
    '^srt_xtransmit_pkt_received_total{direction="input"' \
    || fail "Prometheus payload metrics stopped while CSV writer was active"


metric_must_not_exist 14521 \
    '^srt_xtransmit_us_latency_avg{' \
    || fail "Generator unexpectedly exports receiver payload metrics"


pass "metricsfile and Prometheus payload metrics work in parallel"

stop_processes

echo
echo "========================================"
echo "ALL TESTS PASSED"
echo "========================================"
