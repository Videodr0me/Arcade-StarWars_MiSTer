// ============================================================================
// Audio Filter TL084 - Cascaded 2-pole IIR Low-Pass Filter by Videodr0me
//
// Matches the original Atari Star Wars PCB filter circuit (Sheet 16B):
//   TL084 (1/4 3C) Multiple Feedback Low-Pass topology
//   R39=R40=12K, C48=C49=C50=2700pF -> fc = 4913 Hz
//
// Implementation: two cascaded 1st-order IIR stages at 48 kHz
//   y[n] = y[n-1] + (x[n] - y[n-1]) >>> 1  (alpha = 0.5)
//   Combined -3dB: ~3490 Hz, -12dB/oct asymptotic rolloff
// ============================================================================

module audio_filter_tl084 (
	input              clk,
	input              reset,
	input              ce,       // Clock enable (48 kHz)
	input              enable,   // 1 = filter active, 0 = bypass
	input  signed [16:0] audio_in,
	output signed [16:0] audio_out
);

	reg signed [16:0] s1, s2;

	always @(posedge clk) begin
		if (reset) begin
			s1 <= 17'sd0;
			s2 <= 17'sd0;
		end else if (ce) begin
			s1 <= s1 + ((audio_in - s1) >>> 1);   // Stage 1
			s2 <= s2 + ((s1       - s2) >>> 1);   // Stage 2
		end
	end

	assign audio_out = enable ? s2 : audio_in;

endmodule
