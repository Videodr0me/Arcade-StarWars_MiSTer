// ============================================================================
// Vector Framebuffer — DDRAM Pixel Renderer by Videodr0me 2026:
//
// Vector-to-raster interface convention (X/Y/Z/RGB/BEAM_ON/BEAM_ENA)
// follows the pattern established by Dave Wood's Black Widow renderer.
//
// Renders Atari AVG vector output into a 980×700 8bpp indexed-color
// framebuffer stored in DDRAM, using MISTER_FB for display.
//
//   Vector Generator (12 MHz)         DDRAM Controller (50 MHz)
//   ┌───────────────────┐           ┌─────────────────────────────┐
//   │ AVG + Drawer      │  Async    │  Stage 1: FIFO Pop          │
//   │ X/Y/Z/RGB/BEAM_ON ┼──FIFO───> │  Stage 2: Decode + Address  │
//   │ FRAME_DONE (EOF)  │  (8K×28b) │  Stage 3: DDRAM Write       │
//   └───────────────────┘  CDC      └─────────────────────────────┘
//
// Clock domain crossing:
//   Entries are pushed into an 8K-deep async FIFO using Gray-coded pointers 
//   for safe CDC to the 50 MHz DDRAM domain (clk_sys).
//
// Pixel pipeline (3 stages, clk_sys):
//   Stage 1 — FIFO FETCH: Pop one 28-bit entry.
//   Stage 2 — DECODE/ADDR: If EOF → trigger buffer swap + clear.
//             If pixel → compute DDRAM word address and byte lane:
//             addr = (Y×1024 + X) / 8,  byte_enable = 1 << (addr % 8).
//             Y×1024 = Y<<10 (stride is power of 2, no decomposition needed).
//   Stage 3 — DDRAM WRITE: Issue a single-beat Avalon-MM write with
//             byte enables (no read-modify-write needed).
//
// Triple buffering:
//   980×700 framebuffers (stride 1024) at DDRAM byte offsets 0x30000000,
//   0x300B0000, 0x30160000 (700 KB each, ~2.1 MB total):
//     display_buf      — being scanned out by the MiSTer scaler
//     draw_buf         — receiving new pixels from the pipeline
//     ready_buf        — completed frame waiting for next VBL swap
//     clear_target_buf — being zeroed after a swap
//   On EOF: draw_buf → ready_buf, free buffer → draw_buf + clear_target_buf.
//   On VBL: ready_buf → display_buf (if valid). Guarantees tear-free output.
//
// OSD_FLICKER mode:
//   When enabled, bypasses triple buffering and uses simple double-buffer.
//   This produces visible (fake) vector flicker, looking best in 120hz.
// ============================================================================

