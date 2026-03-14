//
// Copyright 2021 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module round_sd #(
  parameter WIDTH_IN   = 18,
  parameter WIDTH_OUT  = 16,
  parameter DISABLE_SD = 0,
  parameter SD_ORDER   = 1  // V5: 1=first-order, 2=second-order noise shaping
) (
  input                      clk,
  input                      reset,
  input      [ WIDTH_IN-1:0] in,
  input                      strobe_in,
  output reg [WIDTH_OUT-1:0] out         = 0,
  output reg                 strobe_out  = 0
);

  localparam ERR_WIDTH = WIDTH_IN - WIDTH_OUT + 1;

  wire [ERR_WIDTH-1:0] err;
  wire [WIDTH_IN-1:0]  err_ext, err_ext_01, sum;
  wire [WIDTH_OUT-1:0] out_pre;
  wire                 strobe_pre;

  // V5: 2nd-order sigma-delta noise shaping
  // SD_ORDER=1: NTF = (1-z^-1)      → -6 dB/octave  (original)
  // SD_ORDER=2: NTF = (1-z^-1)^2    → -12 dB/octave (+8 dB SNR floor)
  wire [ERR_WIDTH-1:0] err_fb;
  generate
    if (SD_ORDER >= 2) begin : gen_sd2
      reg [ERR_WIDTH-1:0] err_d1;
      always @(posedge clk) begin
        if (reset)
          err_d1 <= {ERR_WIDTH{1'b0}};
        else if (strobe_pre)
          err_d1 <= err;
      end
      wire signed [ERR_WIDTH:0] err_x2   = {err[ERR_WIDTH-1], err} + {err[ERR_WIDTH-1], err};
      wire signed [ERR_WIDTH:0] err_d1_e = {err_d1[ERR_WIDTH-1], err_d1};
      wire signed [ERR_WIDTH:0] err_diff = err_x2 - err_d1_e;
      clip #(.bits_in(ERR_WIDTH+1), .bits_out(ERR_WIDTH)) clip_sd2
        (.in(err_diff), .out(err_fb));
    end else begin : gen_sd1
      assign err_fb = err;
    end
  endgenerate

  sign_extend #(
    .bits_in  (ERR_WIDTH),
    .bits_out (WIDTH_IN)
  ) ext_err (
    .in  (err_fb),
    .out (err_ext)
  );

  assign err_ext_01 =
    //synthesis translate_off
    // Disallow X from getting stuck on the err_ext feedback path in simulation
    (^err_ext === 1'bX) ? 0 :
    //synthesis translate_on
    err_ext;

  add2_and_clip_reg #(
    .WIDTH (WIDTH_IN)
  ) add2_and_clip_reg (
    .clk        (clk),
    .rst        (reset),
    .in1        (in),
    .in2        ((DISABLE_SD == 0) ? err_ext_01 : {WIDTH_IN{1'b0}}),
    .strobe_in  (strobe_in),
    .sum        (sum),
    .strobe_out (strobe_pre)
  );

  round #(
    .bits_in  (WIDTH_IN),
    .bits_out (WIDTH_OUT)
  ) round_sum (
    .in  (sum),
    .out (out_pre),
    .err (err)
  );

  always @(posedge clk) begin
    if (reset) begin
      strobe_out <= 1'b0;
    end else begin
      strobe_out <= strobe_pre;
      if (strobe_pre) begin
        out <= out_pre;
      end
    end
  end

endmodule // round_sd
