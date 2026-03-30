//
// Impulse Noise Blanker — Adaptive threshold for LibreSDR B220
// V11 — F4TNK
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Detects and blanks impulsive noise spikes that exceed an adaptive threshold.
//
// Theory:
//   Maintain running RMS estimate: rms² ≈ E[|x|²] via exponential averaging.
//   If |x[n]|² > K² × rms², replace x[n] with zero (blanking).
//   The RMS estimate is updated only from non-blanked samples to prevent
//   the threshold from rising to accommodate the impulses.
//
//   K=4 (16× power threshold) gives ~0.003% false-positive rate on Gaussian noise.
//
// Implementation:
//   - Power |x|² = I² + Q² using 2 DSP48E1 (time-muxed on same DSP pair)
//   - RMS² estimated via IIR: rms² += (|x|² - rms²) >> α, α=16 (τ≈65536 samples)
//   - Threshold = rms² << 4 (= 16 × rms² = (4 × rms)²)
//   - 3-sample look-ahead pipeline for zero-latency blanking
//   - Always active, no bypass register
//
// Cost: 2 DSP48E1, ~300 LUT, ~400 FF
//

module impulse_blanker #(
  parameter WIDTH     = 24,
  parameter ALPHA     = 16,     // IIR time constant: τ ≈ 2^ALPHA samples
  parameter THRESHOLD = 4       // K in threshold computation (K² shift = 2*log2(K) = 4)
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
  // K² threshold implemented as left-shift by 2*log2(K)
  // For K=4: shift=4 (since 4²=16=2^4)
  localparam K_SQ_SHIFT = 2 * $clog2(THRESHOLD);
  // Power width: |I|² + |Q|² can be up to 2 × (2^(WIDTH-1))² ≈ 2^(2*WIDTH-1)
  localparam PWR_WIDTH  = 2 * WIDTH;

  // ── Pipeline delay line (3 samples for look-ahead) ──────────────────────
  reg signed [WIDTH-1:0] pipe_i [0:2];
  reg signed [WIDTH-1:0] pipe_q [0:2];
  reg [2:0] pipe_stb;

  // ── Power computation ──────────────────────────────────────────────────
  // Use top half bits to limit multiplier width (saves area)
  localparam HALF = WIDTH / 2;  // 12 bits
  wire signed [HALF-1:0] i_top = i_in[WIDTH-1:WIDTH-HALF];
  wire signed [HALF-1:0] q_top = q_in[WIDTH-1:WIDTH-HALF];

  // DSP48 multiply (12×12 = 24 bits each, well within 25×18)
  wire signed [2*HALF-1:0] i_sq = i_top * i_top;
  wire signed [2*HALF-1:0] q_sq = q_top * q_top;

  // Total power (unsigned, always positive since squared)
  // Both i_sq and q_sq are non-negative (signed squared)
  wire [2*HALF:0] power = {1'b0, i_sq[2*HALF-2:0]} + {1'b0, q_sq[2*HALF-2:0]};

  // ── Running RMS² estimate (exponential IIR) ────────────────────────────
  reg [PWR_WIDTH-1:0] rms_sq;  // Running average of |x|²
  wire blanked;

  // Threshold comparison: is power > K² × rms_sq?
  // Equivalent: power > rms_sq << K_SQ_SHIFT
  // But we shift power right instead to avoid overflow: power >> K_SQ_SHIFT > rms_sq
  // Actually: compare power with rms_sq[PWR_WIDTH-1:PWR_WIDTH-(2*HALF+1)] << K_SQ_SHIFT
  // Simpler: threshold in same scale as power
  wire [2*HALF:0] rms_sq_scaled = rms_sq[PWR_WIDTH-1:PWR_WIDTH-(2*HALF+1)];
  wire [2*HALF+K_SQ_SHIFT:0] threshold_val = {rms_sq_scaled, {K_SQ_SHIFT{1'b0}}};
  assign blanked = ({1'b0, power} > threshold_val[2*HALF:0]) && (rms_sq > 0);

  // ── Registered power for pipeline ──────────────────────────────────────
  reg [2*HALF:0] power_r;
  reg blanked_r;
  reg [2:0] blanked_pipe;

  always @(posedge clk) begin
    if (rst) begin
      rms_sq      <= 0;
      power_r     <= 0;
      blanked_r   <= 0;
      blanked_pipe <= 0;
      pipe_stb    <= 0;
      pipe_i[0]   <= 0; pipe_i[1] <= 0; pipe_i[2] <= 0;
      pipe_q[0]   <= 0; pipe_q[1] <= 0; pipe_q[2] <= 0;
      i_out       <= 0;
      q_out       <= 0;
      stb_out     <= 0;
    end else begin
      stb_out <= 0;

      if (stb_in) begin
        // ── Stage 1: Compute power and pipeline ──
        power_r  <= power;
        blanked_r <= blanked;

        // Shift pipeline
        pipe_i[0] <= i_in; pipe_i[1] <= pipe_i[0]; pipe_i[2] <= pipe_i[1];
        pipe_q[0] <= q_in; pipe_q[1] <= pipe_q[0]; pipe_q[2] <= pipe_q[1];
        pipe_stb  <= {pipe_stb[1:0], 1'b1};
        blanked_pipe <= {blanked_pipe[1:0], blanked};

        // ── Stage 2: Update RMS² only if NOT blanked ──
        if (!blanked) begin
          // IIR: rms_sq += (power_extended - rms_sq) >>> ALPHA
          // Use arithmetic right shift for proper tracking
          begin : update_rms
            reg signed [PWR_WIDTH:0] diff;
            diff = {1'b0, {(PWR_WIDTH-2*HALF-1){1'b0}}, power} - {1'b0, rms_sq};
            rms_sq <= rms_sq + {{ALPHA{diff[PWR_WIDTH]}}, diff[PWR_WIDTH:ALPHA]};
          end
        end

        // ── Stage 3: Output oldest sample (blanked or passed) ──
        if (pipe_stb[2]) begin
          if (blanked_pipe[2]) begin
            i_out <= 0;
            q_out <= 0;
          end else begin
            i_out <= pipe_i[2];
            q_out <= pipe_q[2];
          end
          stb_out <= 1'b1;
        end
      end
    end
  end

endmodule // impulse_blanker
