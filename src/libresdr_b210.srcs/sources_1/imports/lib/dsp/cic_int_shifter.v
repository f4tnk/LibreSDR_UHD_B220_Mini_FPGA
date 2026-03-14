// -*- verilog -*-
//
//  USRP - Universal Software Radio Peripheral
//
//  Copyright (C) 2003 Matt Ettus
// 
//  SPDX-License-Identifier: LGPL-3.0-or-later
//

//


// NOTE   This only works for N=4, max interp rate of 256
// NOTE   signal "rate" is EQUAL TO the actual rate (no more -1 BS)
// V3: Added convergent rounding of discarded LSBs

module cic_int_shifter(rate,signal_in,signal_out);
   parameter bw = 16;
   parameter maxbitgain = 24;
   
   input [7:0] rate;
   input       wire [bw+maxbitgain-1:0] signal_in;
   output      reg [bw-1:0] signal_out;

   function [5:0] bitgain;
      input [7:0] rate;
      case(rate)
	// Exact Cases -- (N-1)*log2(rate)
	8'd1 : bitgain = 0;
	8'd2 : bitgain = 3;
	8'd4 : bitgain = 6;
	8'd8 : bitgain = 9;
	8'd16 : bitgain = 12;
	8'd32 : bitgain = 15;
	8'd64 : bitgain = 18;
	8'd128 : bitgain = 21;
	
	// Nearest without overflow	
	8'd3 : bitgain = 5;
	8'd5 : bitgain = 7;
	8'd6 : bitgain = 8;
	8'd7 : bitgain = 9;
	8'd9,8'd10 : bitgain = 10;
	8'd11,8'd12 : bitgain = 11;
	8'd13,8'd14,8'd15 : bitgain = 12;
	8'd17,8'd18,8'd19,8'd20 : bitgain = 13;
	8'd21,8'd22,8'd23,8'd24,8'd25 : bitgain = 14;
	8'd26,8'd27,8'd28,8'd29,8'd30,8'd31 : bitgain = 15;
	8'd33,8'd34,8'd35,8'd36,8'd37,8'd38,8'd39,8'd40 : bitgain = 16;
	8'd41,8'd42,8'd43,8'd44,8'd45,8'd46,8'd47,8'd48,8'd49,8'd50 : bitgain = 17;
	8'd51,8'd52,8'd53,8'd54,8'd55,8'd56,8'd57,8'd58,8'd59,8'd60,8'd61,8'd62,8'd63 : bitgain = 18;
	8'd65,8'd66,8'd67,8'd68,8'd69,8'd70,8'd71,8'd72,8'd73,8'd74,8'd75,8'd76,8'd77,8'd78,8'd79,8'd80 : bitgain = 19;
	8'd81,8'd82,8'd83,8'd84,8'd85,8'd86,8'd87,8'd88,8'd89,8'd90,8'd91,8'd92,8'd93,8'd94,8'd95,8'd96,8'd97,8'd98,8'd99,8'd100,8'd101 : bitgain = 20;
	8'd102,8'd103,8'd104,8'd105,8'd106,8'd107,8'd108,8'd109,8'd110,8'd111,8'd112,8'd113,8'd114,8'd115,8'd116,8'd117,8'd118,8'd119,8'd120,8'd121,8'd122,8'd123,8'd124,8'd125,8'd126,8'd127 : bitgain = 21;
	8'd129,8'd130,8'd131,8'd132,8'd133,8'd134,8'd135,8'd136,8'd137,8'd138,8'd139,8'd140,8'd141,8'd142,8'd143,8'd144,8'd145,8'd146,8'd147,8'd148,8'd149,8'd150,8'd151,8'd152,8'd153,8'd154,8'd155,8'd156,8'd157,8'd158,8'd159,8'd160 : bitgain = 22;
	8'd161,8'd162,8'd163,8'd164,8'd165,8'd166,8'd167,8'd168,8'd169,8'd170,8'd171,8'd172,8'd173,8'd174,8'd175,8'd176,8'd177,8'd178,8'd179,8'd180,8'd181,8'd182,8'd183,8'd184,8'd185,8'd186,8'd187,8'd188,8'd189,8'd190,8'd191,8'd192,8'd193,8'd194,8'd195,8'd196,8'd197,8'd198,8'd199,8'd200,8'd201,8'd202 : bitgain = 23;
	default : bitgain = 24;
      endcase // case(rate)
   endfunction // bitgain
   
   wire [5:0] 	  shift = bitgain(rate);
   
   // V3: Extract bw-bit window with rounding
   reg [bw-1:0] trunc_out;
   reg          round_bit;
   
   always @*
     case(shift)
       6'd0  : begin trunc_out = signal_in[0+bw-1:0];   round_bit = 1'b0; end
       6'd3  : begin trunc_out = signal_in[3+bw-1:3];   round_bit = signal_in[2]; end
       6'd5  : begin trunc_out = signal_in[5+bw-1:5];   round_bit = signal_in[4]; end
       6'd6  : begin trunc_out = signal_in[6+bw-1:6];   round_bit = signal_in[5]; end
       6'd7  : begin trunc_out = signal_in[7+bw-1:7];   round_bit = signal_in[6]; end
       6'd8  : begin trunc_out = signal_in[8+bw-1:8];   round_bit = signal_in[7]; end
       6'd9  : begin trunc_out = signal_in[9+bw-1:9];   round_bit = signal_in[8]; end
       6'd10 : begin trunc_out = signal_in[10+bw-1:10]; round_bit = signal_in[9]; end
       6'd11 : begin trunc_out = signal_in[11+bw-1:11]; round_bit = signal_in[10]; end
       6'd12 : begin trunc_out = signal_in[12+bw-1:12]; round_bit = signal_in[11]; end
       6'd13 : begin trunc_out = signal_in[13+bw-1:13]; round_bit = signal_in[12]; end
       6'd14 : begin trunc_out = signal_in[14+bw-1:14]; round_bit = signal_in[13]; end
       6'd15 : begin trunc_out = signal_in[15+bw-1:15]; round_bit = signal_in[14]; end
       6'd16 : begin trunc_out = signal_in[16+bw-1:16]; round_bit = signal_in[15]; end
       6'd17 : begin trunc_out = signal_in[17+bw-1:17]; round_bit = signal_in[16]; end
       6'd18 : begin trunc_out = signal_in[18+bw-1:18]; round_bit = signal_in[17]; end
       6'd19 : begin trunc_out = signal_in[19+bw-1:19]; round_bit = signal_in[18]; end
       6'd20 : begin trunc_out = signal_in[20+bw-1:20]; round_bit = signal_in[19]; end
       6'd21 : begin trunc_out = signal_in[21+bw-1:21]; round_bit = signal_in[20]; end
       6'd22 : begin trunc_out = signal_in[22+bw-1:22]; round_bit = signal_in[21]; end
       6'd23 : begin trunc_out = signal_in[23+bw-1:23]; round_bit = signal_in[22]; end
       6'd24 : begin trunc_out = signal_in[24+bw-1:24]; round_bit = signal_in[23]; end
       
       default : begin trunc_out = signal_in[24+bw-1:24]; round_bit = signal_in[23]; end
     endcase // case(shift)

   wire would_overflow = ~trunc_out[bw-1] & (&trunc_out[bw-2:0]) & round_bit;
   always @*
     signal_out = would_overflow ? trunc_out : (trunc_out + {{(bw-1){1'b0}}, round_bit});

endmodule // cic_int_shifter

