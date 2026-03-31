-- Copyright 1986-2022 Xilinx, Inc. All Rights Reserved.
-- Copyright 2022-2025 Advanced Micro Devices, Inc. All Rights Reserved.
-- --------------------------------------------------------------------------------
-- Tool Version: Vivado v.2025.2 (lin64) Build 6299465 Fri Nov 14 12:34:56 MST 2025
-- Date        : Mon Mar 30 13:11:22 2026
-- Host        : DESKTOP-8FU7G31 running 64-bit Debian GNU/Linux 13 (trixie)
-- Command     : write_vhdl -force -mode synth_stub
--               /home/f4tnk/dev/LibreSDR_UHD_B220_Mini_FPGA/src/libresdr_b210.gen/gen_clks/ip/gen_clks/gen_clks_stub.vhdl
-- Design      : gen_clks
-- Purpose     : Stub declaration of top-level module interface
-- Device      : xc7a200tfbg484-2
-- --------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity gen_clks is
  Port ( 
    clk_out1_40_int : out STD_LOGIC;
    clk_out2_100_bus : out STD_LOGIC;
    clk_out3_200_ref_pll : out STD_LOGIC;
    reset : in STD_LOGIC;
    locked : out STD_LOGIC;
    clk_in1_40 : in STD_LOGIC
  );

  attribute CORE_GENERATION_INFO : string;
  attribute CORE_GENERATION_INFO of gen_clks : entity is "gen_clks,clk_wiz_v6_0_17_0_0,{component_name=gen_clks,use_phase_alignment=true,use_min_o_jitter=false,use_max_i_jitter=false,use_dyn_phase_shift=false,use_inclk_switchover=false,use_dyn_reconfig=false,enable_axi=0,feedback_source=FDBK_AUTO,PRIMITIVE=MMCM,num_out_clk=3,clkin1_period=25.000,clkin2_period=10.0,use_power_down=false,use_reset=true,use_locked=true,use_inclk_stopped=false,feedback_type=SINGLE,CLOCK_MGR_TYPE=NA,manual_override=false}";
end gen_clks;

architecture stub of gen_clks is
  attribute syn_black_box : boolean;
  attribute black_box_pad_pin : string;
  attribute syn_black_box of stub : architecture is true;
  attribute black_box_pad_pin of stub : architecture is "clk_out1_40_int,clk_out2_100_bus,clk_out3_200_ref_pll,reset,locked,clk_in1_40";
begin
end;
