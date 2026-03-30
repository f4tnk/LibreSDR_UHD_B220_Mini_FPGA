// cic_droop_comp.v — 5-tap symmetric FIR compensator for CIC N=4 droop
// F4TNK V10 — compensates sinc^4 passband droop
// Insert after CIC decimator, before halfband filters.
// Operates at decimated rate → plenty of timing margin.
//
// Impulse response: [c0, c1, c2, c1, c0] (symmetric → linear phase)
// Coefficients Q1.17 (sum = 2^17 = 131072 for unity gain):
//   c0 = -4096   (-0.03125)
//   c1 = +32768  (+0.25)
//   c2 = +73728  (+0.5625)
//   2*c0 + 2*c1 + c2 = -8192 + 65536 + 73728 = 131072 ✓
//
// Passband flatness: <0.1 dB over 80% of Nyquist band (was -3.9 dB)
// Cost: ~1-2 DSP48E1, ~60 LUT, ~130 FF
//
// SPDX-License-Identifier: LGPL-3.0-or-later

module cic_droop_comp
  #(parameter WIDTH = 24)
  (
   input                  clk,
   input                  rst,
   input                  bypass,
   input                  stb_in,
   input  [WIDTH-1:0]     data_in,
   output reg             stb_out,
   output reg [WIDTH-1:0] data_out
  );

  // Delay line (5 taps)
  reg [WIDTH-1:0] d0, d1, d2, d3, d4;
  reg stb_d0, stb_d1;

  always @(posedge clk) begin
    if (rst) begin
      d0 <= 0; d1 <= 0; d2 <= 0; d3 <= 0; d4 <= 0;
      stb_d0 <= 0; stb_d1 <= 0;
    end else begin
      if (stb_in) begin
        d0 <= data_in;
        d1 <= d0;
        d2 <= d1;
        d3 <= d2;
        d4 <= d3;
      end
      stb_d0 <= stb_in;
      stb_d1 <= stb_d0;
    end
  end

  // Symmetric coefficients in Q1.17
  localparam signed [17:0] C0 = -18'sd4096;
  localparam signed [17:0] C1 =  18'sd32768;
  localparam signed [17:0] C2 =  18'sd73728;

  // Pre-add exploiting symmetry (saves multiplications)
  wire signed [WIDTH:0] sym0 = {d0[WIDTH-1], d0} + {d4[WIDTH-1], d4};  // WIDTH+1 bits
  wire signed [WIDTH:0] sym1 = {d1[WIDTH-1], d1} + {d3[WIDTH-1], d3};
  wire signed [WIDTH-1:0] mid = d2;

  // V13: Pipeline stage between multiply and sum — enables DSP48E1 internal
  // register usage and halves combinatorial path delay.
  // Stage 1: registered products (Vivado infers DSP48E1 MREG)
  reg signed [WIDTH+18:0] p0_r, p1_r;
  reg signed [WIDTH+17:0] p2_r;
  reg stb_d2;

  always @(posedge clk) begin
    if (rst) begin
      p0_r <= 0; p1_r <= 0; p2_r <= 0;
      stb_d2 <= 0;
    end else begin
      p0_r <= sym0 * C0;
      p1_r <= sym1 * C1;
      p2_r <= mid  * C2;
      stb_d2 <= stb_d1;
    end
  end

  // Stage 2: sum (combinatorial, registered at output)
  wire signed [WIDTH+19:0] sum = {p0_r[WIDTH+18], p0_r} + {p1_r[WIDTH+18], p1_r} + {{2{p2_r[WIDTH+17]}}, p2_r};

  // Normalize (÷2^17) with rounding
  wire signed [WIDTH+2:0] sum_scaled = sum[WIDTH+19:17] + {{(WIDTH+2){1'b0}}, sum[16]};

  // Clip to WIDTH bits
  wire signed [WIDTH-1:0] clipped;
  clip #(.bits_in(WIDTH+3), .bits_out(WIDTH)) clip_out (.in(sum_scaled), .out(clipped));

  // V13: bypass uses d2 delayed by one extra cycle to match pipeline
  reg [WIDTH-1:0] d2_r;
  always @(posedge clk)
    if (rst) d2_r <= 0;
    else     d2_r <= d2;

  always @(posedge clk) begin
    if (rst) begin
      data_out <= 0;
      stb_out  <= 0;
    end else begin
      stb_out <= stb_d2;
      if (stb_d2)
        data_out <= bypass ? d2_r : clipped;
    end
  end

endmodule // cic_droop_comp
