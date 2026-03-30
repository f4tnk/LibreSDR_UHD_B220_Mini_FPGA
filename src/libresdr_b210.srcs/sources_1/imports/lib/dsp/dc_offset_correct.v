//
// DC Offset Correction Filter for LibreSDR B220 (XC7A200T) — V10
//
// Single-pole IIR high-pass filter: y[n] = x[n] - avg[n]
// where avg[n] = avg[n-1] + (x[n] - avg[n-1]) >> alpha
//
// V10: Dual-alpha strategy for fast acquisition + precise tracking:
//   - ALPHA_FAST (14): used for first 2^20 samples (~17ms @61.44M) → fc≈600Hz
//   - ALPHA_SLOW (20): steady-state tracking → fc≈9.3Hz
// This ensures fast DC removal on startup/retune without steady-state bias.
//
// Fully bypassable via setting register.
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module dc_offset_correct
  #(
    parameter WIDTH = 24,
    parameter ALPHA = 20,       // Slow (tracking) shift amount
    parameter ALPHA_FAST = 14   // Fast (acquisition) shift amount
  )
  (
   input                  clk,
   input                  rst,
   input                  bypass,
   input                  phase_changed,  // V12: reset settle_cnt on retune
   input                  strobe_in,
   input  [WIDTH-1:0]     in,
   output reg [WIDTH-1:0] out,
   output reg             strobe_out
  );

   // Internal accumulator is wider to hold fractional average
   localparam ACC_WIDTH = WIDTH + ALPHA;

   reg signed [ACC_WIDTH-1:0] avg_i;
   wire signed [WIDTH-1:0] in_s = in;

   // Sign-extend input to accumulator width
   wire signed [ACC_WIDTH-1:0] in_ext = {{ALPHA{in_s[WIDTH-1]}}, in_s};

   // Error = input - current average estimate (only top WIDTH bits of avg matter)
   wire signed [WIDTH-1:0] avg_trunc = avg_i[ACC_WIDTH-1:ALPHA];
   wire signed [WIDTH:0] corrected = {in_s[WIDTH-1], in_s} - {avg_trunc[WIDTH-1], avg_trunc};

   // Clip corrected to WIDTH bits
   wire signed [WIDTH-1:0] corrected_clip;
   assign corrected_clip = (corrected[WIDTH] == corrected[WIDTH-1]) ?
                           corrected[WIDTH-1:0] :
                           (corrected[WIDTH] ? {1'b1, {(WIDTH-1){1'b0}}} : {1'b0, {(WIDTH-1){1'b1}}});

   // V10: Dual-alpha with convergence counter
   reg [20:0] settle_cnt;
   wire settled = settle_cnt[20];   // 2^20 = ~1M samples ≈ 17ms @61.44M
   wire [4:0] alpha_sel = settled ? ALPHA[4:0] : ALPHA_FAST[4:0];

   // Compute update term: (in_ext - avg_i) >>> alpha_sel
   wire signed [ACC_WIDTH-1:0] err_full = in_ext - avg_i;

   // Arithmetic right shift by alpha_sel
   // Use two pre-computed shifts and mux based on settled flag
   wire signed [ACC_WIDTH-1:0] update_fast = (err_full >>> ALPHA_FAST);
   wire signed [ACC_WIDTH-1:0] update_slow = (err_full >>> ALPHA);
   wire signed [ACC_WIDTH-1:0] update = settled ? update_slow : update_fast;

   always @(posedge clk) begin
      if (rst) begin
         avg_i      <= {ACC_WIDTH{1'b0}};
         out        <= {WIDTH{1'b0}};
         strobe_out <= 1'b0;
         settle_cnt <= 21'd0;
      end else begin
         // V12: Reset settle_cnt on retune → fast re-acquisition (~17ms vs ~110ms)
         if (phase_changed)
            settle_cnt <= 21'd0;
         strobe_out <= strobe_in;
         if (strobe_in) begin
            if (bypass) begin
               out <= in;
            end else begin
               avg_i <= avg_i + update;
               out   <= corrected_clip;
               if (!settled)
                 settle_cnt <= settle_cnt + 21'd1;
            end
         end
      end
   end

endmodule // dc_offset_correct
