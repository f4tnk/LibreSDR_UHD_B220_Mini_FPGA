//
// Copyright 2011 Ettus Research LLC
// Copyright 2018 Ettus Research, a National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

// NOTE: This module uses Xilinx IP that is not available in Spartan3 and older FPGA's

// Short halfband decimator (intended to be followed by another stage)
// Implements impulse responses of the form [A 0 B 0.5 B 0 A]
//
// These taps designed by halfgen4 from ldoolittle:
//   2 * 131072 * halfgen4(.75/8,2)
//
// V10: INTWIDTH raised from 17 to WIDTH (24) to exploit DSP48E1 25×18 native
//      signed multiply. Eliminates early 7-bit truncation that was destroying
//      weak-signal LSBs. Input round_sd stage is now bypassed (WIDTH→WIDTH).
module small_hb_dec
  #(parameter WIDTH=18,
    parameter DEVICE = "7SERIES")
    (input clk,
     input rst,
     input bypass,
     input run,
     input stb_in,
     input [WIDTH-1:0] data_in,
     output reg stb_out,
     output reg [WIDTH-1:0] data_out);

   // V10: Use full WIDTH internally — DSP48E1 supports 25×18 signed multiply
   localparam INTWIDTH = WIDTH;
   wire [INTWIDTH-1:0] 	data_rnd;
   wire 		stb_rnd;

   // V10: INTWIDTH==WIDTH, so round_sd would be identity but round.v doesn't support
   // bits_in==bits_out. Direct wire-through instead.
   assign data_rnd = data_in;
   assign stb_rnd = stb_in;


   reg 			stb_rnd_d1;
   reg [INTWIDTH-1:0] 	data_rnd_d1;
   always @(posedge clk) stb_rnd_d1 <= stb_rnd;
   always @(posedge clk) data_rnd_d1 <= data_rnd;

   wire 		go;
   reg 			phase, go_d1, go_d2, go_d3, go_d4;
   always @(posedge clk)
     if(rst | ~run)
       phase <= 0;
     else if(stb_rnd_d1)
       phase <= ~phase;
   assign 		go = stb_rnd_d1 & phase;
   always @(posedge clk)
     if(rst | ~run)
       begin
	  go_d1 <= 0;
	  go_d2 <= 0;
	  go_d3 <= 0;
	  go_d4 <= 0;
       end
     else
       begin
	  go_d1 <= go;
	  go_d2 <= go_d1;
	  go_d3 <= go_d2;
	  go_d4 <= go_d3;
       end

   wire [17:0] 		coeff_a = -10690;
   wire [17:0] 		coeff_b = 75809;

   reg [INTWIDTH-1:0] 	d1, d2, d3, d4 , d5, d6;
   always @(posedge clk)
     if(stb_rnd_d1 | rst)
       begin
	  d1 <= data_rnd_d1;
	  d2 <= d1;
	  d3 <= d2;
	  d4 <= d3;
	  d5 <= d4;
	  d6 <= d5;
       end

   // V10: sum and middle widths = INTWIDTH+1 to hold sign-extended addition
   reg [INTWIDTH:0] sum_a, sum_b, middle, middle_d1;

   always @(posedge clk)
     if(go)
       begin
	  sum_a <= {data_rnd_d1[INTWIDTH-1],data_rnd_d1} + {d6[INTWIDTH-1],d6};
	  sum_b <= {d2[INTWIDTH-1],d2} + {d4[INTWIDTH-1],d4};
	  middle <= {d3,1'b0};
       end

   always @(posedge clk)
     if(go_d1)
       middle_d1 <= middle;

   // V10: DSP48E1 25×18 signed multiply — full INTWIDTH+1 input width
   wire [INTWIDTH:0] sum = go_d1 ? sum_b : sum_a;
   wire [17:0] coeff = go_d1 ? coeff_b : coeff_a;
   wire [INTWIDTH+18:0] prod;

    MULT_MACRO #(.DEVICE(DEVICE),
		.LATENCY(1),
		.WIDTH_A(INTWIDTH+1),  // V10: 25 bits (was 18) — fits DSP48E1 A-port natively
		.WIDTH_B(18))
      mult (.P(prod),
	       .A(sum),
	       .B(coeff),
	       .CE(go_d1 | go_d2),
	       .CLK(clk),
	       .RST(rst));

   // V10: Accumulator width = product width + 1 for safe accumulation of 2 products + middle
   localparam ACCWIDTH = INTWIDTH + 18 + 2;  // 24+18+2=44 bits
   reg [ACCWIDTH-1:0] 	 accum;

   // V10+V19: Accumulator alignment for wider product
   // Product is (INTWIDTH+1+18)-bit = 43-bit signed, NOT shifted into accum: it carries
   // the coefficient scale 2^18 (taps = 2*131072*halfgen4 → true_tap = coeff/2^18).
   // Middle is (INTWIDTH+1)-bit = 25-bit and equals d3<<1. To represent the 0.5 center
   // tap at the SAME 2^18 scale it must weigh d3*2^17, hence exactly 16 zero-pad bits:
   //   d3 * 2 * 2^16 = d3 * 2^17 = 0.5 * d3 * 2^18.
   // V19 FIX: the V10 formula "16 + ACCWIDTH - PROD_WIDTH" (=17) doubled the center tap
   // to 1.0 — breaking the halfband property (DC gain 1.497, stopband floor ≈ -9.5 dB →
   // image rejection collapsed whenever HB3 was engaged). 16 zeros restores tap 0.5,
   // the canonical Ettus output scale, and the halfband stopband. Combinatorial-only
   // change: no pipeline latency impact.
   localparam PROD_WIDTH = INTWIDTH + 1 + 18;  // 43 bits
   localparam MID_ZEROS = 16;                                   // V19 (was 17 in V10)
   localparam MID_SIGN  = ACCWIDTH - (INTWIDTH+1) - MID_ZEROS;  // 3
   
   always @(posedge clk)
     if(rst)
       accum <= 0;
     else if(go_d2)
       accum <= {{MID_SIGN{middle_d1[INTWIDTH]}}, middle_d1, {MID_ZEROS{1'b0}}}
              + {{(ACCWIDTH-PROD_WIDTH){prod[PROD_WIDTH-1]}}, prod};
     else if(go_d3)
       accum <= accum + {{(ACCWIDTH-PROD_WIDTH){prod[PROD_WIDTH-1]}}, prod};

   wire [WIDTH:0] 	 accum_rnd;
   wire [WIDTH-1:0] 	 accum_rnd_clip;

   wire 	 stb_round;

   round_sd #(.WIDTH_IN(ACCWIDTH),.WIDTH_OUT(WIDTH+1)) round_acc
     (.clk(clk), .reset(rst), .in(accum), .strobe_in(go_d4), .out(accum_rnd), .strobe_out(stb_round));

   clip #(.bits_in(WIDTH+1),.bits_out(WIDTH)) clip (.in(accum_rnd), .out(accum_rnd_clip));

   // Output
   always @(posedge clk)
     begin
	stb_out  <= bypass ? stb_in : stb_round;
	data_out <= bypass ? data_in : accum_rnd_clip;
     end


endmodule // small_hb_dec
