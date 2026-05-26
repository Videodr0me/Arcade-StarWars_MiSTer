// ============================================================================
// Reticon R5106 Delay/Stereo by Videodr0me 2026
//
// Models the delay circuit on the original Atari Star Wars PCB (Sheet 16B):
//   R5106 BBD: 512 stages, clocked at 37.8 kHz = 13.5 ms delay
//   Recovery amp: TL084 (1/4 3C) with R45=470K, R46=12K
//   Post-delay filter: TL084 (1/4 2B), R47=12K, C57/C58=2700pF
//
// Schematic analysis (Sheet 16B, fig 2: "Output and Summing Amplifiers")
// shows the delayed signal feeds two TL084 stereo output amps alongside
// the dry "AUD" signal, creating what SWSIG.DOC calls "synthesized stereo."
// My interpretation: Left = dry + wet, Right = dry - wet (pseudo-stereo
// via phase difference). The exact polarity is difficult to confirm from
// the available schematic scans.
//
// At 48 kHz sample rate: 13.5 ms = 648 samples
// Feedback gain: 0.5 models combined BBD/filter/amp path losses
// Uses M10K block RAM (648 x 16 = 10,368 bits)
// ============================================================================

module reticon_r5106 (
	input              clk,
	input              reset,
	input              ce,       // Clock enable (48 kHz)
	input              enable,   // 1 = delay active, 0 = bypass
	input  signed [16:0] audio_in,
	output signed [16:0] audio_out,  // Dry + wet (for left channel)
	output signed [16:0] audio_wet   // Wet only (for stereo difference)
);

	reg signed [15:0] delay_mem [0:647];
	reg [9:0] delay_ptr;
	reg signed [15:0] delay_rd;

	// Delay line: write (input + feedback) into the buffer
	wire signed [16:0] delay_fb  = {{1{delay_rd[15]}}, delay_rd};
	wire signed [16:0] delay_wet_s = delay_fb >>> 1;                // Feedback = 0.5
	wire signed [16:0] delay_mix = audio_in + delay_wet_s;

	always @(posedge clk) begin
		if (reset) begin
			delay_ptr <= 10'd0;
		end else if (ce) begin
			delay_rd         <= delay_mem[delay_ptr];
			delay_mem[delay_ptr] <= delay_mix[15:0];                // Write recirculated
			delay_ptr        <= (delay_ptr == 10'd647) ? 10'd0 : delay_ptr + 10'd1;
		end
	end

	assign audio_out = enable ? delay_mix   : audio_in;
	assign audio_wet = enable ? delay_wet_s : 17'sd0;

endmodule
