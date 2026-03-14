//
// IQ Imbalance Correction for LibreSDR B220 — F4TNK V4
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Corrects amplitude and phase imbalance of direct-conversion receiver AD9361.
// Implements a lower-triangular 2x2 matrix:
//
//   I_out = alpha * I_in
//   Q_out = beta  * I_in + Q_in
//
// Where alpha ≈ 1.0 (amplitude correction) and beta ≈ 0.0 (phase correction).
// Format: signed 18-bit Q2.16 (1 sign + 1 integer + 16 fractional bits).
//   alpha = 0x10000 means gain = 1.0 (default/bypass)
//   beta  = 0x00000 means no phase correction (default/bypass)
//
// When alpha = 0x10000 and beta = 0x00000, output ≈ input (transparent).
//
// V4: Full WIDTH-bit input to DSP48E1 (25×18 native signed multiply).
//     Recovers +6 dB SNR floor vs V2's 18-bit truncation.
// Resource cost: 2 × DSP48E1 (MULT_MACRO WIDTH×18) + 1 adder.

module iq_balance
  #(parameter WIDTH = 24,
    parameter DEVICE = "7SERIES")
   (input clk,
    input rst,
    input [17:0] alpha,           // Q2.16 amplitude correction (1.0 = 18'h10000)
    input [17:0] beta,            // Q2.16 phase correction     (0.0 = 18'h00000)
    input strobe_in,
    input [WIDTH-1:0] i_in,
    input [WIDTH-1:0] q_in,
    output reg [WIDTH-1:0] i_out,
    output reg [WIDTH-1:0] q_out,
    output reg strobe_out);

   // V4: Full 24-bit input precision for DSP48E1 multiplication (+6 dB floor recovery)
   // Was 18-bit truncation losing 6 LSBs. DSP48E1 natively supports signed 25×18.
   wire signed [WIDTH-1:0] i_full = i_in;

   // alpha * I  (WIDTH+18 bit signed product, full precision)
   wire [WIDTH+17:0] prod_alpha_i;
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(WIDTH), .WIDTH_B(18))
   mult_alpha (.P(prod_alpha_i), .A(i_full), .B(alpha),
               .CE(strobe_in), .CLK(clk), .RST(rst));

   // beta * I  (WIDTH+18 bit signed product, full precision)
   wire [WIDTH+17:0] prod_beta_i;
   MULT_MACRO #(.DEVICE(DEVICE), .LATENCY(1), .WIDTH_A(WIDTH), .WIDTH_B(18))
   mult_beta (.P(prod_beta_i), .A(i_full), .B(beta),
              .CE(strobe_in), .CLK(clk), .RST(rst));

   // Pipeline strobe and Q through multiplier latency (1 cycle)
   reg strobe_d1;
   reg [WIDTH-1:0] q_d1;
   always @(posedge clk) begin
      strobe_d1 <= strobe_in;
      q_d1 <= q_in;
   end

   // V4: Product format: (WIDTH+18)-bit signed = i_in(24b) × alpha(Q2.16)
   // At unity alpha=0x10000 (=2^16): prod = i_in << 16 → prod[WIDTH+15:16] = i_in
   // One extra MSB for overflow headroom on alpha > 1.0, then clip to WIDTH.
   wire signed [WIDTH:0] i_wide = prod_alpha_i[WIDTH+16:16];         // WIDTH+1 bits
   wire signed [WIDTH-1:0] beta_scaled = prod_beta_i[WIDTH+15:16];   // WIDTH bits

   // Q_out = beta*I + Q_in  (sign-extend both to WIDTH+1 bits for safe addition)
   wire signed [WIDTH:0] q_sum = {beta_scaled[WIDTH-1], beta_scaled} + {q_d1[WIDTH-1], q_d1};

   // Clip from WIDTH+1 to WIDTH bits (always reduces, never expands)
   wire [WIDTH-1:0] i_clipped, q_clipped;
   clip #(.bits_in(WIDTH+1), .bits_out(WIDTH)) clip_i (.in(i_wide), .out(i_clipped));
   clip #(.bits_in(WIDTH+1), .bits_out(WIDTH)) clip_q (.in(q_sum), .out(q_clipped));

   always @(posedge clk)
     if (rst) begin
        i_out <= 0;
        q_out <= 0;
        strobe_out <= 0;
     end else begin
        strobe_out <= strobe_d1;
        if (strobe_d1) begin
           i_out <= i_clipped;
           q_out <= q_clipped;
        end
     end

endmodule // iq_balance
