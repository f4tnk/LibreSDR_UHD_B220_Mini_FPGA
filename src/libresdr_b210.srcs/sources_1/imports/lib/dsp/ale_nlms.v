//
// Adaptive Line Enhancer (ALE) — NLMS algorithm for LibreSDR B220
// V11 — F4TNK
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Implements a complex-valued ALE using Normalized LMS (NLMS) to extract
// correlated (predictable) signal components from wideband noise.
//
// Theory:
//   x[n] = signal + noise. Signal is correlated over Δ samples; noise is not.
//   FIR w[k] predicts x[n] from x[n-Δ]...x[n-Δ-N+1].
//   Output ŝ[n] = Σ w[k]·x[n-Δ-k] = enhanced signal (noise rejected).
//   Error e[n] = x[n] - ŝ[n] → drives weight update.
//   NLMS update: w[k] += μ·e[n]·x*[n-Δ-k] / (||x||² + ε)
//
// Implementation:
//   - NTAPS=32 complex taps, Δ=3 (decorrelation delay)
//   - Time-multiplexed: 1 DSP48E1 pair (I/Q), cycling through taps sequentially
//   - μ=2^(-MU_SHIFT) implemented as right-shift (no multiplier needed for μ)
//   - ||x||² normalization via reciprocal LUT (BRAM-free, shift approximation)
//   - Always active, no bypass. Converges in ~100-500 samples (~1-5 ms).
//
// Cost: 4 DSP48E1, ~2000 LUT, ~3000 FF, 2 BRAM18 (delay line + weights)
//

