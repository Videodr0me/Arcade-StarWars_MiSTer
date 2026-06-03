// ============================================================================
// Vector Framebuffer — DDRAM Pixel Renderer by Videodr0me 2026:
//
// Vector-to-raster interface convention (X/Y/Z/RGB/BEAM_ON/BEAM_ENA)
// follows the pattern established by Dave Wood's Black Widow renderer.
//
// Renders Atari AVG vector output into framebuffer stored in DDRAM
//
// ============================================================================

module vector_fb_ddram (
	input         clk_sys,  // Master DDRAM clock (50MHz)
	input         clk_12,   // Vector generator clock
	input         reset,
	
	// Vector inputs
	input  [10:0] X_VECTOR,
	input  [10:0] Y_VECTOR,
	input  [4:0]  Z_VECTOR,
	input  [2:0]  RGB,
	input  [3:0]  EFFECT,
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
	input [11:0] FB_WIDTH,
	input [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	input [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	// Custom frame sync signals
	input  [7:0]  FLASH_PARAM,
	input         OSD_120HZ,
	input         START_FRAME,
	input         FRAME_DONE,
	input         OSD_FLICKER,
	input   [2:0] STAR_PATTERN,
	output        FIFO_FULL_LED
);

	// ------------------------------------------------------------------------
	// MISTER_FB Configuration
	// ------------------------------------------------------------------------
	assign FB_EN     = 1'b1;
	assign FB_FORMAT = 5'b00011; // 8bpp indexed
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
	wire [28:0] buf0_word = 29'h06000000;
	wire [28:0] buf1_word = (FB_STRIDE == 14'd2048) ? 29'h06044000 : 29'h06016000;
	wire [28:0] buf2_word = (FB_STRIDE == 14'd2048) ? 29'h06088000 : 29'h0602C000;

	wire [31:0] buf0_byte = 32'h30000000;
	wire [31:0] buf1_byte = (FB_STRIDE == 14'd2048) ? 32'h30220000 : 32'h300B0000;
	wire [31:0] buf2_byte = (FB_STRIDE == 14'd2048) ? 32'h30440000 : 32'h30160000;

	assign FB_BASE = (display_buf == 2'd2) ? buf2_byte : 
	                 (display_buf == 2'd1) ? buf1_byte : 
	                                         buf0_byte; 

	// Drawing occurs on the INACTIVE buffer
	wire [28:0] draw_base_word = (draw_buf == 2'd2) ? buf2_word : 
	                             (draw_buf == 2'd1) ? buf1_word : 
	                                                  buf0_word;

	// Clear target buffer immediately after a swap
	wire [28:0] clear_base_word = (clear_target_buf == 2'd2) ? buf2_word : 
	                              (clear_target_buf == 2'd1) ? buf1_word : 
	                                                           buf0_word;

	// ------------------------------------------------------------------------
	// Palette Initialization
	// ------------------------------------------------------------------------
	reg [7:0] pal_addr = 0;
	reg       pal_wr = 0;

	// 8 primary/secondary colors * 32 intensity levels = 256 Palette entries
	wire [2:0] pal_rgb = pal_addr[7:5];
	wire [4:0] pal_int = pal_addr[4:0];
	
	wire [7:0] custom_pal [0:31] = '{
		8'd0, 8'd8, 8'd16, 8'd24, 8'd32, 8'd40, 8'd48, 8'd56,
		8'd64, 8'd72, 8'd80, 8'd88, 8'd96, 8'd104, 8'd112, 8'd120,
		8'd128, 8'd136, 8'd144, 8'd152, 8'd160, 8'd168, 8'd176, 8'd184,
		8'd192, 8'd200, 8'd208, 8'd216, 8'd224, 8'd232, 8'd243, 8'd255
	};
	
	wire [7:0] channel_val = custom_pal[pal_int];
	
	wire [7:0] base_r = pal_rgb[2] ? channel_val : 8'd0;
	wire [7:0] base_g = pal_rgb[1] ? channel_val : 8'd0;
	wire [7:0] base_b = pal_rgb[0] ? channel_val : 8'd0;

	wire [8:0] flash_r = base_r + FLASH_PARAM;
	wire [8:0] flash_g = base_g + FLASH_PARAM;
	wire [8:0] flash_b = base_b + FLASH_PARAM;

	assign FB_PAL_DOUT = {
		(flash_r > 255) ? 8'd255 : flash_r[7:0],
		(flash_g > 255) ? 8'd255 : flash_g[7:0],
		(flash_b > 255) ? 8'd255 : flash_b[7:0]
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
		end else begin
			if (vbl_edge) begin
				pal_init_done <= 0;
				pal_addr <= 0;
				pal_wr <= 1'b1;
			end else if (!pal_init_done) begin
				if (pal_addr == 8'd255) begin
					pal_init_done <= 1'b1;
					pal_wr <= 1'b0;
				end else begin
					pal_addr <= pal_addr + 1'b1;
				end
			end else begin
				pal_wr <= 1'b0;
			end
		end
	end

	// ------------------------------------------------------------------------
	// Async FIFO (Vector Gen -> DDRAM Controller)
	// ------------------------------------------------------------------------
	(* ramstyle = "M10K" *) reg [63:0] fifo_mem [0:16383]; 
	reg [14:0] wr_ptr = 0, wr_ptr_g = 0;
	reg [14:0] rd_ptr = 0, rd_ptr_g = 0;
	
	function [14:0] b2g(input [14:0] b);
		b2g = b ^ (b >> 1);
	endfunction
	
	function [14:0] g2b(input [14:0] g);
		reg [14:0] b;
		begin
			b[14] = g[14];
			b[13] = b[14] ^ g[13];
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
	reg [10:0] last_x = 0;
	reg [10:0] last_y = 0;
	reg        last_beam_on = 0;
	reg        last_frame_done;
	
	// Synchronize read pointer to write domain
	reg [14:0] rd_ptr_g_sync1 = 0, rd_ptr_g_sync2 = 0;
	reg osd_flicker_reg = 0;
	always @(posedge clk_12) begin
		rd_ptr_g_sync1 <= rd_ptr_g;
		rd_ptr_g_sync2 <= rd_ptr_g_sync1;
		osd_flicker_reg <= OSD_FLICKER;
	end
	
	wire [14:0] rd_ptr_bin = g2b(rd_ptr_g_sync2);
	wire [14:0] fifo_used = wr_ptr - rd_ptr_bin;
	wire fifo_full_flag = (fifo_used > 15'd4096);

	reg [19:0] led_timer = 0;
	always @(posedge clk_12) begin
		if (fifo_full_flag) led_timer <= 20'hFFFFF;
		else if (led_timer != 0) led_timer <= led_timer - 1'b1;
	end
	assign FIFO_FULL_LED = (led_timer != 0);
	
	wire push_eof = (FRAME_DONE && !last_frame_done);
	wire push_pix = (BEAM_ON && (X_VECTOR != last_x || Y_VECTOR != last_y || !last_beam_on));
	wire fifo_we  = push_eof || push_pix;
	
	wire [63:0] fifo_din = {
		START_FRAME,       // 63
		OSD_120HZ,         // 62
		osd_flicker_reg,   // 61
		STAR_PATTERN,      // 60:58
		2'd0,              // 57:56
		BEAM_ENA,          // 55
		FRAME_DONE,        // 54
		EFFECT,            // 53:50
		BEAM_ON,           // 49
		RGB,               // 48:46
		Y_VECTOR,          // 45:35
		X_VECTOR,          // 34:24
		Z_VECTOR,          // 23:19
		19'd0              // 18:0
	};
	
	always @(posedge clk_12) begin
		last_x <= X_VECTOR;
		last_y <= Y_VECTOR;
		last_beam_on <= BEAM_ON;
		last_frame_done <= FRAME_DONE;
		
		if (reset) begin
			wr_ptr <= 0;
			wr_ptr_g <= 0;
		end else if (fifo_we) begin
			fifo_mem[wr_ptr[13:0]] <= fifo_din;
			wr_ptr <= wr_ptr + 1'b1;
			wr_ptr_g <= b2g(wr_ptr + 1'b1);
		end
	end
	// --- READ SIDE (clk_sys, 50MHz) ---
	// Pipeline Stages
	reg        stage2_valid;
	reg [63:0] stage2_data;
	
	reg        stage3_valid;
	reg [18:0] stage3_addr;
	reg [7:0]  stage3_be;
	reg [7:0]  stage3_val; // Color + Intensity

	// Star Rendering State
	reg [2:0] star_state = 0;
	reg [63:0] latched_star_data;
	reg [10:0] star_offset_x;
	reg [10:0] star_offset_y;
	logic [4:0] star_offset_z;

	// Diagonal Fill State
	reg diag_state = 0;
	reg [10:0] diag_corner_x;
	reg [10:0] diag_corner_y;
	reg [4:0]  diag_z;
	reg [2:0]  diag_c;
	reg [10:0] read_last_x = 0;
	reg [10:0] read_last_y = 0;

	// Pipeline Data Signals
	wire [4:0]  pixel_z;
	wire [2:0]  pixel_c;
	wire [10:0] pixel_y;
	wire [10:0] pixel_x;
	wire        pixel_beam_on;
	logic [21:0] computed_pixel_addr;
	wire [3:0]  pixel_effect;
	
	
	wire stall_pipeline = (star_state != 0) || (diag_state != 0);
	wire fifo_read_enable = !DDRAM_BUSY && !clearing && !stall_pipeline && !fifo_empty;
	
	// Isolated read block to guarantee M10K BRAM inference
	always @(posedge clk_sys) begin
		if (fifo_read_enable) begin
			stage2_data <= fifo_mem[rd_ptr[13:0]];
		end
	end

	assign pixel_y = stage2_data[45:35];
	assign pixel_x = stage2_data[34:24];
	assign pixel_c = stage2_data[48:46];
	assign pixel_z = stage2_data[23:19];
	// assign pixel_beam_on = stage2_data[49]; // Unused
	assign pixel_effect = stage2_data[53:50];
	// wire pixel_start_frame = stage2_data[63]; // Unused
	wire pixel_frame_done = stage2_data[54];
	wire [2:0] pixel_star_pattern = stage2_data[60:58];
	wire pixel_osd_flicker = stage2_data[61];

	reg [14:0] wr_ptr_g_sync1 = 0, wr_ptr_g_sync2 = 0;
	always @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
	end
	
	wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);


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
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h060CCFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;

	// Clear State
	reg        clearing = 0;
	reg [20:0] clear_addr = 0; 

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
			
			if (pixel_osd_flicker) begin
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
				ddram_addr_reg <= clear_base_word + clear_addr[18:0];
				ddram_din_reg <= 64'd0;
				ddram_be_reg <= 8'hFF;
				ddram_burst_reg <= 8'd1;
				ddram_we_reg <= 1'b1;
				
				if (clear_addr == ((FB_STRIDE == 14'd2048) ? 21'h41A00 : 21'h15F90)) begin
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
				if (stall_pipeline) begin
					if (star_state != 0) begin
						// We are drawing a multi-pixel star.
						// Use the latched data so we don't lose the Z value or draw the wrong pixel.
						// logic [3:0]  l_effect; // Unused
						logic [4:0]  l_z;
						logic [2:0]  l_c;
						logic [10:0] l_y;
						logic [10:0] l_x;
					
					// l_effect = latched_star_data[53:50]; // Unused
					l_z = latched_star_data[23:19];
					l_c = latched_star_data[48:46];
					l_y = latched_star_data[45:35];
					l_x = latched_star_data[34:24];
					
					// Compute offset based on star_state and STAR_PATTERN
					star_offset_x = l_x;
					star_offset_y = l_y;
					star_offset_z = (l_z > 5'd1) ? {1'b0, l_z[4:1]} : l_z; // Half intensity for neighbors, don't drop 1
					
					if (pixel_star_pattern == 3'd1) begin // 2x2
						if (star_state == 1)      begin star_offset_x = l_x + 11'd1; star_offset_y = l_y; end
						else if (star_state == 2) begin star_offset_x = l_x;         star_offset_y = l_y + 11'd1; end
						else if (star_state == 3) begin star_offset_x = l_x + 11'd1; star_offset_y = l_y + 11'd1; end
						
						if (star_state == 3) begin star_state <= 0; end
						else star_state <= star_state + 1'b1;
					end else if (pixel_star_pattern == 3'd2) begin // Elipse
						if (star_state == 1)      begin star_offset_x = l_x + 11'd1; star_offset_y = l_y; star_offset_z = (l_z > 5'd1) ? (l_z - (l_z >> 2)) : l_z; end
						else if (star_state == 2) begin star_offset_x = l_x - 11'd1; star_offset_y = l_y; star_offset_z = (l_z > 5'd1) ? (l_z - (l_z >> 2)) : l_z; end
						else if (star_state == 3) begin star_offset_x = l_x;         star_offset_y = l_y + 11'd1; end
						else if (star_state == 4) begin star_offset_x = l_x;         star_offset_y = l_y - 11'd1; end
						
						if (star_state == 4) begin star_state <= 0; end
						else star_state <= star_state + 1'b1;
					end else begin
						star_state <= 0; // Default fallback (1x1)
					end
					
					// Draw pixel
					if (star_offset_x < FB_WIDTH && star_offset_y < FB_HEIGHT && star_offset_z > 0) begin
						computed_pixel_addr = (FB_STRIDE == 14'd2048) ? 
						                      {star_offset_y, 11'd0} + {11'd0, star_offset_x} :
						                      {2'b00, star_offset_y[9:0], 10'd0} + {11'd0, star_offset_x};
						stage3_addr <= computed_pixel_addr[21:3];
						stage3_be   <= 8'd1 << computed_pixel_addr[2:0];
						stage3_val  <= {l_c, star_offset_z};
						stage3_valid <= 1'b1;
					end
					end else if (diag_state != 0) begin
						if (diag_corner_x < FB_WIDTH && diag_corner_y < FB_HEIGHT && diag_z > 0) begin
							computed_pixel_addr = (FB_STRIDE == 14'd2048) ? 
							                      {diag_corner_y, 11'd0} + {11'd0, diag_corner_x} :
							                      {2'b00, diag_corner_y[9:0], 10'd0} + {11'd0, diag_corner_x};
							stage3_addr <= computed_pixel_addr[21:3];
							stage3_be   <= 8'd1 << computed_pixel_addr[2:0];
							stage3_val  <= {diag_c, diag_z};
							stage3_valid <= 1'b1;
						end
						diag_state <= 0;
					end

				end else if (stage2_valid) begin
					if (pixel_frame_done) begin
						// RECEIVED EOF TOKEN!
						if (!pixel_osd_flicker) begin
							logic [1:0] next_free_buf;
							ready_buf <= draw_buf;

							if      (display_buf != 2'd0 && draw_buf != 2'd0) next_free_buf = 2'd0;
							else if (display_buf != 2'd1 && draw_buf != 2'd1) next_free_buf = 2'd1;
							else                                              next_free_buf = 2'd2;

							draw_buf         <= next_free_buf;
							clear_target_buf <= next_free_buf;

							clearing   <= 1'b1;
							clear_addr <= 0;
						end
					end else begin
						// Normal Pixel Assignments
						// Safety bounds check. Do NOT draw effect-only pixels (pixel_effect > 1)
						if (pixel_x < FB_WIDTH && pixel_y < FB_HEIGHT && (pixel_effect == 4'b0000 || pixel_effect == 4'b0001)) begin
							computed_pixel_addr = (FB_STRIDE == 14'd2048) ? 
							                      {pixel_y, 11'd0} + {11'd0, pixel_x} :
							                      {2'b00, pixel_y[9:0], 10'd0} + {11'd0, pixel_x};
							stage3_addr <= computed_pixel_addr[21:3];
							stage3_be   <= 8'd1 << computed_pixel_addr[2:0];
							stage3_val  <= {pixel_c, pixel_z};
							stage3_valid <= 1'b1;
						end
						
						if (pixel_effect == 4'b0001 && pixel_star_pattern != 3'd0 && pixel_star_pattern <= 3'd3) begin
							star_state <= 1; // Start multi-pixel sequence
							latched_star_data <= stage2_data;
						end else begin
							logic [10:0] dx;
							logic [10:0] dy;
							dx = (pixel_x >= read_last_x) ? (pixel_x - read_last_x) : (read_last_x - pixel_x);
							dy = (pixel_y >= read_last_y) ? (pixel_y - read_last_y) : (read_last_y - pixel_y);
							if (dx == 11'd1 && dy == 11'd1) begin
								diag_state <= 1;
								diag_corner_x <= pixel_x;
								diag_corner_y <= read_last_y;
								diag_z <= pixel_z;
								diag_c <= pixel_c;
							end
						end
						
						read_last_x <= pixel_x;
						read_last_y <= pixel_y;
					end
				end

				// --- STAGE 1: FETCH FROM FIFO ---
				if (fifo_read_enable) begin
					stage2_valid <= 1'b1;
					rd_ptr <= rd_ptr + 1'b1;
					rd_ptr_g <= b2g(rd_ptr + 1'b1);
				end else if (!stall_pipeline) begin
					// If pipeline isn't stalled but FIFO was empty, bubble it
					stage2_valid <= 1'b0;
				end
			end
		end
	end

endmodule