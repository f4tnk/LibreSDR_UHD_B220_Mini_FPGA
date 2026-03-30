//
// Blind IQ Auto-Calibration for LibreSDR B220
// V11 — F4TNK
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Computes IQ imbalance correction coefficients (alpha, beta) from signal
// statistics alone, without requiring a known calibration tone.
//
// Theory (blind estimation):
//   For an ideal signal: E[I²] = E[Q²] and E[I·Q] = 0.
//   With gain imbalance g and phase error φ:
//     alpha = sqrt(E[Q²] / E[I²])          ≈ 1 + (E[Q²]-E[I²])/(2·E[I²])
//     beta  = -E[I·Q] / E[I²]              (cross-talk coefficient)
//
//   These are estimated via exponential averaging over ~2^20 samples (~10-50ms),
//   then formatted as Q2.16 for the iq_balance correction module.
//
// Implementation:
//   - 3 accumulators: sum_ii (E[I²]), sum_qq (E[Q²]), sum_iq (E[I·Q])
//   - Exponential IIR with α=20 (τ≈1M samples, ~10ms @100MSPS)
//   - Alpha/beta computed via shift-and-subtract approximation (no divider)
//   - Output update rate: every 2^UPDATE_SHIFT samples to limit switching noise
//   - Always active, no bypass register
//   - Outputs compatible with iq_balance.v Q2.16 format (18-bit signed)
//
// Cost: 4 DSP48E1, ~500 LUT, ~600 FF
//