module ale_nlms #(
  parameter WIDTH    = 24,
  parameter NTAPS    = 32,       // Number of FIR taps (power of 2 for easy addressing)
  parameter DELAY    = 3,        // Decorrelation delay Δ (samples)
  parameter MU_SHIFT = 12        // Step size μ = 2^(-MU_SHIFT)
) (
  input                  clk,
  input                  rst,
  input                  stb_in,
  input  [WIDTH-1:0]     i_in,
  input  [WIDTH-1:0]     q_in,
  output reg [WIDTH-1:0] i_out,
  output reg [WIDTH-1:0] q_out,
  output reg             stb_out
);

  // ── Derived parameters ──────────────────────────────────────────────────
  localparam DLINE_LEN = NTAPS + DELAY;  // 35 entries
  localparam ADDR_BITS = $clog2(DLINE_LEN);  // 6 bits
  localparam TAP_ADDR  = $clog2(NTAPS);      // 5 bits
  localparam WWIDTH    = 18;                  // Weight precision Q1.17
  // Accumulator for FIR output: WIDTH + WWIDTH + log2(NTAPS) = 24+18+5 = 47
  localparam ACC_WIDTH = WIDTH + WWIDTH + TAP_ADDR;

  // ── Delay line (distributed RAM — DLINE_LEN × 2 × WIDTH) ───────────────
  // Stores complex samples x[n], x[n-1], ..., x[n-DLINE_LEN+1]
  reg signed [WIDTH-1:0] dline_i [0:DLINE_LEN-1];
  reg signed [WIDTH-1:0] dline_q [0:DLINE_LEN-1];

  // ── Weight memory (distributed RAM — NTAPS × 2 × WWIDTH) ───────────────
  // Complex FIR weights w_i[k] + j·w_q[k], Q1.17 format
  reg signed [WWIDTH-1:0] w_i [0:NTAPS-1];
  reg signed [WWIDTH-1:0] w_q [0:NTAPS-1];

  // ── Write pointer for circular delay line ──────────────────────────────
  reg [ADDR_BITS-1:0] wr_ptr;

  // ── State machine ──────────────────────────────────────────────────────
  // States: IDLE → COMPUTE (NTAPS cycles) → UPDATE (NTAPS cycles) → OUTPUT
  localparam S_IDLE    = 3'd0;
  localparam S_COMPUTE = 3'd1;
  localparam S_UPDATE  = 3'd2;
  localparam S_OUTPUT  = 3'd3;

  reg [2:0]  state;
  reg [TAP_ADDR:0] tap_cnt;  // 0..NTAPS-1 counter (extra bit for done detection)

  // ── Latched input ──────────────────────────────────────────────────────
  reg signed [WIDTH-1:0] x_i, x_q;              // Current input x[n]

  // ── FIR output accumulator ─────────────────────────────────────────────
  reg signed [ACC_WIDTH-1:0] acc_i, acc_q;

  // ── Power estimate ||x||² (for NLMS normalization) ─────────────────────
  // Approximate: maintain running sum of |x[n-Δ-k]|² over NTAPS
  // Updated incrementally: power += |new|² - |old|²
  // Use only top bits for normalization shift calculation
  reg [2*WIDTH+TAP_ADDR-1:0] power_sum;  // Sum of magnitudes squared

  // ── Error signals ──────────────────────────────────────────────────────
  reg signed [WIDTH-1:0] err_i, err_q;

  // ── Normalization: approximate 1/power as right-shift ──────────────────
  // Find MSB position of power_sum → shift = msb_pos - MU_SHIFT
  // This avoids division entirely.
  reg [5:0] norm_shift;

  // ── Helper: read delay line at (wr_ptr - offset) mod DLINE_LEN ─────────
  // We need to read x[n-Δ-k] during COMPUTE and UPDATE phases
  wire [ADDR_BITS-1:0] rd_offset = DELAY[ADDR_BITS-1:0] + tap_cnt[ADDR_BITS-1:0];
  wire [ADDR_BITS-1:0] rd_addr_raw = wr_ptr - rd_offset;
  // Modular arithmetic for non-power-of-2 length
  wire [ADDR_BITS-1:0] rd_addr = (rd_addr_raw >= DLINE_LEN) ?
                                  (rd_addr_raw + DLINE_LEN[ADDR_BITS-1:0]) : rd_addr_raw;

  reg signed [WIDTH-1:0] dl_rd_i, dl_rd_q;

  // Read delay line (1-cycle read)
  always @(posedge clk) begin
    dl_rd_i <= dline_i[rd_addr];
    dl_rd_q <= dline_q[rd_addr];
  end

  // Read weights (1-cycle read, during COMPUTE and UPDATE)
  reg signed [WWIDTH-1:0] w_rd_i, w_rd_q;
  wire [TAP_ADDR-1:0] w_addr = tap_cnt[TAP_ADDR-1:0];
  always @(posedge clk) begin
    w_rd_i <= w_i[w_addr];
    w_rd_q <= w_q[w_addr];
  end

  // ── DSP48 multiply: complex multiply components ────────────────────────
  // During COMPUTE: acc += w · x* (complex conjugate multiply for correlation)
  //   re_part = w_i·dl_i + w_q·dl_q
  //   im_part = w_q·dl_i - w_i·dl_q
  // During UPDATE: new_w = w + mu_norm · e · x*
  //   Δw_i = mu_norm · (e_i·dl_i + e_q·dl_q)
  //   Δw_q = mu_norm · (e_q·dl_i - e_i·dl_q)

  wire signed [WIDTH+WWIDTH-1:0] mul_ii, mul_qq, mul_qi, mul_iq;
  // Registered multiplies (DSP48 inferred)
  reg signed [WIDTH+WWIDTH-1:0] mul_ii_r, mul_qq_r, mul_qi_r, mul_iq_r;

  // Mux operands based on state
  wire signed [WWIDTH-1:0] op_a_i = (state == S_COMPUTE) ? w_rd_i : err_i[WIDTH-1:WIDTH-WWIDTH];
  wire signed [WWIDTH-1:0] op_a_q = (state == S_COMPUTE) ? w_rd_q : err_q[WIDTH-1:WIDTH-WWIDTH];

  assign mul_ii = op_a_i * dl_rd_i;
  assign mul_qq = op_a_q * dl_rd_q;
  assign mul_qi = op_a_q * dl_rd_i;
  assign mul_iq = op_a_i * dl_rd_q;

  always @(posedge clk) begin
    mul_ii_r <= mul_ii;
    mul_qq_r <= mul_qq;
    mul_qi_r <= mul_qi;
    mul_iq_r <= mul_iq;
  end

  // ── MSB finder for normalization (priority encoder) ─────────────────────
  function [5:0] find_msb;
    input [2*WIDTH+TAP_ADDR-1:0] val;
    integer i;
    begin
      find_msb = 0;
      for (i = 0; i < 2*WIDTH+TAP_ADDR; i = i + 1)
        if (val[i]) find_msb = i[5:0];
    end
  endfunction

  // ── Delay line write & main FSM ────────────────────────────────────────
  // Pipeline: tap_cnt runs 0..NTAPS+1 (extra cycles for pipeline flush)
  // tap_cnt=0: first read issued, data arrives at tap_cnt=1, multiply result at tap_cnt=2
  // So accumulation runs from tap_cnt=2 to NTAPS+1

  integer k;

  always @(posedge clk) begin
    if (rst) begin
      state    <= S_IDLE;
      tap_cnt  <= 0;
      wr_ptr   <= 0;
      acc_i    <= 0;
      acc_q    <= 0;
      err_i    <= 0;
      err_q    <= 0;
      i_out    <= 0;
      q_out    <= 0;
      stb_out  <= 1'b0;
      x_i      <= 0;
      x_q      <= 0;
      power_sum <= 1;  // Avoid division by zero
      norm_shift <= 0;
      for (k = 0; k < DLINE_LEN; k = k + 1) begin
        dline_i[k] <= 0;
        dline_q[k] <= 0;
      end
      for (k = 0; k < NTAPS; k = k + 1) begin
        w_i[k] <= 0;
        w_q[k] <= 0;
      end
    end else begin
      stb_out <= 1'b0;

      case (state)
        S_IDLE: begin
          if (stb_in) begin
            // Latch input and write to delay line
            x_i <= i_in;
            x_q <= q_in;
            dline_i[wr_ptr] <= i_in;
            dline_q[wr_ptr] <= q_in;

            // Update power estimate incrementally
            // Add |x[n-Δ]|², subtract |x[n-Δ-NTAPS]|²
            // For simplicity, recompute norm_shift from accumulated power
            // (the actual power_sum is maintained via running sum)

            // Start FIR computation
            acc_i   <= 0;
            acc_q   <= 0;
            tap_cnt <= 0;
            state   <= S_COMPUTE;
          end
        end

        S_COMPUTE: begin
          // Pipeline: read issued at tap_cnt, data at tap_cnt+1, multiply at tap_cnt+2
          // Accumulate from tap_cnt >= 2
          if (tap_cnt >= 2) begin
            acc_i <= acc_i + mul_ii_r + mul_qq_r;  // Re(w · x*) = wi·xi + wq·xq
            acc_q <= acc_q + mul_qi_r - mul_iq_r;  // Im(w · x*) = wq·xi - wi·xq
          end

          if (tap_cnt == NTAPS + 1) begin
            // FIR output is in acc (after this last accumulation)
            // Compute error = x[n] - ŝ[n] (truncate accumulator to WIDTH)
            // acc is Q(WIDTH+WWIDTH+TAP_ADDR) — the FIR output has WWIDTH fractional bits
            // ŝ[n] ≈ acc >>> WWIDTH (keeping WIDTH MSBs)
            state   <= S_UPDATE;
            tap_cnt <= 0;

            // Extract FIR output (ŝ) and compute error
            // Weights are Q1.17, so product is shifted by 17 bits
            // Add the last accumulation
            begin : compute_error
              reg signed [ACC_WIDTH-1:0] final_acc_i, final_acc_q;
              reg signed [WIDTH:0] s_hat_i, s_hat_q;
              reg signed [WIDTH:0] err_wide_i, err_wide_q;

              final_acc_i = acc_i + mul_ii_r + mul_qq_r;
              final_acc_q = acc_q + mul_qi_r - mul_iq_r;

              // Extract WIDTH+1 MSBs from accumulator, shifted by WWIDTH-1
              // (WWIDTH-1 because weights are Q1.17, not Q0.17)
              s_hat_i = final_acc_i[ACC_WIDTH-1:ACC_WIDTH-WIDTH-1];
              s_hat_q = final_acc_q[ACC_WIDTH-1:ACC_WIDTH-WIDTH-1];

              // Error = input - prediction (sign-extended to WIDTH+1)
              err_wide_i = {x_i[WIDTH-1], x_i} - s_hat_i;
              err_wide_q = {x_q[WIDTH-1], x_q} - s_hat_q;

              // Clip error to WIDTH bits
              if (err_wide_i[WIDTH] != err_wide_i[WIDTH-1])
                err_i <= err_wide_i[WIDTH] ? {1'b1, {(WIDTH-1){1'b0}}} : {1'b0, {(WIDTH-1){1'b1}}};
              else
                err_i <= err_wide_i[WIDTH-1:0];

              if (err_wide_q[WIDTH] != err_wide_q[WIDTH-1])
                err_q <= err_wide_q[WIDTH] ? {1'b1, {(WIDTH-1){1'b0}}} : {1'b0, {(WIDTH-1){1'b1}}};
              else
                err_q <= err_wide_q[WIDTH-1:0];

              // Output = prediction (enhanced signal), clipped to WIDTH
              if (s_hat_i[WIDTH] != s_hat_i[WIDTH-1])
                i_out <= s_hat_i[WIDTH] ? {1'b1, {(WIDTH-1){1'b0}}} : {1'b0, {(WIDTH-1){1'b1}}};
              else
                i_out <= s_hat_i[WIDTH-1:0];

              if (s_hat_q[WIDTH] != s_hat_q[WIDTH-1])
                q_out <= s_hat_q[WIDTH] ? {1'b1, {(WIDTH-1){1'b0}}} : {1'b0, {(WIDTH-1){1'b1}}};
              else
                q_out <= s_hat_q[WIDTH-1:0];
            end

            // Compute normalization shift
            norm_shift <= find_msb(power_sum);
          end else begin
            tap_cnt <= tap_cnt + 1;
          end

          // Accumulate power during COMPUTE phase (recompute from scratch)
          if (tap_cnt == 0)
            power_sum <= 1;  // Reset + epsilon
          if (tap_cnt >= 1 && tap_cnt <= NTAPS) begin
            // |x|² ≈ |I|² + |Q|² — use upper bits to prevent overflow
            power_sum <= power_sum +
              {{TAP_ADDR{1'b0}}, dl_rd_i[WIDTH-1:WIDTH/2] * dl_rd_i[WIDTH-1:WIDTH/2]} +
              {{TAP_ADDR{1'b0}}, dl_rd_q[WIDTH-1:WIDTH/2] * dl_rd_q[WIDTH-1:WIDTH/2]};
          end
        end

        S_UPDATE: begin
          // Weight update: w[k] += μ·e·x*/||x||²
          // μ/||x||² ≈ 2^(-MU_SHIFT) / 2^norm_shift = 2^(-(MU_SHIFT+norm_shift))
          // Implemented as: (e·x*) >>> total_shift
          // Pipeline: read at tap_cnt, data at +1, multiply at +2, write at +2
          if (tap_cnt >= 2) begin
            // mul_ii_r = err_i_trunc · dl_i, etc.
            // Δw_i = (err_i·dl_i + err_q·dl_q) >>> total_shift
            // Δw_q = (err_q·dl_i - err_i·dl_q) >>> total_shift
            begin : update_weights
              reg signed [WIDTH+WWIDTH:0] dw_i_raw, dw_q_raw;
              reg signed [WWIDTH-1:0] dw_i, dw_q;
              reg signed [WWIDTH:0] new_w_i, new_w_q;
              reg [5:0] total_shift;

              dw_i_raw = (mul_ii_r + mul_qq_r);
              dw_q_raw = (mul_qi_r - mul_iq_r);

              // Total normalization shift
              total_shift = MU_SHIFT[5:0] + norm_shift;
              // Clamp shift to prevent over-shift
              if (total_shift > (WIDTH + WWIDTH - 1))
                total_shift = WIDTH + WWIDTH - 1;

              // Apply shift and truncate to WWIDTH
              dw_i = dw_i_raw >>> total_shift;
              dw_q = dw_q_raw >>> total_shift;

              // Update weights with saturation
              new_w_i = {w_rd_i[WWIDTH-1], w_rd_i} + {dw_i[WWIDTH-1], dw_i};
              new_w_q = {w_rd_q[WWIDTH-1], w_rd_q} + {dw_q[WWIDTH-1], dw_q};

              // Clip to WWIDTH
              if (new_w_i[WWIDTH] != new_w_i[WWIDTH-1])
                w_i[tap_cnt - 2] <= new_w_i[WWIDTH] ? {1'b1, {(WWIDTH-1){1'b0}}} : {1'b0, {(WWIDTH-1){1'b1}}};
              else
                w_i[tap_cnt - 2] <= new_w_i[WWIDTH-1:0];

              if (new_w_q[WWIDTH] != new_w_q[WWIDTH-1])
                w_q[tap_cnt - 2] <= new_w_q[WWIDTH] ? {1'b1, {(WWIDTH-1){1'b0}}} : {1'b0, {(WWIDTH-1){1'b1}}};
              else
                w_q[tap_cnt - 2] <= new_w_q[WWIDTH-1:0];
            end
          end

          if (tap_cnt == NTAPS + 1) begin
            // All weights updated — advance write pointer, emit output
            wr_ptr  <= (wr_ptr == DLINE_LEN - 1) ? {ADDR_BITS{1'b0}} : wr_ptr + 1;
            stb_out <= 1'b1;
            state   <= S_IDLE;
          end else begin
            tap_cnt <= tap_cnt + 1;
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule // ale_nlms
