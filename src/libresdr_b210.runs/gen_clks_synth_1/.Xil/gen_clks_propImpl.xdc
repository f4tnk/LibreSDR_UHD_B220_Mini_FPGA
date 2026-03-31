set_property SRC_FILE_INFO {cfile:/home/f4tnk/dev/LibreSDR_UHD_B220_Mini_FPGA/src/libresdr_b210.gen/gen_clks/ip/gen_clks/gen_clks.xdc rfile:../../../libresdr_b210.gen/gen_clks/ip/gen_clks/gen_clks.xdc id:1 order:EARLY scoped_inst:inst} [current_design]
current_instance inst
set_property src_info {type:SCOPED_XDC file:1 line:54 export:INPUT save:INPUT read:READ} [current_design]
set_input_jitter [get_clocks -of_objects [get_ports clk_in1_40]] 0.250