module iq_auto_cal #(
  parameter WIDTH        = 24,
  parameter COEFF_WIDTH  = 18,     // Q2.16 output format
  parameter FRAC_BITS    = 16,     // Fractional bits in Q2.16
  parameter AVG_ALPHA    = 20,     // IIR time constant 2^20 ≈ 1M samples
  parameter UPDATE_SHIFT = 16      // Update coefficients every 2^16 samples
) (
  input                        clk,
  input                        rst,
  input                        stb_in,
  input  signed [WIDTH-1:0]    i_in,
  input  signed [WIDTH-1:0]    q_in,

  // Output correction coefficients (Q2.16, compatible with iq_balance.v)
  output reg signed [COEFF_WIDTH-1:0] alpha_out,  // Gain correction: ~1.0 at reset
  output reg signed [COEFF_WIDTH-1:0] beta_out,   // Cross-talk: ~0.0 at reset
  output reg                          coeff_valid  // Pulses when coefficients update
);

  // ── Derived parameters ──────────────────────────────────────────────────
  // Use top HALF bits for multiply to limit DSP width
  localparam HALF = WIDTH / 2;  // 12 bits — fits in 18×18 unsigned
  // Accumulator width for |X|² statistics (2*HALF bits per product + headroom)
  localparam STAT_WIDTH = 2 * HALF + AVG_ALPHA;  // 24 + 20 = 44 bits

  // ── Squaring (using top HALF bits for area efficiency) ──────────────────
  wire signed [HALF-1:0] i_top = i_in[WIDTH-1:WIDTH-HALF];
  wire signed [HALF-1:0] q_top = q_in[WIDTH-1:WIDTH-HALF];

  // DSP48 multiplies (12×12 → 24-bit, fits in 25×18)
  wire signed [2*HALF-1:0] prod_ii = i_top * i_top;  // Always ≥ 0
  wire signed [2*HALF-1:0] prod_qq = q_top * q_top;  // Always ≥ 0
  wire signed [2*HALF-1:0] prod_iq = i_top * q_top;  // Can be negative

  // Register products for timing
  reg signed [2*HALF-1:0] prod_ii_r, prod_qq_r, prod_iq_r;
  reg stb_d1;

  always @(posedge clk) begin
    prod_ii_r <= prod_ii;
    prod_qq_r <= prod_qq;
    prod_iq_r <= prod_iq;
    stb_d1    <= stb_in;
  end

  // ── Running statistics (IIR exponential average) ────────────────────────
  // sum_xx += (prod_xx - sum_xx) >> AVG_ALPHA
  // These represent E[I²], E[Q²], E[I·Q] scaled by a constant.
  reg [STAT_WIDTH-1:0] sum_ii;          // E[I²] — unsigned (always positive)
  reg [STAT_WIDTH-1:0] sum_qq;          // E[Q²] — unsigned (always positive)
  reg signed [STAT_WIDTH-1:0] sum_iq;   // E[I·Q] — signed (can be negative)

  always @(posedge clk) begin
    if (rst) begin
      // Initialize sum_ii and sum_qq to a non-zero value proportional
      // to expected signal power to speed up convergence.
      // Default: assume -30 dBFS signal → approx 2^(2*HALF-8) per sample
      sum_ii <= {{(AVG_ALPHA+8){1'b0}}, {(2*HALF-8){1'b1}}};
      sum_qq <= {{(AVG_ALPHA+8){1'b0}}, {(2*HALF-8){1'b1}}};
      sum_iq <= 0;
    end else if (stb_d1) begin
      // IIR update for sum_ii (unsigned)
      begin : update_ii
        reg signed [STAT_WIDTH:0] diff;
        diff = {1'b0, {(STAT_WIDTH-2*HALF){1'b0}}, prod_ii_r[2*HALF-2:0]} - {1'b0, sum_ii};
        sum_ii <= sum_ii + {{AVG_ALPHA{diff[STAT_WIDTH]}}, diff[STAT_WIDTH:AVG_ALPHA]};
      end
      // IIR update for sum_qq (unsigned)
      begin : update_qq
        reg signed [STAT_WIDTH:0] diff;
        diff = {1'b0, {(STAT_WIDTH-2*HALF){1'b0}}, prod_qq_r[2*HALF-2:0]} - {1'b0, sum_qq};
        sum_qq <= sum_qq + {{AVG_ALPHA{diff[STAT_WIDTH]}}, diff[STAT_WIDTH:AVG_ALPHA]};
      end
      // IIR update for sum_iq (signed)
      begin : update_iq
        reg signed [STAT_WIDTH:0] diff;
        diff = {{(STAT_WIDTH-2*HALF+1){prod_iq_r[2*HALF-1]}}, prod_iq_r} - {sum_iq[STAT_WIDTH-1], sum_iq};
        sum_iq <= sum_iq + {{AVG_ALPHA{diff[STAT_WIDTH]}}, diff[STAT_WIDTH:AVG_ALPHA]};
      end
    end
  end

  // ── Update counter (limit coefficient update rate) ──────────────────────
  reg [UPDATE_SHIFT-1:0] update_cnt;
  wire update_now = (update_cnt == 0) && stb_d1;

  always @(posedge clk) begin
    if (rst)
      update_cnt <= 0;
    else if (stb_d1)
      update_cnt <= update_cnt + 1;
  end

  // ── Coefficient computation ─────────────────────────────────────────────
  // alpha = sqrt(E[Q²]/E[I²]) ≈ 1 + (sum_qq - sum_ii) / (2 × sum_ii)
  // beta  = -sum_iq / sum_ii
  //
  // Division by sum_ii is approximated using shift by MSB position.
  //
  // Q2.16 format: 1.0 = 0x10000 = 65536

  function [5:0] msb_pos;
    input [STAT_WIDTH-1:0] val;
    integer i;
    begin
      msb_pos = 0;
      for (i = 0; i < STAT_WIDTH; i = i + 1)
        if (val[i]) msb_pos = i[5:0];
    end
  endfunction

  localparam signed [COEFF_WIDTH-1:0] ALPHA_UNITY = (1 <<< FRAC_BITS);  // 1.0 in Q2.16

  always @(posedge clk) begin
    if (rst) begin
      alpha_out   <= ALPHA_UNITY;  // 1.0
      beta_out    <= 0;            // 0.0
      coeff_valid <= 0;
    end else begin
      coeff_valid <= 0;

      if (update_now && (sum_ii > 0)) begin
        begin : compute_coeffs
          reg [5:0] ii_msb;
          reg signed [STAT_WIDTH:0] delta_gain;    // sum_qq - sum_ii
          reg signed [STAT_WIDTH:0] neg_sum_iq;    // -sum_iq
          reg signed [COEFF_WIDTH-1:0] alpha_corr;
          reg signed [COEFF_WIDTH-1:0] beta_val;
          reg signed [COEFF_WIDTH:0] alpha_sum;
          reg [5:0] shift_amount;

          ii_msb = msb_pos(sum_ii);

          // Normalize: shift so that (sum_qq - sum_ii) / sum_ii ≈ delta >> ii_msb
          // For alpha correction: (sum_qq - sum_ii) / (2 × sum_ii)
          //   ≈ (sum_qq - sum_ii) >> (ii_msb + 1), then convert to Q2.16
          // We need the result in FRAC_BITS fractional bits, so:
          //   alpha_corr = ((sum_qq - sum_ii) << FRAC_BITS) >> (ii_msb + 1)
          //   = (sum_qq - sum_ii) >> (ii_msb + 1 - FRAC_BITS)

          delta_gain = {1'b0, sum_qq} - {1'b0, sum_ii};
          neg_sum_iq = -{{1'b0, sum_iq[STAT_WIDTH-1]}, sum_iq};

          // Shift for alpha: ii_msb + 1 - FRAC_BITS
          // If ii_msb < FRAC_BITS, we need to left-shift (gain < 1 per sample)
          // In practice ii_msb >> FRAC_BITS, so right-shift
          if (ii_msb + 1 > FRAC_BITS)
            shift_amount = ii_msb + 1 - FRAC_BITS[5:0];
          else
            shift_amount = 0;

          alpha_corr = delta_gain >>> shift_amount;
          beta_val   = neg_sum_iq  >>> (ii_msb >= FRAC_BITS ? (ii_msb - FRAC_BITS[5:0] + 1) : 6'd0);

          // alpha = 1.0 + correction/2
          alpha_sum = {ALPHA_UNITY[COEFF_WIDTH-1], ALPHA_UNITY} + {alpha_corr[COEFF_WIDTH-1], alpha_corr};

          // Clip alpha to [0.5, 1.5] in Q2.16 = [0x8000, 0x18000]
          if (alpha_sum > $signed({{(COEFF_WIDTH-16){1'b0}}, 16'hC000, 1'b0}))  // > 1.5
            alpha_out <= $signed(18'h18000);
          else if (alpha_sum < $signed({{(COEFF_WIDTH-15){1'b0}}, 15'h4000, 1'b0}))  // < 0.5
            alpha_out <= $signed(18'h08000);
          else
            alpha_out <= alpha_sum[COEFF_WIDTH-1:0];

          // Clip beta to [-0.25, +0.25] in Q2.16
          if (beta_val > $signed(18'h04000))
            beta_out <= $signed(18'h04000);
          else if (beta_val < $signed(-18'sh04000))
            beta_out <= $signed(-18'sh04000);
          else
            beta_out <= beta_val;

          coeff_valid <= 1'b1;
        end
      end
    end
  end

endmodule // iq_auto_cal
