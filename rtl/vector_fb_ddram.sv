// ============================================================================
// High Performance HD Framebuffer — DDRAM Pixel Renderer by Videodr0me 2026:
//
// Vector-to-raster interface convention (X/Y/Z/RGB/BEAM_ON)
// follows the pattern established by Dave Wood's Black Widow renderer.
//
// Renders Atari AVG vector output into framebuffer stored in DDRAM and 
// Manages display pipeline.
// ============================================================================

module vector_fb_ddram (
	input         clk_sys,
	input         clk_12,
	input         reset,
	
	// Vector inputs
	input  [10:0] X_VECTOR,
	input  [10:0] Y_VECTOR,
	input  [7:0]  Z_VECTOR,
	input  [2:0]  RGB,
	input         IS_DOT,
	input         BEAM_ON,

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
	input [11:0]  FB_WIDTH,
	input [11:0]  FB_HEIGHT,
	output [31:0] FB_BASE,
	input [13:0]  FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,

	// Custom and frame sync signals
	input  [7:0]  FLASH_PARAM,
	input         OSD_120HZ,
	input         START_FRAME,
	input         FRAME_DONE,
	input         OSD_FLICKER,
	input   [2:0] STAR_PATTERN,
	output        FIFO_FULL_LED
);

	// MISTER_FB Configuration
	assign FB_EN     = 1'b1;
	assign FB_FORMAT = 5'b00110;
	assign FB_FORCE_BLANK = 1'b0;

	assign DDRAM_CLK = clk_sys;
	reg ddram_rd_reg = 0;
	assign DDRAM_RD = ddram_rd_reg;

	localparam ST_CLEAN    = 3'd0;
	localparam ST_DRAWING  = 3'd1;
	localparam ST_DRAWN    = 3'd2;
	localparam ST_DISPLAY  = 3'd3;
	localparam ST_DIRTY    = 3'd4;
	localparam ST_CLEARING = 3'd5;

	reg [2:0] buf_state [0:3];
	initial begin
		buf_state[0] = ST_DISPLAY;
		buf_state[1] = ST_DIRTY;
		buf_state[2] = ST_DIRTY;
		buf_state[3] = ST_DIRTY;
	end

	// Combinational State Finders (Instant 0-clock resolution)
	wire [1:0] clean_idx   = (buf_state[0]==ST_CLEAN)   ? 2'd0 : (buf_state[1]==ST_CLEAN)   ? 2'd1 : (buf_state[2]==ST_CLEAN)   ? 2'd2 : 2'd3;
	wire       has_clean   = (buf_state[0]==ST_CLEAN)   | (buf_state[1]==ST_CLEAN)   | (buf_state[2]==ST_CLEAN)   | (buf_state[3]==ST_CLEAN);

	wire [1:0] drawn_idx   = (buf_state[0]==ST_DRAWN)   ? 2'd0 : (buf_state[1]==ST_DRAWN)   ? 2'd1 : (buf_state[2]==ST_DRAWN)   ? 2'd2 : 2'd3;
	wire       has_drawn   = (buf_state[0]==ST_DRAWN)   | (buf_state[1]==ST_DRAWN)   | (buf_state[2]==ST_DRAWN)   | (buf_state[3]==ST_DRAWN);

	wire [1:0] dirty_idx   = (buf_state[0]==ST_DIRTY)   ? 2'd0 : (buf_state[1]==ST_DIRTY)   ? 2'd1 : (buf_state[2]==ST_DIRTY)   ? 2'd2 : 2'd3;
	wire       has_dirty   = (buf_state[0]==ST_DIRTY)   | (buf_state[1]==ST_DIRTY)   | (buf_state[2]==ST_DIRTY)   | (buf_state[3]==ST_DIRTY);

	wire       is_clearing = (buf_state[0]==ST_CLEARING)| (buf_state[1]==ST_CLEARING)| (buf_state[2]==ST_CLEARING)| (buf_state[3]==ST_CLEARING);
	wire [1:0] clearing_idx= (buf_state[0]==ST_CLEARING)? 2'd0 : (buf_state[1]==ST_CLEARING)? 2'd1 : (buf_state[2]==ST_CLEARING)? 2'd2 : 2'd3;

	// Current Pointers based on states
	reg [1:0] display_buf = 2'd0;
	reg [1:0] draw_buf    = 2'd1;

	reg draw_stall = 1;

	reg [2:0] vbl_sync = 3'b000;
	wire vbl_edge = vbl_sync[1] && !vbl_sync[2];

	// FB_BASE outputs the ACTIVE buffer for display (byte address),
	// while DDRAM_ADDR is a 64-bit word index (8 bytes per unit).
	wire [28:0] buf0_word = 29'h06000000;
	wire [28:0] buf1_word = (FB_STRIDE == 14'd8192) ? 29'h06110000 : 29'h06060000;
	wire [28:0] buf2_word = (FB_STRIDE == 14'd8192) ? 29'h06220000 : 29'h060C0000;
	wire [28:0] buf3_word = (FB_STRIDE == 14'd8192) ? 29'h06330000 : 29'h06120000;

	wire [31:0] buf0_byte = 32'h30000000;
	wire [31:0] buf1_byte = (FB_STRIDE == 14'd8192) ? 32'h30880000 : 32'h30300000;
	wire [31:0] buf2_byte = (FB_STRIDE == 14'd8192) ? 32'h31100000 : 32'h30600000;
	wire [31:0] buf3_byte = (FB_STRIDE == 14'd8192) ? 32'h31980000 : 32'h30900000;

	assign FB_BASE = (display_buf == 2'd3) ? buf3_byte : 
	                 (display_buf == 2'd2) ? buf2_byte : 
	                 (display_buf == 2'd1) ? buf1_byte : 
	                                         buf0_byte; 

	wire [28:0] draw_base_word = (draw_buf == 2'd3) ? buf3_word :
	                             (draw_buf == 2'd2) ? buf2_word : 
	                             (draw_buf == 2'd1) ? buf1_word : 
	                                                  buf0_word;



	assign FB_PAL_DOUT = 24'd0;   // Unused
	assign FB_PAL_CLK  = clk_sys; // Unused
	assign FB_PAL_ADDR = 8'd0;    // Unused
	assign FB_PAL_WR   = 1'b0; // Unused

	// Async FIFO (Vector Gen -> DDRAM Controller)
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
	reg        last_frame_done = 0;
	
	// Synchronize read pointer to write domain
	reg [14:0] rd_ptr_g_sync1 = 0, rd_ptr_g_sync2 = 0;
	always @(posedge clk_12) begin
		rd_ptr_g_sync1 <= rd_ptr_g;
		rd_ptr_g_sync2 <= rd_ptr_g_sync1;
	end
	
	wire [14:0] rd_ptr_bin = g2b(rd_ptr_g_sync2);
	wire [14:0] fifo_used = wr_ptr - rd_ptr_bin;
	wire fifo_full_flag = (fifo_used > 15'd256);

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
		1'b0,              // 62
		1'b0,              // 61
		3'b0,              // 60:58
		1'b0,              // 57
		FRAME_DONE,        // 56
		3'b0,              // 55:53 
		IS_DOT,            // 52
		BEAM_ON,           // 51
		RGB,               // 50:48
		Y_VECTOR,          // 47:37
		X_VECTOR,          // 36:26
		Z_VECTOR,          // 25:18
		18'd0              // 17:0
	};
	
	// CDC Reset Synchronizer for clk_12 (to safely catch the raw reset for wr_ptr)
	reg [1:0] rst_12_sync = 2'b11;
	always @(posedge clk_12) rst_12_sync <= {rst_12_sync[0], reset | (FB_WIDTH == 0) | (FB_HEIGHT == 0)};
	wire rst_12 = rst_12_sync[1];

	always @(posedge clk_12) begin
		last_x <= X_VECTOR;
		last_y <= Y_VECTOR;
		last_beam_on <= BEAM_ON;
		last_frame_done <= FRAME_DONE;
		
		if (rst_12) begin
			wr_ptr <= 0;
			wr_ptr_g <= 0;
		end else if (fifo_we) begin
			fifo_mem[wr_ptr[13:0]] <= fifo_din;
			wr_ptr <= wr_ptr + 1'b1;
			wr_ptr_g <= b2g(wr_ptr + 1'b1);
		end
	end
	// --- READ SIDE ---
	// Pipeline Stages
	reg        stage2_valid = 0;
	reg [63:0] stage2_data;
	
	reg        stage3_valid;
	reg [20:0] stage3_addr;
	reg [31:0] stage3_val;
	reg [7:0]  stage3_be;
	reg [28:0] stage3_draw_base;
	reg [21:0] computed_pixel_addr;
	reg [63:0] latched_star_data;
	reg [15:0] latched_y_offset;
	
	typedef enum logic {
		ST_PRIMARY = 1'b0,
		ST_SUB     = 1'b1
	} stage2_state_t;
	
	typedef enum logic [1:0] {
		SUB_DIAG  = 2'd0,
		SUB_STAR1 = 2'd1,
		SUB_STAR2 = 2'd2
	} sub_mode_t;
	
	stage2_state_t stage2_state = ST_PRIMARY;
	sub_mode_t     sub_mode     = SUB_DIAG;
	logic [2:0]    sub_idx      = 0;

	reg [10:0] diag_corner_x;
	reg [10:0] diag_corner_y;
	reg [7:0]  diag_z;
	reg [2:0]  diag_c;
	reg [10:0] read_last_x = 0;
	reg [10:0] read_last_y = 0;

	// Pipeline Data Signals
	wire [7:0]  pixel_z;
	wire [2:0]  pixel_c;
	wire [10:0] pixel_y;
	wire [10:0] pixel_x;
	wire        pixel_beam_on;
	wire        pixel_is_dot;
	// Subpixel Combinatorial Generator
	logic [10:0] next_x, next_y;
	logic [7:0]  next_z;
	logic [2:0]  next_c;
	logic        next_valid;

	always_comb begin
		next_valid = 1'b0;
		next_x = pixel_x;
		next_y = pixel_y;
		next_z = pixel_z;
		next_c = pixel_c;
		
		if (stage2_valid && !pixel_frame_done) begin
			if (stage2_state == ST_PRIMARY) begin
				next_x = pixel_x;
				next_y = pixel_y;
				next_z = pixel_z;
				next_c = pixel_c;
				next_valid = (pixel_x < FB_WIDTH && pixel_y < FB_HEIGHT);
			end else if (stage2_state == ST_SUB) begin
				if (sub_mode == SUB_DIAG) begin
					next_x = diag_corner_x;
					next_y = diag_corner_y;
					next_z = diag_z;
					next_c = diag_c;
					next_valid = (next_x < FB_WIDTH && next_y < FB_HEIGHT && next_z > 0);
				end else begin
					// Star
					logic [7:0]  l_z;
					logic [2:0]  l_c;
					logic [10:0] l_y;
					logic [10:0] l_x;
					
					l_z = latched_star_data[25:18];
					l_c = latched_star_data[50:48];
					l_y = latched_star_data[47:37];
					l_x = latched_star_data[36:26];
					
					next_c = l_c;
					if (sub_mode == SUB_STAR1) begin
						next_z = l_z; // Double pattern keeps the same Z
						if (sub_idx == 1)      begin next_x = l_x + 11'd1; next_y = l_y; end
						else if (sub_idx == 2) begin next_x = l_x;         next_y = l_y + 11'd1; end
						else                   begin next_x = l_x + 11'd1; next_y = l_y + 11'd1; end
					end else begin
						if (sub_idx == 1 || sub_idx == 2) begin
							next_z = (l_z > 8'd1) ? (l_z - {2'b00, l_z[7:2]}) : l_z; // 3/4 Z for Left/Right
						end else begin
							next_z = (l_z > 8'd1) ? {1'b0, l_z[7:1]} : l_z;          // 1/2 Z for Top/Bottom
						end

						if (sub_idx == 1)      begin next_x = l_x + 11'd1; next_y = l_y; end
						else if (sub_idx == 2) begin next_x = l_x - 11'd1; next_y = l_y; end
						else if (sub_idx == 3) begin next_x = l_x;         next_y = l_y + 11'd1; end
						else                   begin next_x = l_x;         next_y = l_y - 11'd1; end
					end
					next_valid = (next_x < FB_WIDTH && next_y < FB_HEIGHT && next_z > 0);
				end
			end
		end
	end

	wire fifo_read_enable = !DDRAM_BUSY && !clearing_tile && !stage2_valid && !fifo_empty && !draw_stall && !force_clear;
	
	// CDC Reset Synchronizer for clk_sys
	reg [1:0] rst_sys_sync = 2'b11;
	always @(posedge clk_sys) rst_sys_sync <= {rst_sys_sync[0], reset};
	wire rst_sys = rst_sys_sync[1];

	// Isolated read block to guarantee M10K BRAM inference
	always @(posedge clk_sys) begin
		if (fifo_read_enable) begin
			stage2_data <= fifo_mem[rd_ptr[13:0]];
		end
	end

	assign pixel_y = stage2_data[47:37];
	assign pixel_x = stage2_data[36:26];
	assign pixel_c = stage2_data[50:48];
	assign pixel_z = stage2_data[25:18];
	// assign pixel_beam_on = stage2_data[51];
	assign pixel_is_dot = stage2_data[52];
	// wire pixel_start_frame = stage2_data[63];
	wire pixel_frame_done = stage2_data[56];
	wire [2:0] pixel_star_pattern = STAR_PATTERN;

	reg [14:0] wr_ptr_g_sync1 = 0, wr_ptr_g_sync2 = 0;
	reg osd_flicker_old = 0, osd_flicker_reg = 0;
	always @(posedge clk_sys) begin
		wr_ptr_g_sync1 <= wr_ptr_g;
		wr_ptr_g_sync2 <= wr_ptr_g_sync1;
		osd_flicker_reg <= osd_flicker_old;
		osd_flicker_old <= OSD_FLICKER;
	end
	
	wire fifo_empty = (rd_ptr_g == wr_ptr_g_sync2);


	// DDRAM Registers
	reg [63:0] ddram_din_reg;
	reg [28:0] ddram_addr_reg;
	reg [7:0]  ddram_be_reg;
	reg [7:0]  ddram_burst_reg;
	reg        ddram_we_reg = 0;

	assign DDRAM_DIN = ddram_din_reg;
	assign DDRAM_ADDR = ddram_addr_reg;
	assign DDRAM_BE = ddram_be_reg;
	assign DDRAM_BURSTCNT = ddram_burst_reg;
	
	// SAFETY CLAMP !
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h064FFFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;


	wire [5:0]  tile_cols = FB_WIDTH[10:5] + {5'd0, |FB_WIDTH[4:0]};
	wire [10:0] line_rows = FB_HEIGHT[10:0];

	reg [5:0]  stage3_tile_x;
	reg [10:0] stage3_line_y;
	reg [1:0]  stage3_draw_buf;

	// BRAM initializer
	reg        bram_init = 1;
	reg [15:0] bram_init_addr = 0;
	
	// Latch to capture 1-cycle reset pulses
	reg reset_pending = 0;

	// Pixel pipeline offset
	wire [15:0] pix_offset = ({5'd0, stage3_line_y} << 5) + ({5'd0, stage3_line_y} << 4) + {10'd0, stage3_tile_x};
	wire        pix_tile_wr = stage3_valid && !p_reading; // Only write BRAM when processing
	wire [15:0] scan_offset = ({5'd0, scan_y} << 5) + ({5'd0, scan_y} << 4) + {10'd0, scan_x};

	reg [5:0]  scan_wr_col_reg = 0;
	reg [10:0] scan_wr_y_reg = 0;
	wire [15:0] clear_wr_offset = ({5'd0, scan_wr_y_reg} << 5) + ({5'd0, scan_wr_y_reg} << 4) + {10'd0, scan_wr_col_reg};

	// Fast MUX to select absolute offset delta based on sub_idx, bypassing shift-add logic
	wire [10:0] l_x_calc = latched_star_data[36:26];
	wire [5:0]  l_x_plus_5  = (l_x_calc + 11'd1) >> 5;
	wire [5:0]  l_x_minus_5 = (l_x_calc - 11'd1) >> 5;
	wire [5:0]  l_x_5       = l_x_calc[10:5];

	reg [15:0] total_delta;
	always_comb begin
		total_delta = {10'd0, next_x[10:5]};
		if (stage2_state == ST_SUB) begin
			if (sub_mode == SUB_STAR1) begin
				if (sub_idx == 1) total_delta = {10'd0, l_x_plus_5};
				else if (sub_idx == 2) total_delta = 16'd48 + {10'd0, l_x_5};
				else if (sub_idx == 3) total_delta = 16'd48 + {10'd0, l_x_plus_5};
			end else if (sub_mode == SUB_STAR2) begin
				if (sub_idx == 1) total_delta = {10'd0, l_x_plus_5};
				else if (sub_idx == 2) total_delta = {10'd0, l_x_minus_5};
				else if (sub_idx == 3) total_delta = 16'd48 + {10'd0, l_x_5};
				else if (sub_idx == 4) total_delta = -16'd48 + {10'd0, l_x_5};
			end
		end
	end

	// Select the correct Y-offset base
	wire [15:0] next_y_offset = 
		(stage2_state == ST_PRIMARY) ? ({5'd0, pixel_y} << 5) + ({5'd0, pixel_y} << 4) :
		latched_y_offset;

	wire [15:0] pre_pix_offset = next_y_offset + total_delta;

	// Size must match TILE_BRAM_DEPTH.
	localparam TILE_BRAM_DEPTH = 65536;
	(* ramstyle = "M10K" *) reg tile_dirty_0 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_1 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_2 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_3 [0:TILE_BRAM_DEPTH-1];

	// BRAM Read Ports (multiplexed between scanner and pixel pipeline)
	wire [15:0] rd_addr_0 = (stage3_draw_buf == 2'd0) ? pre_pix_offset : scan_offset;
	wire [15:0] rd_addr_1 = (stage3_draw_buf == 2'd1) ? pre_pix_offset : scan_offset;
	wire [15:0] rd_addr_2 = (stage3_draw_buf == 2'd2) ? pre_pix_offset : scan_offset;
	wire [15:0] rd_addr_3 = (stage3_draw_buf == 2'd3) ? pre_pix_offset : scan_offset;

	reg scan_rd_0, scan_rd_1, scan_rd_2, scan_rd_3;
	always @(posedge clk_sys) begin
		scan_rd_0 <= tile_dirty_0[rd_addr_0];
		scan_rd_1 <= tile_dirty_1[rd_addr_1];
		scan_rd_2 <= tile_dirty_2[rd_addr_2];
		scan_rd_3 <= tile_dirty_3[rd_addr_3];
	end

	wire tile_rd_data_raw = (latched_clear_buf == 2'd0) ? scan_rd_0 :
	                        (latched_clear_buf == 2'd1) ? scan_rd_1 :
	                        (latched_clear_buf == 2'd2) ? scan_rd_2 : scan_rd_3;

	wire pix_rd = (stage3_draw_buf == 2'd0) ? scan_rd_0 :
	              (stage3_draw_buf == 2'd1) ? scan_rd_1 :
	              (stage3_draw_buf == 2'd2) ? scan_rd_2 : scan_rd_3;

	// Additive Blending Read-Modify-Write Pipeline (Write-Through Cache)
	reg [20:0] cache_addr = 21'h1FFFFF; // Invalid address
	reg [1:0]  cache_buf  = 2'd0;
	reg [63:0] cache_data = 64'd0;
	reg        cache_valid = 1'b0;
	reg        p_reading = 1'b0;
	
	// Combinational Saturating Adders for RGB
	wire [7:0] px_b = stage3_val[7:0];
	wire [7:0] px_g = stage3_val[15:8];
	wire [7:0] px_r = stage3_val[23:16];
	
	// --- Pixel 0 Blending Logic ---
	// 1. Determine "non-involved" channels for the incoming vector
	wire r0_non_involved = (px_r == 8'd0);
	wire g0_non_involved = (px_g == 8'd0);
	wire b0_non_involved = (px_b == 8'd0);

	// 2. Pure Add Drive
	wire [8:0] sum_b0 = {1'b0, px_b} + {1'b0, cache_data[7:0]};
	wire [8:0] sum_g0 = {1'b0, px_g} + {1'b0, cache_data[15:8]};
	wire [8:0] sum_r0 = {1'b0, px_r} + {1'b0, cache_data[23:16]};

	wire [7:0] sat_b0 = sum_b0[8] ? 8'hFF : sum_b0[7:0];
	wire [7:0] sat_g0 = sum_g0[8] ? 8'hFF : sum_g0[7:0];
	wire [7:0] sat_r0 = sum_r0[8] ? 8'hFF : sum_r0[7:0];

	wire [6:0] spill_b0 = sum_b0[8] ? sum_b0[7:1] : 7'd0;
	wire [6:0] spill_g0 = sum_g0[8] ? sum_g0[7:1] : 7'd0;
	wire [6:0] spill_r0 = sum_r0[8] ? sum_r0[7:1] : 7'd0;

	// 3. Distribute half-excess to non-involved channels
	// Ternary adder (3-input addition natively mapped to ALM)
	wire [8:0] temp_b0 = {1'b0, sat_b0} + {2'b00, spill_r0} + {2'b00, spill_g0};
	wire [8:0] temp_g0 = {1'b0, sat_g0} + {2'b00, spill_r0} + {2'b00, spill_b0};
	wire [8:0] temp_r0 = {1'b0, sat_r0} + {2'b00, spill_g0} + {2'b00, spill_b0};

	// 4. Final Combination
	wire [7:0] final_b0 = b0_non_involved ? ((sat_b0[7] || sat_b0[6]) ? sat_b0 : ((temp_b0[8] || temp_b0[7] || temp_b0[6]) ? 8'd64 : temp_b0[7:0])) : sat_b0;
	wire [7:0] final_g0 = g0_non_involved ? ((sat_g0[7] || sat_g0[6]) ? sat_g0 : ((temp_g0[8] || temp_g0[7] || temp_g0[6]) ? 8'd64 : temp_g0[7:0])) : sat_g0;
	wire [7:0] final_r0 = r0_non_involved ? ((sat_r0[7] || sat_r0[6]) ? sat_r0 : ((temp_r0[8] || temp_r0[7] || temp_r0[6]) ? 8'd64 : temp_r0[7:0])) : sat_r0;

	// --- Pixel 1 Blending Logic ---
	// 1. Determine "non-involved" channels for the incoming vector
	wire r1_non_involved = (px_r == 8'd0);
	wire g1_non_involved = (px_g == 8'd0);
	wire b1_non_involved = (px_b == 8'd0);

	// 2. Pure Add Drive
	wire [8:0] sum_b1 = {1'b0, px_b} + {1'b0, cache_data[39:32]};
	wire [8:0] sum_g1 = {1'b0, px_g} + {1'b0, cache_data[47:40]};
	wire [8:0] sum_r1 = {1'b0, px_r} + {1'b0, cache_data[55:48]};

	wire [7:0] sat_b1 = sum_b1[8] ? 8'hFF : sum_b1[7:0];
	wire [7:0] sat_g1 = sum_g1[8] ? 8'hFF : sum_g1[7:0];
	wire [7:0] sat_r1 = sum_r1[8] ? 8'hFF : sum_r1[7:0];

	wire [6:0] spill_b1 = sum_b1[8] ? sum_b1[7:1] : 7'd0;
	wire [6:0] spill_g1 = sum_g1[8] ? sum_g1[7:1] : 7'd0;
	wire [6:0] spill_r1 = sum_r1[8] ? sum_r1[7:1] : 7'd0;

	// 3. Distribute half-excess to non-involved channels
	// Ternary adder (3-input addition natively mapped to ALM)
	wire [8:0] temp_b1 = {1'b0, sat_b1} + {2'b00, spill_r1} + {2'b00, spill_g1};
	wire [8:0] temp_g1 = {1'b0, sat_g1} + {2'b00, spill_r1} + {2'b00, spill_b1};
	wire [8:0] temp_r1 = {1'b0, sat_r1} + {2'b00, spill_g1} + {2'b00, spill_b1};

	// 4. Final Combination
	wire [7:0] final_b1 = b1_non_involved ? ((sat_b1[7] || sat_b1[6]) ? sat_b1 : ((temp_b1[8] || temp_b1[7] || temp_b1[6]) ? 8'd64 : temp_b1[7:0])) : sat_b1;
	wire [7:0] final_g1 = g1_non_involved ? ((sat_g1[7] || sat_g1[6]) ? sat_g1 : ((temp_g1[8] || temp_g1[7] || temp_g1[6]) ? 8'd64 : temp_g1[7:0])) : sat_g1;
	wire [7:0] final_r1 = r1_non_involved ? ((sat_r1[7] || sat_r1[6]) ? sat_r1 : ((temp_r1[8] || temp_r1[7] || temp_r1[6]) ? 8'd64 : temp_r1[7:0])) : sat_r1;

	wire [63:0] blended_cache = {
		cache_data[63:56], final_r1, final_g1, final_b1,
		cache_data[31:24], final_r0, final_g0, final_b0
	};
	
	wire [8:0] bz_b = {1'b0, px_b} + {1'b0, FLASH_PARAM};
	wire [8:0] bz_g = {1'b0, px_g} + {1'b0, FLASH_PARAM};
	wire [8:0] bz_r = {1'b0, px_r} + {1'b0, FLASH_PARAM};

	wire [7:0] final_bz_b = bz_b[8] ? 8'hFF : bz_b[7:0];
	wire [7:0] final_bz_g = bz_g[8] ? 8'hFF : bz_g[7:0];
	wire [7:0] final_bz_r = bz_r[8] ? 8'hFF : bz_r[7:0];

	// For clean tiles
	wire [63:0] blended_zero = {
		8'd0, final_bz_r, final_bz_g, final_bz_b,
		8'd0, final_bz_r, final_bz_g, final_bz_b
	};

	wire [63:0] cache_din_hit  = (stage3_be[0] == 1'b1) ? {cache_data[63:32], blended_cache[31:0]} : {blended_cache[63:32], cache_data[31:0]};
	
	wire [31:0] flash_bg = {8'd0, FLASH_PARAM, FLASH_PARAM, FLASH_PARAM};
	wire [63:0] cache_din_zero = (stage3_be[0] == 1'b1) ? 
		{flash_bg, blended_zero[31:0]} : 
		{blended_zero[63:32], flash_bg};

	reg        sweep_active = 0;
	reg [3:0]  swept_mask = 4'b0000;
	reg        latched_sweep = 0;

	// Apply hit flash logic combinationally outside the RAM block to ensure M10K inference
	wire tile_rd_data = tile_rd_data_raw | (|FLASH_PARAM) | latched_sweep;

	// --- BRAM Write Ports ---
	// Write sources: bram_init (all 4), pix_tile_wr (draw_buf only), scan_wr_req (clear_buf only)
	// By design, draw_buf != latched_clear_buf, so pix and clear writes target different BRAMs.
	reg scan_wr_req = 0;

	wire [3:0]  wr_en;
	wire [15:0] wr_addr [0:3];
	wire [3:0]  wr_data;

	genvar i;
	generate
		for (i = 0; i < 4; i = i + 1) begin : bram_ports
			assign wr_en[i]   = bram_init || (pix_tile_wr && stage3_draw_buf == i) || (scan_wr_req && latched_clear_buf == i);
			assign wr_addr[i] = bram_init ? bram_init_addr : (scan_wr_req && latched_clear_buf == i) ? clear_wr_offset : pix_offset;
			assign wr_data[i] = bram_init ? 1'b1 : (scan_wr_req && latched_clear_buf == i) ? 1'b0 : 1'b1;
		end
	endgenerate

	always @(posedge clk_sys) begin
		if (wr_en[0]) tile_dirty_0[wr_addr[0]] <= wr_data[0];
		if (wr_en[1]) tile_dirty_1[wr_addr[1]] <= wr_data[1];
		if (wr_en[2]) tile_dirty_2[wr_addr[2]] <= wr_data[2];
		if (wr_en[3]) tile_dirty_3[wr_addr[3]] <= wr_data[3];
	end


	// Scanner FSM — runs permanently
	reg        scan_active = 0;
	reg        scan_phase = 0;
	reg        group_active = 0;
	reg        next_tile_valid = 0;
	reg [5:0]  next_tile_col_start = 0;
	reg [5:0]  next_tile_col_end = 0;
	reg [10:0] next_tile_row = 0;
	reg        scan_done = 0;

	reg [10:0] scan_y = 0;
	reg [5:0]  scan_x = 0;

	reg        scan_restart = 0;
	reg        scan_go = 0;

	always @(posedge clk_sys) begin
		if (rst_sys) begin
			scan_active <= 0;
			group_active <= 0;
			next_tile_valid <= 0;
			scan_done <= 0;
			scan_phase <= 0;
		end else begin
			if (scan_restart) begin
				scan_y <= 11'd0;
				scan_x <= 6'd0;
				scan_active <= 1'b1;
				scan_phase <= 1'b0;
				group_active <= 1'b0;
				next_tile_valid <= 1'b0;
				scan_done <= 1'b0;
			end else if (scan_go && !scan_active) begin
				scan_active <= 1'b1;
				scan_phase <= 1'b0;
				group_active <= 1'b0;
				next_tile_valid <= 1'b0;
			end

			if (scan_active) begin
				if (scan_phase == 1'b0) begin
					// Phase 0: check if current address is past valid range
					if (scan_y >= line_rows) begin
						scan_done <= 1'b1;
						scan_active <= 1'b0;
					end else begin
						// Address presented to BRAM — wait one clock for data
						scan_phase <= 1'b1;
					end
				end else begin
					// Phase 1: BRAM data available for scan_addr
					if (tile_rd_data) begin
						if (!group_active) begin
							// Start a new group
							group_active <= 1'b1;
							next_tile_row <= scan_y;
							next_tile_col_start <= scan_x;
							next_tile_col_end <= scan_x;
						end else begin
							// Extend current group
							next_tile_col_end <= scan_x;
						end

						if (scan_x >= tile_cols - 1'b1) begin
							next_tile_valid <= 1'b1;
							group_active <= 1'b0;
							scan_x <= 6'd0;
							scan_y <= scan_y + 1'b1;
							scan_active <= 1'b0; // Pause to consume group
						end else begin
							scan_x <= scan_x + 1'b1;
						end
						scan_phase <= 1'b0;
					end else begin
						// If we had an active group, it's now finished.
						if (group_active) begin
							next_tile_valid <= 1'b1;
							group_active <= 1'b0;
							scan_active <= 1'b0; // Pause to let consume group
						end else begin
							// Just keep searching
							if (scan_x >= tile_cols - 1'b1) begin
								scan_x <= 6'd0;
								scan_y <= scan_y + 1'b1;
							end else begin
								scan_x <= scan_x + 1'b1;
							end
							scan_phase <= 1'b0;
						end
					end
				end
			end
		end
	end

	// ------------------------------------------------------------------------
	// Main DDRAM State Machine
	// ------------------------------------------------------------------------
	reg        clearing = 0;
	reg        clearing_tile = 0;
	reg [10:0] clear_x = 0;
	reg [10:0] clear_y = 0;
	reg [5:0]  current_col = 0;
	reg [5:0]  clear_col_end = 0;
	reg        clear_pending = 0;
	reg [28:0] latched_clear_base;
	reg [1:0]  latched_clear_buf;
	
	reg        last_flash_active = 0;

	reg force_clear = 0;

	reg vbl_swap_req = 0;
	reg eof_swap_req = 0;

	// Pipeline idle condition
	wire pipeline_idle = fifo_empty && !stage2_valid && !stage3_valid && !p_reading;

	// READY / VALID Handshake Signals
	wire stage3_hit = (stage3_addr == cache_addr && cache_valid && cache_buf == stage3_draw_buf);
	wire stage3_clean_miss = (!stage3_hit && pix_rd == 1'b0);
	wire stage3_ready = (!DDRAM_BUSY && !clearing_tile && !p_reading && stage3_valid) && (stage3_hit || stage3_clean_miss);

	always @(posedge clk_sys) begin
		vbl_sync <= {vbl_sync[1:0], FB_VBL};

		if (!DDRAM_BUSY) begin
			ddram_we_reg <= 1'b0;
			ddram_rd_reg <= 1'b0;
		end

		scan_restart <= 1'b0;
		scan_go <= 1'b0;
		scan_wr_req <= 1'b0;
		vbl_swap_req <= 1'b0;
		eof_swap_req <= 1'b0;

		if (rst_sys || reset_pending || FB_WIDTH == 0 || FB_HEIGHT == 0) begin
			if (reset_pending == 1'b0) begin
				reset_pending <= 1'b1;
				buf_state[0] <= ST_DISPLAY;
				buf_state[1] <= ST_DIRTY;
				buf_state[2] <= ST_DIRTY;
				buf_state[3] <= ST_DIRTY;
				display_buf <= 2'd0;
				draw_buf <= 2'd1;
				draw_stall <= 1'b1;
				clearing <= 1'b0;
				clear_y <= 0;
				scan_wr_col_reg <= 0;
				scan_wr_y_reg <= 0;
				clear_pending <= 1'b1;
				last_flash_active <= 0;
				sweep_active <= 0;
				swept_mask <= 0;
				force_clear <= 0;
				
				rd_ptr <= 0;
				rd_ptr_g <= 0;
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				stage2_state <= ST_PRIMARY;
				bram_init <= 1'b1;
				bram_init_addr <= 0;
				cache_valid <= 0;
				p_reading <= 0;
			end

			// Drain any active DDRAM burst gracefully (runs in parallel)
			if (clearing_tile) begin
				if (DDRAM_BUSY) begin
				end else begin
					ddram_be_reg <= 8'h00;
					if (clear_x[3:0] == 4'hF) begin
						clearing_tile <= 1'b0; // Burst done — proceed to reset init
						ddram_we_reg <= 1'b0;
						ddram_burst_reg <= 8'd0;
					end else begin
						ddram_we_reg <= 1'b1;
						clear_x <= clear_x + 1'b1;
					end
				end
			end else begin
				clear_x <= 0;
				clearing_tile <= 1'b0;
				if (!DDRAM_BUSY) begin
					ddram_we_reg <= 1'b0;
					ddram_rd_reg <= 1'b0;
					ddram_burst_reg <= 0;
				end
			end

			// BRAM Initialization Phase (runs in parallel)
			if (bram_init) begin
				bram_init_addr <= bram_init_addr + 1'b1;
				if (bram_init_addr == TILE_BRAM_DEPTH - 1) begin
					bram_init <= 1'b0;
				end
			end

			// Release reset_pending only when both parallel tasks are complete AND hard reset is released
			if (!clearing_tile && !bram_init && !rst_sys && FB_WIDTH != 0 && FB_HEIGHT != 0) begin
				reset_pending <= 1'b0;
			end
		end else begin

			// VBLANK Swap Request
			if (vbl_edge) begin
				vbl_swap_req <= 1'b1;
			end

			// DDRAM Bus Arbitration (Priority Chain)
			if (DDRAM_BUSY) begin
				// Wait — DDRAM busy

			// --- Priority 1: Active burst ---
			end else if (clearing_tile) begin
				ddram_addr_reg <= latched_clear_base
					+ ((FB_STRIDE == 14'd8192) ? {clear_y, 10'd0} : {clear_y, 9'd0})
					+ clear_x;
				ddram_din_reg <= {8'd0, FLASH_PARAM, FLASH_PARAM, FLASH_PARAM,
				                  8'd0, FLASH_PARAM, FLASH_PARAM, FLASH_PARAM};
				ddram_be_reg <= 8'hFF;
				ddram_burst_reg <= 8'd16;
				ddram_we_reg <= 1'b1;

				if (clear_x[3:0] == 4'hF) begin
					// Mark ONLY after DDRAM burst is written
					scan_wr_req <= 1'b1;
					scan_wr_col_reg <= current_col;
					scan_wr_y_reg <= clear_y;

					if (current_col == clear_col_end) begin
						// Check for seamless chain:
						if (next_tile_valid && !scan_go && (pipeline_idle || force_clear)) begin
							// SEAMLESS CHAIN: Instantly load next group
							current_col <= next_tile_col_start;
							clear_col_end <= next_tile_col_end;
							clear_x <= {next_tile_col_start, 4'd0};
							clear_y <= next_tile_row;
							scan_go <= 1'b1;
						end else begin
							// Group done, no next group ready yet
							clearing_tile <= 1'b0;
						end
					end else begin
						// Continue current group seamlessly
						current_col <= current_col + 1'b1;
						clear_x <= {current_col + 1'b1, 4'd0};
					end
				end else begin
					clear_x <= clear_x + 1'b1;
				end

			// --- Priority 2: Pixel write to DDRAM ---
			end else if (stage3_valid && !force_clear && !p_reading) begin
				if (stage3_addr == cache_addr && cache_valid && cache_buf == stage3_draw_buf) begin
					// CACHE HIT
					ddram_addr_reg  <= stage3_draw_base + stage3_addr;
					ddram_be_reg    <= stage3_be;
					ddram_din_reg   <= cache_din_hit;
					ddram_burst_reg <= 8'd1;
					ddram_we_reg    <= 1'b1;
					// Consumed
					stage3_valid <= 1'b0;
					cache_data      <= cache_din_hit;
				end else begin
					// CACHE MISS
					if (pix_rd == 1'b0) begin
						// CLEAN TILE -> Write directly! No read needed.
						cache_addr      <= stage3_addr;
						cache_buf       <= stage3_draw_buf;
						cache_valid     <= 1'b1;
						cache_data      <= cache_din_zero;
						
						ddram_addr_reg  <= stage3_draw_base + stage3_addr;
						ddram_be_reg    <= stage3_be;
						ddram_din_reg   <= cache_din_zero;
						ddram_burst_reg <= 8'd1;
						ddram_we_reg    <= 1'b1;
						// Consumed
						stage3_valid    <= 1'b0;
					end else begin
						// DIRTY TILE: Fetch from DDRAM
						p_reading       <= 1'b1;
						ddram_addr_reg  <= stage3_draw_base + stage3_addr;
						ddram_rd_reg    <= 1'b1;
						ddram_burst_reg <= 8'd1;
					end
				end
			end else if (p_reading) begin
				if (DDRAM_DOUT_READY) begin
					p_reading       <= 1'b0;
					cache_addr      <= stage3_addr;
					cache_buf       <= stage3_draw_buf;
					cache_valid     <= 1'b1;
					cache_data      <= DDRAM_DOUT; // Just fill the cache with raw memory and process hit on next cycle
				end

			// --- Priority 3: Load next tile group or finish ---
			end else if (clearing && !clearing_tile) begin
				if (next_tile_valid && !scan_go) begin
					// Scanner has a group ready — start clearing it
					if (pipeline_idle || force_clear || clear_pending || draw_stall) begin
						clearing_tile <= 1'b1;
						current_col <= next_tile_col_start;
						clear_x <= {next_tile_col_start, 4'd0};
						clear_y <= next_tile_row;
						clear_col_end <= next_tile_col_end;
						scan_go <= 1'b1;
					end
					// else: pipeline has work, let it drain first (no yield!)
				end else if (scan_done && !scan_restart) begin
					// Finished scanning the entire buffer — complete!
					clearing <= 1'b0;
					buf_state[clearing_idx] <= ST_CLEAN;
					force_clear <= 1'b0;
					if (latched_sweep) swept_mask[clearing_idx] <= 1'b1;
				end
				// else: scanner still searching, wait (no DDRAM use)

			// --- Start work on dbuffer
			end else if (has_dirty && !is_clearing && (pipeline_idle || clear_pending || draw_stall)) begin
				buf_state[dirty_idx] <= ST_CLEARING;
				clearing <= 1'b1;
				clearing_tile <= 1'b0;
				latched_clear_base <= (dirty_idx == 2'd3) ? buf3_word :
				                      (dirty_idx == 2'd2) ? buf2_word : 
				                      (dirty_idx == 2'd1) ? buf1_word : 
				                                            buf0_word;
				scan_restart <= 1'b1;
				latched_clear_buf <= dirty_idx;
				latched_sweep <= sweep_active && !swept_mask[dirty_idx];

			end else if (clear_pending && !clearing) begin
				clear_pending <= 1'b0;
				// FLUSH pipeline stages from the previous frame.
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				stage2_state <= ST_PRIMARY;
			end

			// =============================================================
			if (!force_clear) begin
				
				// --- STAGE 2: DECODE TOKEN OR CALCULATE ADDRESS ---
				// Only advance stage3 if it is empty or ready to accept a new pixel
				if (!stage3_valid || stage3_ready) begin
					stage3_valid <= 1'b0; // Default to empty, will be overridden if valid pixel output
					
					if (stage2_valid) begin
						if (pixel_frame_done) begin
							// RECEIVED EOF TOKEN!
							read_last_x <= 0;
							read_last_y <= 0;
							eof_swap_req <= 1'b1;
							stage2_valid <= 1'b0;
						end else begin
							// --- 1. Output the Generated Pixel ---
							if (next_valid) begin
								computed_pixel_addr = (FB_STRIDE == 14'd8192) ? 
								                      {next_y, 11'd0} + {11'd0, next_x} :
								                      {2'b00, next_y[9:0], 10'd0} + {11'd0, next_x};
								stage3_addr <= computed_pixel_addr[21:1];
								stage3_be   <= (computed_pixel_addr[0] == 1'b0) ? 8'h0F : 8'hF0;
								stage3_val  <= {8'd0, (next_c[0] ? next_z : 8'd0), (next_c[1] ? next_z : 8'd0), (next_c[2] ? next_z : 8'd0)};
								stage3_tile_x <= next_x[10:5];
								stage3_line_y <= next_y[10:0];
								stage3_draw_buf <= draw_buf;
								stage3_draw_base <= draw_base_word;
								stage3_valid <= 1'b1;
							end
							
							// --- 2. Advance the Sub-Pixel FSM ---
							if (stage2_state == ST_PRIMARY) begin
								logic [10:0] dx;
								logic [10:0] dy;
								dx = (pixel_x >= read_last_x) ? (pixel_x - read_last_x) : (read_last_x - pixel_x);
								dy = (pixel_y >= read_last_y) ? (pixel_y - read_last_y) : (read_last_y - pixel_y);
								
								if (pixel_is_dot && pixel_star_pattern >= 3'd1 && pixel_star_pattern <= 3'd2) begin
									stage2_state <= ST_SUB;
									sub_mode <= (pixel_star_pattern == 3'd1) ? SUB_STAR1 : SUB_STAR2;
									sub_idx <= 1;
									latched_star_data <= stage2_data;
									latched_y_offset <= ({5'd0, stage2_data[47:37]} << 5) + ({5'd0, stage2_data[47:37]} << 4);
								end else if (dx == 11'd1 && dy == 11'd1) begin
									stage2_state <= ST_SUB;
									sub_mode <= SUB_DIAG;
									sub_idx <= 1;
									diag_corner_x <= pixel_x;
									diag_corner_y <= read_last_y;
									latched_y_offset <= ({5'd0, read_last_y} << 5) + ({5'd0, read_last_y} << 4);
									diag_z <= pixel_z;
									diag_c <= pixel_c;
								end else begin
									stage2_valid <= 1'b0; // Token consumed
								end
								read_last_x <= pixel_x;
								read_last_y <= pixel_y;
							end else if (stage2_state == ST_SUB) begin
								if (sub_mode == SUB_DIAG && sub_idx == 1) begin
									stage2_state <= ST_PRIMARY;
									stage2_valid <= 1'b0;
								end else if (sub_mode == SUB_STAR1 && sub_idx == 3) begin
									stage2_state <= ST_PRIMARY;
									stage2_valid <= 1'b0;
								end else if (sub_mode == SUB_STAR2 && sub_idx == 4) begin
									stage2_state <= ST_PRIMARY;
									stage2_valid <= 1'b0;
								end else begin
									sub_idx <= sub_idx + 1'b1;
								end
							end
						end
					end
				end


				// --- STAGE 1: FETCH FROM FIFO ---
				if (fifo_read_enable) begin
					stage2_valid <= 1'b1;
					rd_ptr <= rd_ptr + 1'b1;
					rd_ptr_g <= b2g(rd_ptr + 1'b1);
				end
			end
			
			// --- Draw Stall Recovery (takes priority over swaps) ---
			if (draw_stall && has_clean) begin
				buf_state[clean_idx] <= ST_DRAWING;
				draw_buf <= clean_idx;
				draw_stall <= 1'b0;
				clear_pending <= 1'b0;

			// --- Buffer Swap Routing (only when not recovering from stall) ---
			end else begin
				if (osd_flicker_reg) begin
					if (vbl_swap_req) begin
						buf_state[display_buf] <= ST_DIRTY;
						buf_state[draw_buf] <= ST_DISPLAY;
						display_buf <= draw_buf;
						
						if (has_clean) begin
							buf_state[clean_idx] <= ST_DRAWING;
							draw_buf <= clean_idx;
						end else begin
							draw_stall <= 1'b1;
							if (clearing) force_clear <= 1'b1;
						end
					end
				end else begin
					if (eof_swap_req && !vbl_swap_req) begin
						// AVG Finished a frame, no VBLANK
						if (has_drawn) buf_state[drawn_idx] <= ST_DIRTY; // Drop older frame
						buf_state[draw_buf] <= ST_DRAWN;
						
						if (has_clean) begin
							buf_state[clean_idx] <= ST_DRAWING;
							draw_buf <= clean_idx;
						end else begin
							draw_stall <= 1'b1;
							if (clearing) force_clear <= 1'b1;
						end
					end else if (!eof_swap_req && vbl_swap_req) begin
						// VBLANK only
						if (has_drawn) begin
							buf_state[drawn_idx] <= ST_DISPLAY;
							buf_state[display_buf] <= ST_DIRTY;
							display_buf <= drawn_idx;
						end
					end else if (eof_swap_req && vbl_swap_req) begin
						// BOTH: Bypass ST_DRAWN, display the newly finished frame immediately!
						if (has_drawn) buf_state[drawn_idx] <= ST_DIRTY; // Drop the waiting frame
						buf_state[display_buf] <= ST_DIRTY; // Drop current display
						
						buf_state[draw_buf] <= ST_DISPLAY; // New frame goes straight to display
						display_buf <= draw_buf;
						
						if (has_clean) begin
							buf_state[clean_idx] <= ST_DRAWING;
							draw_buf <= clean_idx;
						end else begin
							draw_stall <= 1'b1;
							if (clearing) force_clear <= 1'b1;
						end
					end
				end
			end

			// Common EOF cleanup (Applies whenever EOF happens)
			if (eof_swap_req) begin
				// Flush pipeline on EOF
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				stage2_state <= ST_PRIMARY;
				cache_valid <= 1'b0;
				p_reading <= 1'b0;
				
				last_flash_active <= (|FLASH_PARAM);
				if (last_flash_active && !(|FLASH_PARAM)) begin
					sweep_active <= 1'b1;
					swept_mask <= 4'b0000;
				end else if (sweep_active && (swept_mask == 4'b1111)) begin
					sweep_active <= 1'b0;
				end
			end
		end
	end

endmodule