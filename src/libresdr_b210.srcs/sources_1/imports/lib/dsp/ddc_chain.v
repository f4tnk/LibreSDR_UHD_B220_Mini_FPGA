//
// Copyright 2011-2013 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//


//! The USRP digital down-conversion chain

module ddc_chain
  #(
    parameter BASE = 0,
    parameter DSPNO = 0,
    parameter WIDTH = 24,
    parameter NEW_HB_DECIM = 0,
    parameter DEVICE = "SPARTAN6"
  )
  (input clk, input rst, input clr,
   input 	     set_stb, input [7:0] set_addr, input [31:0] set_data,

   // From RX frontend
   input [WIDTH-1:0] rx_fe_i,
   input [WIDTH-1:0] rx_fe_q,

   // To RX control
   output [31:0] sample,
   input 	     run,
   output 	     strobe,
   output [31:0]     debug
   );

   localparam  cwidth = 25;
   localparam  zwidth = 24;

   wire [31:0] phase_inc;
   wire [15:0] phase_inc_hi;     // V2: upper 16 bits for 48-bit NCO
   reg [47:0]  phase;            // V2: 48-bit phase accumulator

   wire [17:0] scale_factor;
   wire [cwidth-1:0] to_cordic_i, to_cordic_q;
   wire [cwidth-1:0] i_cordic, q_cordic;
   reg  [WIDTH-1:0] i_cordic_pipe, q_cordic_pipe;
   wire [WIDTH-1:0] i_cic, q_cic;


   wire        strobe_cic, strobe_hb1, strobe_hb2;
   wire        strobe_hb3;       // V2: 3rd halfband strobe
   wire        enable_hb1, enable_hb2;
   wire        enable_hb3;       // V2: 3rd halfband enable
   wire [7:0]  cic_decim_rate;

   reg [WIDTH-1:0]  rx_fe_i_mux, rx_fe_q_mux;
   wire        realmode;
   wire        swap_iq;
   wire        invert_i;
   wire        invert_q;

   setting_reg #(.my_addr(BASE+0)) sr_0
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(phase_inc),.changed());

   setting_reg #(.my_addr(BASE+1), .width(18)) sr_1
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(scale_factor),.changed());

   // V2: bit layout {enable_hb3[10], enable_hb1[9], enable_hb2[8], cic_decim_rate[7:0]}
   // UHD driver writes hb0<<9 | hb1<<8 — hb3 at bit 10 is optional (0=bypassed)
   setting_reg #(.my_addr(BASE+2), .width(11)) sr_2
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out({enable_hb3, enable_hb1, enable_hb2, cic_decim_rate}),.changed());

   setting_reg #(.my_addr(BASE+3), .width(4)) sr_3
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out({invert_i,invert_q,realmode,swap_iq}),.changed());

   // DC offset correction control (enabled by default at reset)
   wire dc_offset_bypass;
   setting_reg #(.my_addr(BASE+5), .width(1)) sr_dc_offset
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(dc_offset_bypass),.changed());

   // V2: IQ imbalance correction coefficients
   wire [17:0] iq_alpha;  // Amplitude correction (Q2.16, 1.0 = 0x10000)
   wire [17:0] iq_beta;   // Phase correction     (Q2.16, 0.0 = 0x00000)

   // V10: TPDF dither LFSR — eliminates CIC idle tones
   // TPDF (triangular PDF) ±2 LSB: sum of two independent RPDF ±1 LSB sources
   // Provides better spectral whitening than single RPDF at negligible SNR cost
   reg [15:0] lfsr_a = 16'hACE1;
   reg [15:0] lfsr_b = 16'h7B3F;
   always @(posedge clk)
     if (rst) begin
       lfsr_a <= 16'hACE1;
       lfsr_b <= 16'h7B3F;
     end else begin
       lfsr_a <= {lfsr_a[14:0], lfsr_a[15] ^ lfsr_a[13] ^ lfsr_a[12] ^ lfsr_a[10]};
       lfsr_b <= {lfsr_b[14:0], lfsr_b[15] ^ lfsr_b[14] ^ lfsr_b[12] ^ lfsr_b[3]};
     end
   setting_reg #(.my_addr(BASE+6), .width(18), .at_reset(18'h10000)) sr_iq_alpha
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(iq_alpha),.changed());
   setting_reg #(.my_addr(BASE+7), .width(18), .at_reset(18'h00000)) sr_iq_beta
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(iq_beta),.changed());

   // V2: NCO 48-bit upper phase increment (default 0 = backward compatible 32-bit)
   setting_reg #(.my_addr(BASE+8), .width(16)) sr_phase_hi
     (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
      .in(set_data),.out(phase_inc_hi),.changed());

   // MUX so we can do realmode signals on either input

   always @(posedge clk)
     if(swap_iq)
       begin
          rx_fe_i_mux <= invert_i ? ~rx_fe_q : rx_fe_q;
          rx_fe_q_mux <= realmode ? {WIDTH{1'b0}} : invert_q ? ~rx_fe_i : rx_fe_i;
       end
     else
       begin
	  rx_fe_i_mux <= invert_i ? ~rx_fe_i : rx_fe_i;
          rx_fe_q_mux <= realmode ? {WIDTH{1'b0}} : invert_q ? ~rx_fe_q : rx_fe_q;
       end

   // DC offset correction - removes DC component from RX signal
   // Enabled by default (bypass=0). Write 1 to BASE+5 to disable.
   // Cutoff frequency ≈ fs/(2*pi*2^20) ≈ 9 Hz at 61.44 MSPS
   wire [WIDTH-1:0] rx_fe_i_dc, rx_fe_q_dc;
   wire strobe_dc_i, strobe_dc_q;

   dc_offset_correct #(.WIDTH(WIDTH), .ALPHA(20)) dc_correct_i
     (.clk(clk), .rst(rst), .bypass(dc_offset_bypass),
      .strobe_in(1'b1), .in(rx_fe_i_mux), .out(rx_fe_i_dc), .strobe_out(strobe_dc_i));

   dc_offset_correct #(.WIDTH(WIDTH), .ALPHA(20)) dc_correct_q
     (.clk(clk), .rst(rst), .bypass(dc_offset_bypass),
      .strobe_in(1'b1), .in(rx_fe_q_mux), .out(rx_fe_q_dc), .strobe_out(strobe_dc_q));

   // V2: IQ imbalance correction — after DC offset, before CORDIC
   //   I_out = alpha * I_in
   //   Q_out = beta  * I_in + Q_in
   // Default: alpha=1.0 (0x10000), beta=0.0 → transparent
   wire [WIDTH-1:0] rx_fe_i_iq, rx_fe_q_iq;
   wire strobe_iq;

   iq_balance #(.WIDTH(WIDTH), .DEVICE(DEVICE)) iq_bal
     (.clk(clk), .rst(rst),
      .alpha(iq_alpha), .beta(iq_beta),
      .strobe_in(1'b1),
      .i_in(rx_fe_i_dc), .q_in(rx_fe_q_dc),
      .i_out(rx_fe_i_iq), .q_out(rx_fe_q_iq),
      .strobe_out(strobe_iq));

   // V2: NCO — 48-bit phase accumulator for sub-Hz resolution
   // freq_resolution = fs / 2^48 ≈ 0.00022 Hz @ 61.44 MSPS
   always @(posedge clk)
     if(rst)
       phase <= 0;
     else if(~run)
       phase <= 0;
     else
       phase <= phase + {phase_inc_hi, phase_inc};

   // CORDIC  24-bit I/O
   // (Algorithmic gain through CORDIC => 1.647 * 0.5 = 0.8235)
   // (Worst case gain through rotation => SQRT(2) = 1.4142)
   // Total worst case gain => 0.8235 * 1.4142 = 1.1646
   // So add an extra MSB bit for word growth.

   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_i (.in(rx_fe_i_iq), .out(to_cordic_i));
   sign_extend #(.bits_in(WIDTH), .bits_out(cwidth)) sign_extend_cordic_q (.in(rx_fe_q_iq), .out(to_cordic_q));

   cordic_z24 #(.bitwidth(cwidth))
   cordic(.clock(clk), .reset(rst), .enable(run),
	  .xi(to_cordic_i),. yi(to_cordic_q), .zi(phase[47:48-zwidth]),
	  .xo(i_cordic),.yo(q_cordic),.zo() );

   // V3: Round 25→24 bit (was truncation) + add RPDF dither for CIC idle tones
   wire [23:0] i_cordic_rounded = i_cordic[24:1] + {23'b0, i_cordic[0]};
   wire [23:0] q_cordic_rounded = q_cordic[24:1] + {23'b0, q_cordic[0]};
   // Overflow-safe: if round would wrap max positive, saturate
   wire i_cord_ovf = ~i_cordic[24] & (&i_cordic[23:1]) & i_cordic[0];
   wire q_cord_ovf = ~q_cordic[24] & (&q_cordic[23:1]) & q_cordic[0];

   // V10: TPDF dither injection — ±2 LSB triangular PDF
   // dither_val = rpdf_a + rpdf_b - 1 ∈ {-1, 0, +1} with triangular probability
   // Suppress dither when signal is at min/max to prevent wrap
   wire [WIDTH-1:0] i_cord_rnd = i_cord_ovf ? i_cordic[24:1] : i_cordic_rounded;
   wire [WIDTH-1:0] q_cord_rnd = q_cord_ovf ? q_cordic[24:1] : q_cordic_rounded;
   wire i_at_min = i_cord_rnd[WIDTH-1] & ~(|i_cord_rnd[WIDTH-2:0]);
   wire q_at_min = q_cord_rnd[WIDTH-1] & ~(|q_cord_rnd[WIDTH-2:0]);
   wire i_at_max = ~i_cord_rnd[WIDTH-1] & (&i_cord_rnd[WIDTH-2:0]);
   wire q_at_max = ~q_cord_rnd[WIDTH-1] & (&q_cord_rnd[WIDTH-2:0]);
   // TPDF: sum of two independent bits → {0,1,2}, subtract 1 → {-1,0,+1}
   wire signed [1:0] i_dith_val = {1'b0, lfsr_a[0]} + {1'b0, lfsr_b[0]} - 2'sd1;
   wire signed [1:0] q_dith_val = {1'b0, lfsr_a[8]} + {1'b0, lfsr_b[8]} - 2'sd1;
   // Clamp: suppress +1 at max, suppress -1 at min
   wire signed [1:0] i_dith_safe = (i_at_max && i_dith_val > 0) ? 2'sd0 :
                                   (i_at_min && i_dith_val < 0) ? 2'sd0 : i_dith_val;
   wire signed [1:0] q_dith_safe = (q_at_max && q_dith_val > 0) ? 2'sd0 :
                                   (q_at_min && q_dith_val < 0) ? 2'sd0 : q_dith_val;

   always @(posedge clk) begin
      i_cordic_pipe <= i_cord_rnd + {{(WIDTH-2){i_dith_safe[1]}}, i_dith_safe};
      q_cordic_pipe <= q_cord_rnd + {{(WIDTH-2){q_dith_safe[1]}}, q_dith_safe};
   end


   // CIC decimator  24 bit I/O
   // Applies crude 1/(2^N) right shift gain compensation internally to prevent excesive downstream word growth.
   // Output gain is = algo_gain/(POW(2,CEIL(LOG2(algo_gain))) where algo_gain is = cic_decim_rate^4
   // Thus output gain is <= 1.0 and no word growth occurs.
   cic_strober cic_strober(.clock(clk),.reset(rst),.enable(run),.rate(cic_decim_rate),
			   .strobe_fast(1'b1),.strobe_slow(strobe_cic) );

   cic_decim #(.bw(WIDTH))
     decim_i (.clock(clk),.reset(rst),.enable(run),
	      .rate(cic_decim_rate),.strobe_in(1'b1),.strobe_out(strobe_cic),
	      .signal_in(i_cordic_pipe),.signal_out(i_cic));

   cic_decim #(.bw(WIDTH))
     decim_q (.clock(clk),.reset(rst),.enable(run),
	      .rate(cic_decim_rate),.strobe_in(1'b1),.strobe_out(strobe_cic),
	      .signal_in(q_cordic_pipe),.signal_out(q_cic));

   // V10: CIC droop compensator — 5-tap symmetric FIR
   // Corrects sinc^4 passband attenuation (+3.9 dB at band edge)
   // Always enabled (bypass=0). Operates at post-CIC decimated rate.
   wire [WIDTH-1:0] i_cic_comp, q_cic_comp;
   wire strobe_cic_comp;

   cic_droop_comp #(.WIDTH(WIDTH)) droop_comp_i
     (.clk(clk), .rst(rst), .bypass(1'b0),
      .stb_in(strobe_cic), .data_in(i_cic),
      .stb_out(strobe_cic_comp), .data_out(i_cic_comp));

   cic_droop_comp #(.WIDTH(WIDTH)) droop_comp_q
     (.clk(clk), .rst(rst), .bypass(1'b0),
      .stb_in(strobe_cic), .data_in(q_cic),
      .stb_out(), .data_out(q_cic_comp));

   //////////////////////////////////////////////////////////////////////////
   //
   // Conditional compilation of either:
   // 1) New X300 style decimation filters, or
   // 2) Traditional N210 style decimation filters.
   //
   //////////////////////////////////////////////////////////////////////////
   generate
      if (NEW_HB_DECIM == 1) begin: new_hb

	 wire        reload_go, reload_we1, reload_we2,  reload_ld1, reload_ld2;
	 wire [17:0] coef_din;

	 setting_reg #(.my_addr(BASE+4), .width(22)) sr_4
	   (.clk(clk),.rst(rst),.strobe(set_stb),.addr(set_addr),
	    .in(set_data),.out({reload_ld2,reload_we2,reload_ld1,reload_we1,coef_din[17:0]}),.changed(reload_go));

	 // Halfbands
	 wire 	     nd1, nd2, nd3;
	 wire 	     rfd1, rfd2, rfd3;
	 wire 	     rdy1, rdy2, rdy3;
	 wire 	     data_valid1, data_valid2, data_valid3;
	 wire [46:0] i_hb1, q_hb1;
	 wire [46:0] i_hb2, q_hb2;
	 localparam HB1_SCALE = 18;
	 localparam HB2_SCALE = 18;

	 // V4: Overflow-safe rounding for HB1 47→24b extraction (+6 dB vs truncation)
	 // Prevents wrap-to-negative when truncated value = max positive and round bit = 1
	 wire [WIDTH-1:0] i_hb1_rnd, q_hb1_rnd;
	 wire i_hb1_ovf = ~i_hb1[23+HB1_SCALE] & (&i_hb1[22+HB1_SCALE:HB1_SCALE]) & i_hb1[HB1_SCALE-1];
	 wire q_hb1_ovf = ~q_hb1[23+HB1_SCALE] & (&q_hb1[22+HB1_SCALE:HB1_SCALE]) & q_hb1[HB1_SCALE-1];
	 assign i_hb1_rnd = i_hb1_ovf ? i_hb1[23+HB1_SCALE:HB1_SCALE]
	                               : (i_hb1[23+HB1_SCALE:HB1_SCALE] + {{23{1'b0}}, i_hb1[HB1_SCALE-1]});
	 assign q_hb1_rnd = q_hb1_ovf ? q_hb1[23+HB1_SCALE:HB1_SCALE]
	                               : (q_hb1[23+HB1_SCALE:HB1_SCALE] + {{23{1'b0}}, q_hb1[HB1_SCALE-1]});

	 // V4: Overflow-safe rounding for HB2 47→24b extraction
	 wire [WIDTH-1:0] i_hb2_rnd, q_hb2_rnd;
	 wire i_hb2_ovf = ~i_hb2[23+HB2_SCALE] & (&i_hb2[22+HB2_SCALE:HB2_SCALE]) & i_hb2[HB2_SCALE-1];
	 wire q_hb2_ovf = ~q_hb2[23+HB2_SCALE] & (&q_hb2[22+HB2_SCALE:HB2_SCALE]) & q_hb2[HB2_SCALE-1];
	 assign i_hb2_rnd = i_hb2_ovf ? i_hb2[23+HB2_SCALE:HB2_SCALE]
	                               : (i_hb2[23+HB2_SCALE:HB2_SCALE] + {{23{1'b0}}, i_hb2[HB2_SCALE-1]});
	 assign q_hb2_rnd = q_hb2_ovf ? q_hb2[23+HB2_SCALE:HB2_SCALE]
	                               : (q_hb2[23+HB2_SCALE:HB2_SCALE] + {{23{1'b0}}, q_hb2[HB2_SCALE-1]});


	 assign strobe_hb1 = data_valid1;
	 assign strobe_hb2 = data_valid2;

	 // V10: Feed compensated CIC output to HB1
	 assign nd1 = strobe_cic_comp;
	 assign nd2 = strobe_hb1;

	 // Default Coeffs have gain of ~1.0
	 hbdec1 hbdec1
	   (.clk(clk), // input clk
	    .sclr(rst), // input sclr
	    .ce(enable_hb1), // input ce
	    .coef_ld(reload_go & reload_ld1), // input coef_ld
	    .coef_we(reload_go & reload_we1), // input coef_we
	    .coef_din(coef_din), // input [17 : 0] coef_din
	    .rfd(rfd1), // output rfd
	    .nd(nd1), // input nd
	    .din_1(i_cic_comp), // input [23 : 0] din_1 — V10: droop-compensated
	    .din_2(q_cic_comp), // input [23 : 0] din_2 — V10: droop-compensated
	    .rdy(rdy1), // output rdy
	    .data_valid(data_valid1), // output data_valid
	    .dout_1(i_hb1), // output [46 : 0] dout_1
	    .dout_2(q_hb1)); // output [46 : 0] dout_2

	 // Default Coeffs have gain of ~1.0
	 hbdec2 hbdec2
	   (.clk(clk), // input clk
	    .sclr(rst), // input sclr
	    .ce(enable_hb2), // input ce
	    .coef_ld(reload_go & reload_ld2), // input coef_ld
	    .coef_we(reload_go & reload_we2), // input coef_we
	    .coef_din(coef_din), // input [17 : 0] coef_din
	    .rfd(rfd2), // output rfd
	    .nd(nd2), // input nd
	    .din_1(i_hb1_rnd), // input [23 : 0] din_1 — V4: rounded (was truncated)
	    .din_2(q_hb1_rnd), // input [23 : 0] din_2 — V4: rounded (was truncated)
	    .rdy(rdy2), // output rdy
	    .data_valid(data_valid2), // output data_valid
	    .dout_1(i_hb2), // output [46 : 0] dout_1
	    .dout_2(q_hb2)); // output [46 : 0] dout_2

	 // V2: 3rd halfband filter (HB3) — additional ×2 decimation
	 // Uses small_hb_dec (7-tap, 1 DSP each)
	 // Placed after the HB1/HB2 output mux, before scaling.
	 // When bypassed (~enable_hb3), passes data through unchanged.
	 wire [WIDTH-1:0] i_hb3, q_hb3;

	 // Select data source for HB3 based on HB1/HB2 enables
	 reg [WIDTH-1:0]  i_pre_hb3, q_pre_hb3;
	 reg              strobe_pre_hb3;

	 // V10: HB3 now uses droop-compensated CIC output
	 always @(posedge clk)
	   case({enable_hb1,enable_hb2})
	     2'd0 : begin
		strobe_pre_hb3 <= strobe_cic_comp;
		i_pre_hb3 <= i_cic_comp;
		q_pre_hb3 <= q_cic_comp;
	     end
	     2'd1 : begin
		strobe_pre_hb3 <= strobe_cic_comp;
		i_pre_hb3 <= i_cic_comp;
		q_pre_hb3 <= q_cic_comp;
	     end
	     2'd2 : begin
		strobe_pre_hb3 <= strobe_hb1;
		// V4: Overflow-safe rounded HB1 (was inline add without overflow check)
		i_pre_hb3 <= i_hb1_rnd;
		q_pre_hb3 <= q_hb1_rnd;
	     end
	     2'd3 : begin
		strobe_pre_hb3 <= strobe_hb2;
		// V4: Overflow-safe rounded HB2 (was inline add without overflow check)
		i_pre_hb3 <= i_hb2_rnd;
		q_pre_hb3 <= q_hb2_rnd;
	     end
	   endcase

	 small_hb_dec #(.WIDTH(WIDTH), .DEVICE(DEVICE)) hb3_i
	   (.clk(clk), .rst(rst), .bypass(~enable_hb3), .run(run),
	    .stb_in(strobe_pre_hb3), .data_in(i_pre_hb3),
	    .stb_out(strobe_hb3), .data_out(i_hb3));

	 small_hb_dec #(.WIDTH(WIDTH), .DEVICE(DEVICE)) hb3_q
	   (.clk(clk), .rst(rst), .bypass(~enable_hb3), .run(run),
	    .stb_in(strobe_pre_hb3), .data_in(q_pre_hb3),
	    .stb_out(), .data_out(q_hb3));

	 // V9: External bypass mux — avoids HB3's internal 1-cycle bypass register
	 // When HB3 disabled, route pre_hb3 directly (0 extra cycles).
	 // When HB3 enabled, use filter output (HB3 has its own decimation timing).
	 wire [WIDTH-1:0] i_to_mult = enable_hb3 ? i_hb3 : i_pre_hb3;
	 wire [WIDTH-1:0] q_to_mult = enable_hb3 ? q_hb3 : q_pre_hb3;
	 wire             strobe_to_mult = enable_hb3 ? strobe_hb3 : strobe_pre_hb3;

	 // V6/V9: Full 24-bit precision into prescale multiply
	 // DSP48E1 natively supports 25×18 signed — no input truncation needed.
	 // Single pipeline register (matches V4's clip_reg latency — keeps total
	 // pipeline depth identical to avoid UHD accum_timeout).
	 reg [WIDTH:0]    i_prescale_ext, q_prescale_ext;
	 reg              strobe_prescale_ext;
	 always @(posedge clk) begin
	    strobe_prescale_ext <= strobe_to_mult;
	    i_prescale_ext <= {i_to_mult[WIDTH-1], i_to_mult};
	    q_prescale_ext <= {q_to_mult[WIDTH-1], q_to_mult};
	 end

	 // Apply scaling gain to compensate for CORDIC and CIC gain adjustments so that signal swing over network transport has
	 // optimal dynamic range.
	 wire [WIDTH+18:0]  prod_i, prod_q;  // 25+18=43 bit product

	 MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		      .LATENCY(1),         // Desired clock cycle latency, 0-4
		      .WIDTH_A(WIDTH+1),   // V6: 25-bit (full 24+sign) — DSP48E1 native 25×18
		      .WIDTH_B(18))        // Multiplier B-input bus width, 1-18
	 mult_i (.P(prod_i),             // Multiplier output bus, width determined by WIDTH_P parameter
		.A(i_prescale_ext),          // V6: full precision input
		.B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
		.CE(strobe_prescale_ext),    // 1-bit active high input clock enable
		.CLK(clk),              // 1-bit positive edge clock input
		.RST(rst));             // 1-bit input active high reset

	 MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		      .LATENCY(1),         // Desired clock cycle latency, 0-4
		      .WIDTH_A(WIDTH+1),   // V6: 25-bit (full 24+sign) — DSP48E1 native 25×18
		      .WIDTH_B(18))        // Multiplier B-input bus width, 1-18
	 mult_q (.P(prod_q),             // Multiplier output bus, width determined by WIDTH_P parameter
		.A(q_prescale_ext),          // V6: full precision input
		.B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
		.CE(strobe_prescale_ext),    // 1-bit active high input clock enable
		.CLK(clk),              // 1-bit positive edge clock input
		.RST(rst));             // 1-bit input active high reset

	 reg 		  strobe_scaled;
	 wire 		  strobe_clip;
	 wire [32:0] 	  i_clip, q_clip;

	 always @(posedge clk)  strobe_scaled <= strobe_prescale_ext;

	 clip_reg #(.bits_in(WIDTH+19), .bits_out(33), .STROBED(1)) clip_i
	   (.clk(clk), .in(prod_i), .strobe_in(strobe_scaled), .out(i_clip), .strobe_out(strobe_clip));
	 clip_reg #(.bits_in(WIDTH+19), .bits_out(33), .STROBED(1)) clip_q
	   (.clk(clk), .in(prod_q), .strobe_in(strobe_scaled), .out(q_clip), .strobe_out());

	 // V5: 2nd-order sigma-delta → -12 dB/octave noise floor (+8 dB SNR)
	 round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16), .SD_ORDER(2)) round_i
	   (.clk(clk), .reset(rst), .in(i_clip), .strobe_in(strobe_clip), .out(sample[31:16]), .strobe_out(strobe));
	 round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16), .SD_ORDER(2)) round_q
	   (.clk(clk), .reset(rst), .in(q_clip), .strobe_in(strobe_clip), .out(sample[15:0]), .strobe_out());

      end else begin: old_hb // block: new_hb
	 ///////////////////////////////////////////////
	 //
	 // Legacy Decimation Filters from USRP2
	 //
	 ///////////////////////////////////////////////
	 wire [WIDTH-1:0] i_hb1, q_hb1;
	 wire [WIDTH-1:0] i_hb2, q_hb2;
	 // First (small) halfband  24 bit I/O
	 // V10: uses droop-compensated CIC output
	 small_hb_dec #(.WIDTH(WIDTH),.DEVICE(DEVICE)) small_hb_i
	   (.clk(clk),.rst(rst),.bypass(~enable_hb1),.run(run),
	    .stb_in(strobe_cic_comp),.data_in(i_cic_comp),.stb_out(strobe_hb1),.data_out(i_hb1));

	 small_hb_dec #(.WIDTH(WIDTH),.DEVICE(DEVICE)) small_hb_q
	   (.clk(clk),.rst(rst),.bypass(~enable_hb1),.run(run),
	    .stb_in(strobe_cic_comp),.data_in(q_cic_comp),.stb_out(),.data_out(q_hb1));

	 // Second (large) halfband  24 bit I/O
	 wire [8:0] 	  cpi_hb = enable_hb1 ? {cic_decim_rate,1'b0} : {1'b0,cic_decim_rate};
	 hb_dec #(.WIDTH(WIDTH),.DEVICE(DEVICE)) hb_i
	   (.clk(clk),.rst(rst),.bypass(~enable_hb2),.run(run),.cpi(cpi_hb),
	    .stb_in(strobe_hb1),.data_in(i_hb1),.stb_out(strobe_hb2),.data_out(i_hb2));

	 hb_dec #(.WIDTH(WIDTH),.DEVICE(DEVICE)) hb_q
	   (.clk(clk),.rst(rst),.bypass(~enable_hb2),.run(run),.cpi(cpi_hb),
	    .stb_in(strobe_hb1),.data_in(q_hb1),.stb_out(),.data_out(q_hb2));

	 // V6: Full 24-bit precision into prescale multiply (old_hb path)
	 // Was: truncate 24→19 MSBs → clip 19→18 → MULT 18×18 (lost 6 bits)
	 // Now: full 24-bit → sign-extend 25 → MULT 25×18 (DSP48E1 native)
	 reg [WIDTH:0]    i_prescale_ext, q_prescale_ext;
	 reg              strobe_prescale_ext;
	 always @(posedge clk) begin
	    strobe_prescale_ext <= strobe_hb2;
	    i_prescale_ext <= {i_hb2[WIDTH-1], i_hb2};
	    q_prescale_ext <= {q_hb2[WIDTH-1], q_hb2};
	 end

	 //scalar operation (gain of 6 bits)
	 wire [WIDTH+18:0]  prod_i, prod_q;  // V6: 25+18=43 bit product

	 MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		      .LATENCY(1),         // Desired clock cycle latency, 0-4
		      .WIDTH_A(WIDTH+1),   // V6: 25-bit (full 24+sign) — DSP48E1 native 25×18
		      .WIDTH_B(18))        // Multiplier B-input bus width, 1-18
	 mult_i (.P(prod_i),             // Multiplier output bus, width determined by WIDTH_P parameter
		.A(i_prescale_ext),          // V6: full precision input
		.B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
		.CE(strobe_prescale_ext),    // 1-bit active high input clock enable
		.CLK(clk),              // 1-bit positive edge clock input
		.RST(rst));             // 1-bit input active high reset

	 MULT_MACRO #(.DEVICE(DEVICE),  // Target Device: "VIRTEX5", "VIRTEX6", "SPARTAN6","7SERIES"
		      .LATENCY(1),         // Desired clock cycle latency, 0-4
		      .WIDTH_A(WIDTH+1),   // V6: 25-bit (full 24+sign) — DSP48E1 native 25×18
		      .WIDTH_B(18))        // Multiplier B-input bus width, 1-18
	 mult_q (.P(prod_q),             // Multiplier output bus, width determined by WIDTH_P parameter
		.A(q_prescale_ext),          // V6: full precision input
		.B(scale_factor),       // Multiplier input B bus, width determined by WIDTH_B parameter
		.CE(strobe_prescale_ext),    // 1-bit active high input clock enable
		.CLK(clk),              // 1-bit positive edge clock input
		.RST(rst));             // 1-bit input active high reset

	 reg 		  strobe_scaled;
	 wire 		  strobe_clip;
	 wire [32:0] 	  i_clip, q_clip;

	 always @(posedge clk)  strobe_scaled <= strobe_prescale_ext;

	 clip_reg #(.bits_in(WIDTH+19), .bits_out(33), .STROBED(1)) clip_i
	   (.clk(clk), .in(prod_i), .strobe_in(strobe_scaled), .out(i_clip), .strobe_out(strobe_clip));
	 clip_reg #(.bits_in(WIDTH+19), .bits_out(33), .STROBED(1)) clip_q
	   (.clk(clk), .in(prod_q), .strobe_in(strobe_scaled), .out(q_clip), .strobe_out());

	 // V5: 2nd-order sigma-delta → -12 dB/octave noise floor (+8 dB SNR)
	 round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16), .SD_ORDER(2)) round_i
	   (.clk(clk), .reset(rst), .in(i_clip), .strobe_in(strobe_clip), .out(sample[31:16]), .strobe_out(strobe));
	 round_sd #(.WIDTH_IN(33), .WIDTH_OUT(16), .SD_ORDER(2)) round_q
	   (.clk(clk), .reset(rst), .in(q_clip), .strobe_in(strobe_clip), .out(sample[15:0]), .strobe_out());

      end // block: old_hb
   endgenerate



   assign debug = {enable_hb1, enable_hb2, enable_hb3, run, strobe, strobe_cic, strobe_hb1, strobe_hb2};

endmodule // ddc_chain
