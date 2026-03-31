// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
// Date        : Mon Mar 30 13:11:21 2026
// Host        : DESKTOP-8FU7G31 running 64-bit Debian GNU/Linux 13 (trixie)
// Command     : write_verilog -force -mode synth_stub
//               /home/f4tnk/dev/LibreSDR_UHD_B220_Mini_FPGA/src/libresdr_b210.gen/sources_1/ip/clk_wiz_0/clk_wiz_0_stub.v
// Design      : clk_wiz_0
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tfbg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* CORE_GENERATION_INFO = "clk_wiz_0,clk_wiz_v6_0_17_0_0,{component_name=clk_wiz_0,use_phase_alignment=false,use_min_o_jitter=false,use_max_i_jitter=false,use_dyn_phase_shift=false,use_inclk_switchover=false,use_dyn_reconfig=false,enable_axi=0,feedback_source=FDBK_AUTO,PRIMITIVE=MMCM,num_out_clk=1,clkin1_period=100.000,clkin2_period=10.0,use_power_down=false,use_reset=false,use_locked=true,use_inclk_stopped=false,feedback_type=SINGLE,CLOCK_MGR_TYPE=NA,manual_override=false}" *) 
module clk_wiz_0(clk_out_200M, locked, clk_in1_10M)
/* synthesis syn_black_box black_box_pad_pin="locked,clk_in1_10M" */
/* synthesis syn_force_seq_prim="clk_out_200M" */;
  output clk_out_200M /* synthesis syn_isclock = 1 */;
  output locked;
  input clk_in1_10M;
endmodule