module vector_fb_ddram (
	input         clk_sys,  // Master DDRAM clock (50MHz)
	input         clk_12,   // Vector generator clock
	input         reset,
	
	// Vector inputs
	input  [9:0]  X_VECTOR,
	input  [9:0]  Y_VECTOR,
	input  [4:0]  Z_VECTOR,
	input  [2:0]  RGB,
	input         BEAM_ON,
	input         BEAM_ENA,

	// DDRAM Framebuffer Interface
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	// MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	// Custom frame sync signals
	input         START_FRAME,
	input         FRAME_DONE,
	input         OSD_FLICKER,
	output        FIFO_FULL_LED
);

	// ------------------------------------------------------------------------
	// MISTER_FB Configuration
	// ------------------------------------------------------------------------
	assign FB_EN     = 1'b1;
	assign FB_FORMAT = 5'b00011; // 8bpp indexed
	assign FB_WIDTH  = 980;
	assign FB_HEIGHT = 700;
	assign FB_STRIDE = 1024;
	assign FB_FORCE_BLANK = 1'b0;

	// ------------------------------------------------------------------------
	// DDRAM Clock and Read (Unused)
	// ------------------------------------------------------------------------
	assign DDRAM_CLK = clk_sys;
	assign DDRAM_RD = 1'b0;

	// ------------------------------------------------------------------------
	// Triple Buffers
	// ------------------------------------------------------------------------
	reg [1:0] display_buf;
	reg [1:0] draw_buf;
	reg [1:0] ready_buf;
	reg [1:0] clear_target_buf;

	reg [2:0] vbl_sync;
	wire vbl_edge = vbl_sync[1] && !vbl_sync[2];

	// FB_BASE outputs the ACTIVE buffer for display (byte address),
	// while DDRAM_ADDR is a 64-bit word index (8 bytes per unit).
	assign FB_BASE = (display_buf == 2'd2) ? 32'h30160000 : 
	                 (display_buf == 2'd1) ? 32'h300B0000 : 
	                                         32'h30000000; 

	// Drawing occurs on the INACTIVE buffer
	wire [28:0] draw_base_word = (draw_buf == 2'd2) ? 29'h0602C000 : 
	                             (draw_buf == 2'd1) ? 29'h06016000 : 
	                                                  29'h06000000;

	// Clear target buffer immediately after a swap
	wire [28:0] clear_base_word = (clear_target_buf == 2'd2) ? 29'h0602C000 : 
	                              (clear_target_buf == 2'd1) ? 29'h06016000 : 
	                                                           29'h06000000;

	// ------------------------------------------------------------------------
	// Palette Initialization
	// ------------------------------------------------------------------------
	reg [7:0] pal_addr = 0;
	reg       pal_wr = 0;

	// 8 primary/secondary colors * 32 intensity levels = 256 Palette entries
	wire [2:0] pal_rgb = pal_addr[7:5];
	wire [4:0] pal_int = pal_addr[4:0];
	wire [7:0] channel_val = {pal_int, pal_int[4:2]};

	assign FB_PAL_DOUT = {
		pal_rgb[2] ? channel_val : 8'h00, // Red
		pal_rgb[1] ? channel_val : 8'h00, // Green
		pal_rgb[0] ? channel_val : 8'h00  // Blue
	};

	assign FB_PAL_CLK  = clk_sys;
	assign FB_PAL_ADDR = pal_addr;
	assign FB_PAL_WR   = pal_wr;
	
	reg pal_init_done = 0;
	always @(posedge clk_sys) begin
		if (reset) begin
			pal_addr <= 0;
			pal_wr <= 0;
			pal_init_done <= 0;
		end else if (!pal_init_done) begin
			pal_wr <= 1'b1;
			if (pal_addr == 8'd255) begin
				pal_init_done <= 1'b1;
				pal_wr <= 1'b0;
			end else begin
				pal_addr <= pal_addr + 1'b1;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Async FIFO (Vector Gen -> DDRAM Controller)
	// ------------------------------------------------------------------------
	(* ramstyle = "M10K" *) reg [27:0] fifo_mem [0:8191]; 
	reg [13:0] wr_ptr = 0, wr_ptr_g = 0;
	reg [13:0] rd_ptr = 0, rd_ptr_g = 0;
	
	function [13:0] b2g(input [13:0] b);
		b2g = b ^ (b >> 1);
	endfunction
	
	function [13:0] g2b(input [13:0] g);
		reg [13:0] b;
		begin
			b[13] = g[13];
			b[12] = b[13] ^ g[12];
			b[11] = b[12] ^ g[11];
			b[10] = b[11] ^ g[10];
			b[9]  = b[10] ^ g[9];
			b[8]  = b[9]  ^ g[8];
			b[7]  = b[8]  ^ g[7];
			b[6]  = b[7]  ^ g[6];
			b[5]  = b[6]  ^ g[5];
			b[4]  = b[5]  ^ g[4];
			b[3]  = b[4]  ^ g[3];
			b[2]  = b[3]  ^ g[2];
			b[1]  = b[2]  ^ g[1];
			b[0]  = b[1]  ^ g[0];
			g2b = b;
		end
	endfunction

	// --- WRITE SIDE (clk_12) ---
	reg [9:0] last_x, last_y;
	reg       last_beam_on;
	reg       last_frame_done;
	
	// Synchronize read pointer to write domain
	reg [13:0] rd_ptr_g_sync1 = 0, rd_ptr_g_sync2 = 0;
	always @(posedge clk_12) begin
		rd_ptr_g_sync1 <= rd_ptr_g;
		rd_ptr_g_sync2 <= rd_ptr_g_sync1;
	end
	
	wire [13:0] rd_ptr_bin = g2b(rd_ptr_g_sync2);
	wire [13:0] fifo_used = wr_ptr - rd_ptr_bin;
	wire fifo_full_flag = (fifo_used > 14'd8100);

	reg [19:0] led_timer = 0;
	always @(posedge clk_12) begin
		if (fifo_full_flag) led_timer <= 20'hFFFFF;
		else if (led_timer != 0) led_timer <= led_timer - 1'b1;
	end
	assign FIFO_FULL_LED = (led_timer != 0);
	
	// Pre-calculate conditions to ensure a SINGLE RAM assignment
	wire push_eof = (FRAME_DONE && !last_frame_done);
	wire push_pix = (BEAM_ON && (X_VECTOR != last_x || Y_VECTOR != last_y || !last_beam_on));
	wire fifo_we  = push_eof || push_pix;
	wire [27:0] fifo_din = push_eof ? 28'hFFFFFFF : {Z_VECTOR, RGB, Y_VECTOR, X_VECTOR};
	
	always @(posedge clk_12) begin
		last_x <= X_VECTOR;
		last_y <= Y_VECTOR;
		last_beam_on <= BEAM_ON;
		last_frame_done <= FRAME_DONE;
		
		if (reset) begin
			wr_ptr <= 0;
			wr_ptr_g <= 0;
		end else if (fifo_we) begin
			// Single write assignment for Quartus BRAM inference
			fifo_mem[wr_ptr[12:0]] <= fifo_din;
			wr_ptr <= wr_ptr + 1'b1;
			wr_ptr_g <= b2g(wr_ptr + 1'b1);
		end
	end
	// --- READ SIDE (clk_sys, 50MHz) ---
	// Pipeline Stages
	reg        stage2_valid;
	reg [27:0] stage2_data;
	
	reg        stage3_valid;
	reg [28:0] stage3_addr;
	reg [7:0]  stage3_be;
	reg [7:0]  stage3_val; // Color + Intensity

	// Pipeline Data Signals Here
	logic [4:0]  pixel_z;
	logic [2:0]  pixel_c;
	logic [9:0]  pixel_y;
	logic [9:0]  pixel_x;
	logic [19:0] computed_pixel_addr;

	reg [13:0] wr_ptr_g_sync1 = 0, wr_ptr_g_sync2 = 0;
	always @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
	end
	
	wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);

	always @(posedge clk_sys) begin
		stage2_data <= fifo_mem[rd_ptr[12:0]];
	end
	// DDRAM Registers
	reg [63:0] ddram_din_reg;
	reg [28:0] ddram_addr_reg;
	reg [7:0]  ddram_be_reg;
	reg [7:0]  ddram_burst_reg;
	reg        ddram_we_reg;

	assign DDRAM_DIN = ddram_din_reg;
	assign DDRAM_ADDR = ddram_addr_reg;
	assign DDRAM_BE = ddram_be_reg;
	assign DDRAM_BURSTCNT = ddram_burst_reg;
	
	// SAFETY CLAMP
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h0604FFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;

	// Clear State
	reg clearing;
	reg [16:0] clear_addr; // 89600 words = ~700KB buffer

	always @(posedge clk_sys) begin
		vbl_sync <= {vbl_sync[1:0], FB_VBL};

		if (!DDRAM_BUSY) begin
			ddram_we_reg <= 1'b0;
		end

		if (reset) begin
			display_buf <= 2'd0;
			draw_buf <= 2'd1;
			ready_buf <= 2'd3;
			clear_target_buf <= 2'd1;
			
			clearing <= 1'b1;
			clear_addr <= 0;
			
			rd_ptr <= 0;
			rd_ptr_g <= 0;
			stage2_valid <= 1'b0;
			stage3_valid <= 1'b0;
			ddram_we_reg <= 0;
		end else begin
		
			// -------------------------------------------------------------
			// VBLANK (Output Side)
			// -------------------------------------------------------------
			if (OSD_FLICKER) begin
				// Unbuffered On
				if (vbl_edge) begin
					display_buf <= draw_buf;
					draw_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clear_target_buf <= (draw_buf == 2'd0) ? 2'd1 : 2'd0;
					clearing <= 1'b1;
					clear_addr <= 0;
				end
			end else begin
				// Unbuffered Off: TRIPLE BUFFER
				if (vbl_edge && ready_buf != 2'd3) begin
					display_buf <= ready_buf;
					ready_buf <= 2'd3; // Invalidate
				end
			end

			// -------------------------------------------------------------
			// CLEARING LOGIC
			// -------------------------------------------------------------
			if (DDRAM_BUSY) begin
				// Wait
			end else if (clearing) begin
				// CLEAR the new draw buffer before accepting pixels.
				ddram_addr_reg <= clear_base_word + clear_addr;
				ddram_din_reg <= 64'd0;
				ddram_be_reg <= 8'hFF;
				ddram_burst_reg <= 8'd1;
				ddram_we_reg <= 1'b1;
				
				if (clear_addr == 17'd89599) begin
					clearing <= 1'b0;
				end else begin
					clear_addr <= clear_addr + 1'b1;
				end
				
				// FLUSH pipeline stages from the previous frame.
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;

			end else begin
				// --- STAGE 3: PLOT TO DDRAM ---
				if (stage3_valid) begin
					ddram_addr_reg  <= draw_base_word + stage3_addr;
					ddram_be_reg    <= stage3_be;
					ddram_din_reg   <= {8{stage3_val}}; 
					ddram_burst_reg <= 8'd1;
					ddram_we_reg    <= 1'b1;
				end

				// --- STAGE 2: DECODE TOKEN OR CALCULATE ADDRESS ---
				stage3_valid <= 1'b0;
				if (stage2_valid) begin
					if (stage2_data == 28'hFFFFFFF) begin
						// RECEIVED EOF TOKEN!
						if (!OSD_FLICKER) begin
							logic [1:0] next_free_buf;

							// 1. Stash the pointer of the buffer we just finished drawing
							ready_buf <= draw_buf;

							// 2. Find the 3rd unused buffer.
							// We cannot use the currently displayed buffer (display_buf)
							// We cannot use the buffer we JUST finished (draw_buf, which is becoming ready_buf)
							if      (display_buf != 2'd0 && draw_buf != 2'd0) next_free_buf = 2'd0;
							else if (display_buf != 2'd1 && draw_buf != 2'd1) next_free_buf = 2'd1;
							else                                              next_free_buf = 2'd2;

							// 3. Assign BOTH registers to the newly calculated free buffer
							draw_buf         <= next_free_buf;
							clear_target_buf <= next_free_buf;

							// 4. Trigger clear
							clearing   <= 1'b1;
							clear_addr <= 0;
						end
					end  else begin
						// Normal Pixel Assignments
						// stage2_data: {Z[4:0], RGB[2:0], Y[9:0], X[9:0]}
						pixel_z = stage2_data[27:23];
						pixel_c = stage2_data[22:20];
						pixel_y = stage2_data[19:10];
						pixel_x = stage2_data[9:0];
						
						// Safety bounds check (defense-in-depth)
						if (pixel_x < 10'd980 && pixel_y < 10'd700) begin
							// Stride 1024 = 2^10. Y * 1024 = Y << 10
							computed_pixel_addr = {pixel_y, 10'd0} + {10'd0, pixel_x};
							
							stage3_addr <= computed_pixel_addr[19:3];
							stage3_be   <= 8'd1 << computed_pixel_addr[2:0];
							stage3_val  <= {pixel_c, pixel_z};
							stage3_valid <= 1'b1;
						end
					end
				end

				// --- STAGE 1: FETCH FROM FIFO ---
				stage2_valid <= !fifo_empty;
				
				if (!fifo_empty) begin
					rd_ptr <= rd_ptr + 1'b1;
					rd_ptr_g <= b2g(rd_ptr + 1'b1);
				end
			end
		end
	end

endmodule