#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# LibreSDR B220 Mini FPGA - Build monitor
# Launches Vivado batch build and polls every 60 s for progress / errors.
# Usage: ./build_and_monitor.sh
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIVADO_BIN="/usr/local/vivado/2025.2/Vivado/bin/vivado"
BUILD_TCL="$SCRIPT_DIR/build.tcl"
LOG_FILE="$SCRIPT_DIR/build_output/vivado_build.log"
JOURNAL_FILE="$SCRIPT_DIR/build_output/vivado_build.jou"
PID_FILE="$SCRIPT_DIR/build_output/vivado_build.pid"

mkdir -p "$SCRIPT_DIR/build_output"

# ── Timestamp helper ─────────────────────────────────────────────────────────
ts() { date "+%H:%M:%S"; }

# ── Progress parser ──────────────────────────────────────────────────────────
show_progress() {
    local log="$1"
    [[ ! -f "$log" ]] && return

    # Last phase line (synth/impl/route/bitstream)
    local phase  errors  critwarns  warnings
    phase=$(grep -oP '(?<=Running: )[^\n]+' "$log" 2>/dev/null | tail -1 || true)
    errors=$(grep -c '^\[ERROR\]\|^ERROR:' "$log" 2>/dev/null || true)
    critwarns=$(grep -c 'CRITICAL WARNING' "$log" 2>/dev/null || true)
    warnings=$(grep -c '^\[WARNING\]\|^WARNING:' "$log" 2>/dev/null || true)

    # Detect stage from log
    local stage="starting"
    if grep -q "write_bitstream" "$log" 2>/dev/null; then
        stage="write_bitstream"
    elif grep -q "route_design" "$log" 2>/dev/null; then
        stage="route_design"
    elif grep -q "place_design" "$log" 2>/dev/null; then
        stage="place_design"
    elif grep -q "opt_design" "$log" 2>/dev/null; then
        stage="opt_design"
    elif grep -q "synth_design" "$log" 2>/dev/null; then
        stage="synth_design"
    elif grep -q "open_project" "$log" 2>/dev/null; then
        stage="open_project"
    fi

    echo "[$(ts)] Stage: $stage | Errors: $errors | Crit-Warns: $critwarns | Warnings: $warnings"
    [[ -n "$phase" ]] && echo "         Last op: $phase"
}

# ── Error extraction ─────────────────────────────────────────────────────────
show_errors() {
    local log="$1"
    [[ ! -f "$log" ]] && return
    local n
    n=$(grep -c '^\[ERROR\]\|^ERROR:' "$log" 2>/dev/null || true)
    if [[ "$n" -gt 0 ]]; then
        echo "[$(ts)] === ERRORS DETECTED ($n) ==="
        grep -E '^\[ERROR\]|^ERROR:' "$log" | tail -20
    fi
    local cw
    cw=$(grep -c 'CRITICAL WARNING' "$log" 2>/dev/null || true)
    if [[ "$cw" -gt 0 ]]; then
        echo "[$(ts)] === CRITICAL WARNINGS ($cw) ==="
        grep 'CRITICAL WARNING' "$log" | tail -10
    fi
}

# ── Launch Vivado ─────────────────────────────────────────────────────────────
echo "[$(ts)] =========================================="
echo "[$(ts)]  LibreSDR B220 Mini FPGA Build Start"
echo "[$(ts)]  Vivado: $VIVADO_BIN"
echo "[$(ts)]  TCL:    $BUILD_TCL"
echo "[$(ts)]  Log:    $LOG_FILE"
echo "[$(ts)] =========================================="

"$VIVADO_BIN" -mode batch \
    -source  "$BUILD_TCL" \
    -log     "$LOG_FILE" \
    -journal "$JOURNAL_FILE" \
    &

BUILD_PID=$!
echo "$BUILD_PID" > "$PID_FILE"
echo "[$(ts)] Build launched (PID=$BUILD_PID)"
echo "[$(ts)] Polling every 60 seconds..."
echo ""

# ── Monitor loop ──────────────────────────────────────────────────────────────
EXIT_CODE=0
while kill -0 "$BUILD_PID" 2>/dev/null; do
    sleep 60
    show_progress "$LOG_FILE"
    show_errors   "$LOG_FILE"
    echo ""
done

wait "$BUILD_PID" && EXIT_CODE=$? || EXIT_CODE=$?

# ── Final summary ─────────────────────────────────────────────────────────────
echo ""
echo "[$(ts)] =========================================="
if [[ "$EXIT_CODE" -eq 0 ]]; then
    echo "[$(ts)]  BUILD SUCCEEDED  (exit=$EXIT_CODE)"
    # Show bitstream location
    BIT=$(find "$SCRIPT_DIR/build_output" -name "*.bit" 2>/dev/null | head -1)
    [[ -n "$BIT" ]] && echo "[$(ts)]  Bitstream: $BIT"
    # Final timing summary snippet
    if [[ -f "$SCRIPT_DIR/build_output/timing_summary.rpt" ]]; then
        echo "[$(ts)]  --- Timing Summary (first 30 lines) ---"
        head -30 "$SCRIPT_DIR/build_output/timing_summary.rpt"
    fi
else
    echo "[$(ts)]  BUILD FAILED  (exit=$EXIT_CODE)"
    show_errors "$LOG_FILE"
    echo ""
    echo "[$(ts)]  Full log: $LOG_FILE"
fi
echo "[$(ts)] =========================================="

rm -f "$PID_FILE"
exit "$EXIT_CODE"
