# LibreSDR B220 Mini FPGA - Vivado batch build script
# Usage: vivado -mode batch -source build.tcl

set script_dir [file dirname [file normalize [info script]]]
set project_file "$script_dir/src/libresdr_b210.xpr"
set output_dir  "$script_dir/build_output"

# ── Create output directory ──────────────────────────────────────────────────
file mkdir $output_dir

proc log {msg} {
    set ts [clock format [clock seconds] -format "%H:%M:%S"]
    puts "\[$ts\] $msg"
    flush stdout
}

log "Opening project: $project_file"
open_project $project_file

# V10: Ensure new cic_droop_comp.v is in the project sources
set droop_src "$script_dir/src/libresdr_b210.srcs/sources_1/imports/lib/dsp/cic_droop_comp.v"
if {[file exists $droop_src]} {
    set existing [get_files -quiet *cic_droop_comp.v]
    if {$existing eq ""} {
        log "Adding cic_droop_comp.v to project..."
        add_files -norecurse $droop_src
        set_property file_type {Verilog} [get_files $droop_src]
    }
}

# ── Upgrade locked IPs (handles Vivado version upgrade 2025.1 → 2025.2) ─────
log "Checking IP status..."
set locked_ips [get_ips -filter {IS_LOCKED == 1}]
if {[llength $locked_ips] > 0} {
    log "Upgrading [llength $locked_ips] locked IP(s): $locked_ips"
    upgrade_ip -quiet $locked_ips
}

# Regenerate output products for all IPs (ensures synthesis stubs exist)
log "Generating IP output products..."
set all_ips [get_ips]
if {[llength $all_ips] > 0} {
    generate_target all $all_ips
    export_ip_user_files -of_objects $all_ips -no_script -sync -force -quiet
    log "IP generation done."
}

# ── SYNTHESIS ────────────────────────────────────────────────────────────────
log "Starting synthesis (strategy: Vivado Default)..."
reset_run synth_1
# V9: Use default synthesis strategy to avoid retiming issues
# Retiming can move registers across combinational logic, potentially breaking
# control register bus timing or strobe pipeline ordering.
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]
log "Synthesis status: $synth_status"

if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    log "ERROR: Synthesis did not complete successfully."
    set msgs [get_msg_config -severity {ERROR} -count]
    log "Error count: $msgs"
    # Print all errors to the log
    foreach msg [get_msgs -severity ERROR] {
        log "  SYN-ERROR: [get_property MSG_TEXT $msg]"
    }
    exit 1
}

# Report timing and resource usage after synthesis
open_run synth_1 -name synth_1
report_utilization -file "$output_dir/post_synth_utilization.rpt"
log "Synthesis complete. Utilization report: $output_dir/post_synth_utilization.rpt"

# ── IMPLEMENTATION ────────────────────────────────────────────────────────────
log "Starting implementation (strategy: Vivado Default)..."
reset_run impl_1
# V9: Use default implementation strategy
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]
log "Implementation status: $impl_status"

if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    log "ERROR: Implementation did not complete successfully."
    foreach msg [get_msgs -severity ERROR] {
        log "  IMPL-ERROR: [get_property MSG_TEXT $msg]"
    }
    exit 2
}

# ── POST-IMPLEMENTATION REPORTS ──────────────────────────────────────────────
open_run impl_1

report_timing_summary -max_paths 20 -file "$output_dir/timing_summary.rpt"
report_utilization    -file "$output_dir/post_impl_utilization.rpt"
report_drc            -file "$output_dir/drc.rpt"
report_power          -file "$output_dir/power.rpt"

# ── GENERATE .BIN FILE ────────────────────────────────────────────────────────
# The project may not generate .bin by default; force it from checkpoint.
log "Generating raw binary bitstream (.bin)..."
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
write_bitstream -bin_file -force "$output_dir/libresdr_b220"
log "Bitstream generated: $output_dir/libresdr_b220.bit + .bin"

# ── COPY BITSTREAM ────────────────────────────────────────────────────────────
# (kept for backward compatibility — files are already in output_dir from write_bitstream above)

log "Build COMPLETED successfully."
exit 0
