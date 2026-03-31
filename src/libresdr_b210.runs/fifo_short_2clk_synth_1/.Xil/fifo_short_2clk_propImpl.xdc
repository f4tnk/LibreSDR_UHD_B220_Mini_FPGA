set_property SRC_FILE_INFO {cfile:/home/f4tnk/dev/LibreSDR_UHD_B220_Mini_FPGA/src/libresdr_b210.gen/fifo_short_2clk/ip/fifo_short_2clk/fifo_short_2clk.xdc rfile:../../../libresdr_b210.gen/fifo_short_2clk/ip/fifo_short_2clk/fifo_short_2clk.xdc id:1 order:EARLY scoped_inst:U0} [current_design]
set_property SRC_FILE_INFO {cfile:/usr/local/vivado/2025.2/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_gray.tcl rfile:../../../../../../../../usr/local/vivado/2025.2/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_gray.tcl id:2 order:LATE scoped_inst:U0/inst_fifo_gen/gconvfifo.rf/grf.rf/gntv_or_sync_fifo.gcx.clkx/rd_pntr_cdc_inst unmanaged:yes} [current_design]
set_property SRC_FILE_INFO {cfile:/usr/local/vivado/2025.2/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_gray.tcl rfile:../../../../../../../../usr/local/vivado/2025.2/data/ip/xpm/xpm_cdc/tcl/xpm_cdc_gray.tcl id:3 order:LATE scoped_inst:U0/inst_fifo_gen/gconvfifo.rf/grf.rf/gntv_or_sync_fifo.gcx.clkx/wr_pntr_cdc_inst unmanaged:yes} [current_design]
current_instance U0
set_property src_info {type:SCOPED_XDC file:1 line:64 export:INPUT save:INPUT read:READ} [current_design]
create_waiver  -type CDC -id CDC-1 -user fifo_generator  -to [get_pins -hierarchical -filter {NAME =~ *gconvfifo.rf/grf.rf/gntv_or_sync_fifo.mem/gdm.dm_gen.dm/gpr1.dout_i_reg[0]/D}] -description {Waiving CDC-1 warning because it is treating the asynchronous LUTRAM read to the read register path as CDC path which is not a real CDC}
current_instance
current_instance U0/inst_fifo_gen/gconvfifo.rf/grf.rf/gntv_or_sync_fifo.gcx.clkx/rd_pntr_cdc_inst
set_property src_info {type:SCOPED_XDC file:2 line:23 export:INPUT save:NONE read:READ} [current_design]
create_waiver -internal -scoped -type CDC -id {CDC-6} -user "xpm_cdc" -tags "1009444" -desc "The CDC-6 warning is waived as it is safe in the context of XPM_CDC_GRAY." -from [get_pins -quiet {src_gray_ff_reg*/C}] -to [get_pins -quiet {dest_graysync_ff_reg*/D}]
current_instance
current_instance U0/inst_fifo_gen/gconvfifo.rf/grf.rf/gntv_or_sync_fifo.gcx.clkx/wr_pntr_cdc_inst
set_property src_info {type:SCOPED_XDC file:3 line:23 export:INPUT save:NONE read:READ} [current_design]
create_waiver -internal -scoped -type CDC -id {CDC-6} -user "xpm_cdc" -tags "1009444" -desc "The CDC-6 warning is waived as it is safe in the context of XPM_CDC_GRAY." -from [get_pins -quiet {src_gray_ff_reg*/C}] -to [get_pins -quiet {dest_graysync_ff_reg*/D}]
