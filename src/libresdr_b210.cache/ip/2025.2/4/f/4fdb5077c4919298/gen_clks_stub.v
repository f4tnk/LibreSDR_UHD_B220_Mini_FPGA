// Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
// Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
// --------------------------------------------------------------------------------
// Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
// Date        : Mon Mar 30 13:11:21 2026
// Host        : DESKTOP-8FU7G31 running 64-bit Debian GNU/Linux 13 (trixie)
// Command     : write_verilog -force -mode synth_stub -rename_top decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix -prefix
//               decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix_ gen_clks_stub.v
// Design      : gen_clks
// Purpose     : Stub declaration of top-level module interface
// Device      : xc7a200tfbg484-2
// --------------------------------------------------------------------------------

// This empty module with port declaration file causes synthesis tools to infer a black box for IP.
// The synthesis directives are for Synopsys Synplify support to prevent IO buffer insertion.
// Please paste the declaration into a Verilog source file or add the file as an additional source.
(* CORE_GENERATION_INFO = "gen_clks,clk_wiz_v6_0_17_0_0,{component_name=gen_clks,use_phase_alignment=true,use_min_o_jitter=false,use_max_i_jitter=false,use_dyn_phase_shift=false,use_inclk_switchover=false,use_dyn_reconfig=false,enable_axi=0,feedback_source=FDBK_AUTO,PRIMITIVE=MMCM,num_out_clk=3,clkin1_period=25.000,clkin2_period=10.0,use_power_down=false,use_reset=true,use_locked=true,use_inclk_stopped=false,feedback_type=SINGLE,CLOCK_MGR_TYPE=NA,manual_override=false}" *) 
module decalper_eb_ot_sdeen_pot_pi_dehcac_xnilix(clk_out1_40_int, clk_out2_100_bus, 
  clk_out3_200_ref_pll, reset, locked, clk_in1_40)
/* synthesis syn_black_box black_box_pad_pin="reset,locked,clk_in1_40" */
/* synthesis syn_force_seq_prim="clk_out1_40_int" */
/* synthesis syn_force_seq_prim="clk_out2_100_bus" */
/* synthesis syn_force_seq_prim="clk_out3_200_ref_pll" */;
  output clk_out1_40_int /* synthesis syn_isclock = 1 */;
  output clk_out2_100_bus /* synthesis syn_isclock = 1 */;
  output clk_out3_200_ref_pll /* synthesis syn_isclock = 1 */;
  input reset;
  output locked;
  input clk_in1_40;
endmodule
