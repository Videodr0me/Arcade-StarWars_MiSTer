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
	assign DDRAM_RD = 1'b0;

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
	wire [28:0] buf1_word = (FB_STRIDE == 14'd8192) ? 29'h06108000 : 29'h06058000;
	wire [28:0] buf2_word = (FB_STRIDE == 14'd8192) ? 29'h06210000 : 29'h060B0000;
	wire [28:0] buf3_word = (FB_STRIDE == 14'd8192) ? 29'h06318000 : 29'h06108000;

	wire [31:0] buf0_byte = 32'h30000000;
	wire [31:0] buf1_byte = (FB_STRIDE == 14'd8192) ? 32'h30840000 : 32'h302C0000;
	wire [31:0] buf2_byte = (FB_STRIDE == 14'd8192) ? 32'h31080000 : 32'h30580000;
	wire [31:0] buf3_byte = (FB_STRIDE == 14'd8192) ? 32'h318C0000 : 32'h30840000;

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
	wire fifo_full_flag = (fifo_used > 15'd128);

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
	always @(posedge clk_12) rst_12_sync <= {rst_12_sync[0], reset};
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
	reg [7:0]  stage3_be;
	reg [31:0] stage3_val;

	// Star State
	reg [2:0] star_state = 0;
	reg [63:0] latched_star_data;
	reg [10:0] star_offset_x;
	reg [10:0] star_offset_y;
	logic [7:0] star_offset_z;

	reg diag_state = 0;
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
	logic [21:0] computed_pixel_addr;
	wire        pixel_is_dot;
	
	
	wire stall_pipeline = (star_state != 0) || (diag_state != 0);
	wire fifo_read_enable = !DDRAM_BUSY && !clearing_tile && !stall_pipeline && !fifo_empty && !draw_stall && !force_clear;
	
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
	wire safe_address = (ddram_addr_reg >= 29'h06000000) && (ddram_addr_reg <= 29'h0641FFFF);
	assign DDRAM_WE = ddram_we_reg && safe_address;


	wire [5:0]  tile_cols = FB_WIDTH[10:5] + {5'd0, |FB_WIDTH[4:0]};
	wire [10:0] line_rows = FB_HEIGHT[10:0];

	reg [5:0]  stage3_tile_x;
	reg [10:0] stage3_line_y;
	reg [1:0]  stage3_draw_buf;

	// BRAM initializer
	reg        bram_init = 1;
	reg [15:0] bram_init_addr = 0;

	// Pixel pipeline offset
	wire [15:0] pix_offset = ({5'd0, stage3_line_y} << 5) + ({5'd0, stage3_line_y} << 4) + {10'd0, stage3_tile_x};
	wire        pix_tile_wr = stage3_valid && !bram_init;
	wire [15:0] scan_offset = ({5'd0, scan_y} << 5) + ({5'd0, scan_y} << 4) + {10'd0, scan_x};

	reg [5:0]  scan_wr_col_reg = 0;
	reg [10:0] scan_wr_y_reg = 0;
	wire [15:0] clear_wr_offset = ({5'd0, scan_wr_y_reg} << 5) + ({5'd0, scan_wr_y_reg} << 4) + {10'd0, scan_wr_col_reg};

	// Size must match TILE_BRAM_DEPTH.
	localparam TILE_BRAM_DEPTH = 65536;
	(* ramstyle = "M10K" *) reg tile_dirty_0 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_1 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_2 [0:TILE_BRAM_DEPTH-1];
	(* ramstyle = "M10K" *) reg tile_dirty_3 [0:TILE_BRAM_DEPTH-1];

	// BRAM Read Ports (scanner reads ALL, output muxed by latched_clear_buf)
	reg scan_rd_0, scan_rd_1, scan_rd_2, scan_rd_3;
	always @(posedge clk_sys) scan_rd_0 <= tile_dirty_0[scan_offset];
	always @(posedge clk_sys) scan_rd_1 <= tile_dirty_1[scan_offset];
	always @(posedge clk_sys) scan_rd_2 <= tile_dirty_2[scan_offset];
	always @(posedge clk_sys) scan_rd_3 <= tile_dirty_3[scan_offset];

	wire tile_rd_data_raw = (latched_clear_buf == 2'd0) ? scan_rd_0 :
	                        (latched_clear_buf == 2'd1) ? scan_rd_1 :
	                        (latched_clear_buf == 2'd2) ? scan_rd_2 : scan_rd_3;

	reg        sweep_active = 0;
	reg [3:0]  swept_mask = 4'b0000;
	wire force_full_clear = (|FLASH_PARAM) || (sweep_active && !swept_mask[latched_clear_buf]);

	// Apply hit flash logic combinationally outside the RAM block to ensure M10K inference
	wire tile_rd_data = tile_rd_data_raw | force_full_clear;

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
	wire pipeline_idle = fifo_empty && !stage2_valid && !stage3_valid && !stall_pipeline;

	always @(posedge clk_sys) begin
		vbl_sync <= {vbl_sync[1:0], FB_VBL};

		if (!DDRAM_BUSY) begin
			ddram_we_reg <= 1'b0;
		end

		scan_restart <= 1'b0;
		scan_go <= 1'b0;
		scan_wr_req <= 1'b0;
		vbl_swap_req <= 1'b0;
		eof_swap_req <= 1'b0;

		if (rst_sys) begin
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
				buf_state[0] <= ST_DISPLAY;
				buf_state[1] <= ST_DIRTY;
				buf_state[2] <= ST_DIRTY;
				buf_state[3] <= ST_DIRTY;
				display_buf <= 2'd0;
				draw_buf <= 2'd1;
				draw_stall <= 1'b1;
				clearing <= 1'b0;
				clearing_tile <= 1'b0;
				clear_x <= 0;
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
				star_state <= 0;
				diag_state <= 0;
				ddram_we_reg <= 0;
				ddram_burst_reg <= 0;
				bram_init <= 1;
				bram_init_addr <= 0;
			end
		end else begin

			// VBLANK Swap Request
			if (vbl_edge) begin
				vbl_swap_req <= 1'b1;
			end

			if (bram_init) begin
				bram_init_addr <= bram_init_addr + 1'b1;
				if (bram_init_addr == TILE_BRAM_DEPTH - 1)
					bram_init <= 1'b0;
			end

			// DDRAM Bus Arbitration (Priority Chain)
			if (DDRAM_BUSY || bram_init) begin
				// Wait — DDRAM busy or BRAM still initializing

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
			end else if (stage3_valid && !force_clear) begin
				ddram_addr_reg  <= draw_base_word + stage3_addr;
				ddram_be_reg    <= stage3_be;
				ddram_din_reg   <= {stage3_val, stage3_val}; 
				ddram_burst_reg <= 8'd1;
				ddram_we_reg    <= 1'b1;

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
					if (sweep_active) swept_mask[clearing_idx] <= 1'b1;
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

			end else if (clear_pending && !clearing) begin
				clear_pending <= 1'b0;
				// FLUSH pipeline stages from the previous frame.
				stage2_valid <= 1'b0;
				stage3_valid <= 1'b0;
				star_state <= 0;
				diag_state <= 0;
			end

			// =============================================================
			if (!bram_init && !force_clear) begin
				// --- STAGE 2: DECODE TOKEN OR CALCULATE ADDRESS ---
				// Only advance stage3 if it was consumed or no write pending
				if ((!DDRAM_BUSY && !clearing_tile) || !stage3_valid) begin
					stage3_valid <= 1'b0;
					if (stall_pipeline) begin
						if (star_state != 0) begin
							logic [7:0]  l_z;
							logic [2:0]  l_c;
							logic [10:0] l_y;
							logic [10:0] l_x;
						
						// l_effect = latched_star_data[55:52]; // Unused
						l_z = latched_star_data[25:18];
						l_c = latched_star_data[50:48];
						l_y = latched_star_data[47:37];
						l_x = latched_star_data[36:26];
						
						// Compute offset based on star_state and STAR_PATTERN
						star_offset_x = l_x;
						star_offset_y = l_y;
						star_offset_z = (l_z > 8'd1) ? {1'b0, l_z[7:1]} : l_z;
						
						if (STAR_PATTERN == 3'd1) begin
							if (star_state == 1)      begin star_offset_x = l_x + 11'd1; star_offset_y = l_y; end
							else if (star_state == 2) begin star_offset_x = l_x;         star_offset_y = l_y + 11'd1; end
							else if (star_state == 3) begin star_offset_x = l_x + 11'd1; star_offset_y = l_y + 11'd1; end
							
							if (star_state == 3) begin star_state <= 0; end
							else star_state <= star_state + 1'b1;
						end else if (STAR_PATTERN == 3'd2) begin
							if (star_state == 1)      begin star_offset_x = l_x + 11'd1; star_offset_y = l_y; star_offset_z = (l_z > 8'd1) ? (l_z - (l_z >> 2)) : l_z; end
							else if (star_state == 2) begin star_offset_x = l_x - 11'd1; star_offset_y = l_y; star_offset_z = (l_z > 8'd1) ? (l_z - (l_z >> 2)) : l_z; end
							else if (star_state == 3) begin star_offset_x = l_x;         star_offset_y = l_y + 11'd1; end
							else if (star_state == 4) begin star_offset_x = l_x;         star_offset_y = l_y - 11'd1; end
							
							if (star_state == 4) begin star_state <= 0; end
							else star_state <= star_state + 1'b1;
						end else begin
							star_state <= 0;
						end
						
						if (star_offset_x < FB_WIDTH && star_offset_y < FB_HEIGHT && star_offset_z > 0) begin
							computed_pixel_addr = (FB_STRIDE == 14'd8192) ? 
							                      {star_offset_y, 11'd0} + {11'd0, star_offset_x} :
							                      {2'b00, star_offset_y[9:0], 10'd0} + {11'd0, star_offset_x};
							stage3_addr <= computed_pixel_addr[21:1];
							stage3_be   <= (computed_pixel_addr[0] == 1'b0) ? 8'h0F : 8'hF0;
							stage3_val  <= {8'd0, (l_c[0] ? star_offset_z : 8'd0), (l_c[1] ? star_offset_z : 8'd0), (l_c[2] ? star_offset_z : 8'd0)};
							stage3_tile_x <= star_offset_x[10:5];
							stage3_line_y <= star_offset_y[10:0];
							stage3_draw_buf <= draw_buf;
							stage3_valid <= 1'b1;
						end
						end else if (diag_state != 0) begin
							if (diag_corner_x < FB_WIDTH && diag_corner_y < FB_HEIGHT && diag_z > 0) begin
								computed_pixel_addr = (FB_STRIDE == 14'd8192) ? 
								                      {diag_corner_y, 11'd0} + {11'd0, diag_corner_x} :
								                      {2'b00, diag_corner_y[9:0], 10'd0} + {11'd0, diag_corner_x};
								stage3_addr <= computed_pixel_addr[21:1];
								stage3_be   <= (computed_pixel_addr[0] == 1'b0) ? 8'h0F : 8'hF0;
								stage3_val  <= {8'd0, (diag_c[0] ? diag_z : 8'd0), (diag_c[1] ? diag_z : 8'd0), (diag_c[2] ? diag_z : 8'd0)};
								stage3_tile_x <= diag_corner_x[10:5];
								stage3_line_y <= diag_corner_y[10:0];
								stage3_draw_buf <= draw_buf;
								stage3_valid <= 1'b1;
							end
							diag_state <= 0;
						end

					end else if (stage2_valid) begin
						if (pixel_frame_done) begin
							// RECEIVED EOF TOKEN!
							read_last_x <= 0;
							read_last_y <= 0;
							eof_swap_req <= 1'b1;
						end else begin
							if (pixel_x < FB_WIDTH && pixel_y < FB_HEIGHT) begin
								computed_pixel_addr = (FB_STRIDE == 14'd8192) ? 
								                      {pixel_y, 11'd0} + {11'd0, pixel_x} :
								                      {2'b00, pixel_y[9:0], 10'd0} + {11'd0, pixel_x};
								stage3_addr <= computed_pixel_addr[21:1];
								stage3_be   <= (computed_pixel_addr[0] == 1'b0) ? 8'h0F : 8'hF0;
								stage3_val  <= {8'd0, (pixel_c[0] ? pixel_z : 8'd0), (pixel_c[1] ? pixel_z : 8'd0), (pixel_c[2] ? pixel_z : 8'd0)};
								stage3_tile_x <= pixel_x[10:5];
								stage3_line_y <= pixel_y[10:0];
								stage3_draw_buf <= draw_buf;
								stage3_valid <= 1'b1;
							end
							
							if (pixel_is_dot && pixel_star_pattern != 3'd0 && pixel_star_pattern <= 3'd3) begin
								star_state <= 1;
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
						
						// Token has been successfully advanced down the pipeline,
						// so we clear its valid flag. If the FIFO fetches a new token 
						// on this exact cycle, it will correctly overwrite this 0 with a 1 below.
						stage2_valid <= 1'b0; 
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
				star_state <= 0;
				diag_state <= 0;
				
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