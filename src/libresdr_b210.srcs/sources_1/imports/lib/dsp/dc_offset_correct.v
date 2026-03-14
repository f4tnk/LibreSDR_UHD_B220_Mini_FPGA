//
// DC Offset Correction Filter for LibreSDR B220 (XC7A200T)
//
// Single-pole IIR high-pass filter: y[n] = x[n] - avg[n]
// where avg[n] = avg[n-1] + (x[n] - avg[n-1]) >> alpha
//
// Alpha controls the cutoff frequency: fc ≈ fs / (2*pi*2^alpha)
// Default alpha=20: at 61.44 MSPS, fc ≈ 9.3 Hz (removes DC, preserves signal)
//
// Fully bypassable via setting register.
// SPDX-License-Identifier: LGPL-3.0-or-later
//

module dc_offset_correct
  #(
    parameter WIDTH = 24,
    parameter ALPHA = 20  // Shift amount for IIR averaging (higher = lower cutoff)
  )
  (
   input                  clk,
   input                  rst,
   input                  bypass,
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

   always @(posedge clk) begin
      if (rst) begin
         avg_i      <= {ACC_WIDTH{1'b0}};
         out        <= {WIDTH{1'b0}};
         strobe_out <= 1'b0;
      end else begin
         strobe_out <= strobe_in;
         if (strobe_in) begin
            if (bypass) begin
               out <= in;
            end else begin
               // Update average: avg += (input - avg) >> ALPHA
               // This is equivalent to: avg = avg + (in_ext - avg_i) >>> ALPHA
               // Simplified: avg += error >> ALPHA where error = in_ext - avg_i
               avg_i <= avg_i + ((in_ext - avg_i) >>> ALPHA);
               out   <= corrected_clip;
            end
         end
      end
   end

endmodule // dc_offset_correct
