//============================================================================
//  Arcade: Star Wars — Game Hardware Module
//
//  Implements the original Atari Star Wars PCB: main 6809 CPU, audio 6809 CPU,
//  4× POKEY, RIOT, TMS5220 speech, Mathbox, AVG vector generator, ADC,
//  inter-CPU latches, and analog audio mixing/filtering.
//
//  Port to MiSTer FPGA by Videodr0me 2026
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
module starwars (
	input         clk_12,
	input         clk_50,
	input         clk_vid,  // Video pixel clock (always 109 MHz)
	input         reset,

	// OSD Settings
	input         osd_raster_flicker,
	input         osd_audio_filter,   // 1=On (TL084 LPF active), 0=Off (bypass)
	input         osd_audio_delay,    // 1=On (Reticon delay/stereo active), 0=Off (bypass)
	input         osd_120hz_mode,     // 1=120Hz (ce_pix always high), 0=60Hz (ce_pix toggles)
	
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

	// Audio (pseudo-stereo: dry ± wet from BBD delay)
	output [15:0] audio_out_l,
	output [15:0] audio_out_r,
	
	// Video timing (active pixel data goes through FB/DDRAM path)
	output [2:0]  video_r,  // Unused — zeroed
	output [2:0]  video_g,
	output [2:0]  video_b,
	output        hsync,    // Used for Video timing
	output        vsync,
	output        vblank,
	output        hblank,
	
	// Inputs
	input  [7:0]  dsw0,
	input  [7:0]  dsw1,
	input         coin1,
	input         coin2,
	input         aux_coin,
	input         fire_l,
	input         fire_r,
	input         shield_l,
	input         shield_r,
	input         test_mode,
	input  [7:0]  analog_x,
	input  [7:0]  analog_y,
	
	// LEDs
	output [2:0]  led,
	
	// ROM Download
	input [24:0]  dn_addr,
	input  [7:0]  dn_data,
	input         dn_wr,
	
	// NVRAM IOCTL
	output        nvram_write_pulse,
	input         nvram_wr_ext,
	input  [7:0]  nvram_addr_ext,
	input  [7:0]  nvram_din_ext,
	output reg [7:0]  nvram_dout_ext
);

	// CPU Main (6809)
	wire [15:0] main_addr;
	wire [7:0]  main_din;
	wire [7:0]  main_dout;
	wire        main_rw;
	wire        main_vma;
	reg         main_irq_reg;
	wire        main_irq;
	wire        main_firq;
	wire        main_nmi;
	assign      main_irq = main_irq_reg;
	assign      main_firq = 1'b0;
	assign      main_nmi = 1'b0;

	// ~246.09Hz Timer for Main IRQ
	// clk_12 is 12.096 MHz. Hardware divider is 4096 * 12 = 49152 cycles.
	// 12096000 / 49152 = 246.09375 Hz.
	reg [15:0] irq_timer;
	wire irq_ack = (main_addr >= 16'h4660 && main_addr <= 16'h467F) && !main_rw && main_vma;
	
	always @(posedge clk_12) begin
		if (reset) begin
			irq_timer <= 16'd0;
			main_irq_reg <= 1'b0;
		end else begin
			if (irq_timer >= 16'd49151) begin
				irq_timer <= 16'd0;
				main_irq_reg <= 1'b1; // Trigger IRQ
			end else begin
				irq_timer <= irq_timer + 16'd1;
			end
			
			if (irq_ack) begin
				main_irq_reg <= 1'b0; // Clear IRQ
			end
		end
	end

	// 1.5 MHz Clock Enable for CPUs
	reg [2:0] ce_div = 0;
	reg       ce_1m5 = 0;
	always @(posedge clk_12) begin
		if (reset) begin
			ce_div <= 0;
			ce_1m5 <= 0;
		end else begin
			ce_div <= ce_div + 3'd1;
			ce_1m5 <= (ce_div == 0);
		end
	end

	cpu09 main_cpu(
		.clk(clk_12),
		.ce(ce_1m5),
		.rst(reset),
		.rw(main_rw),
		.vma(main_vma),
		.addr(main_addr),
		.data_in(main_din),
		.data_out(main_dout),
		.halt(1'b0),
		.irq(main_irq),
		.firq(main_firq),
		.nmi(main_nmi)
	);

	// CPU Audio (6809)
	wire [15:0] aud_addr;
	wire [7:0]  aud_din;
	wire [7:0]  aud_dout;
	wire        aud_rw;
	wire        aud_vma;
	// Sound Reset and Latches clear (0x46E0)
	wire soundrst_we = (main_addr == 16'h46E0) && !main_rw && main_vma;
	
	reg [7:0] aud_rst_cnt;
	always @(posedge clk_12) begin
		if (reset) begin
			aud_rst_cnt <= 8'h0;
		end else if (soundrst_we) begin
			aud_rst_cnt <= 8'hFF;
		end else if (ce_1m5 && aud_rst_cnt > 0) begin
			aud_rst_cnt <= aud_rst_cnt - 8'd1;
		end
	end

	wire        aud_reset = reset | (aud_rst_cnt > 0); // Assert reset if global reset OR during extended software reset
	wire        aud_irq_n; // Driven by A6532 RIOT (Active Low)
	wire        aud_irq = ~aud_irq_n; // Invert for CPU09
	wire        aud_nmi = 1'b0; // No NMI on Audio CPU

	cpu09 audio_cpu(
		.clk(clk_12),
		.ce(ce_1m5),
		.rst(aud_reset),
		.rw(aud_rw),
		.vma(aud_vma),
		.addr(aud_addr),
		.data_in(aud_din),
		.data_out(aud_dout),
		.halt(1'b0),
		.irq(aud_irq),
		.firq(1'b0),
		.nmi(aud_nmi)
	);

	// --- ROM Download Address Decoding ---
	// MRA ROM layout (index 0), based on actual file sizes:
	//   0x00000-0x03FFF: Banked ROM (16KB: 136021.214.1f, two 8K bank pages)
	//   0x04000-0x0BFFF: Main ROM  (32KB: 4x 8KB files)
	//   0x0C000-0x0CFFF: Vector ROM (4KB: 136021-105.1l)
	//   0x0D000-0x10FFF: Audio ROM (16KB: 2x 8KB files)
	//   0x11000-0x110FF: AVG PROM  (256B, skipped — using hardcoded LUT)
	//   0x11100-0x120FF: Mathbox PROMs (4KB: 4x 1KB files)
	wire dn_banked_cs = dn_wr && (dn_addr < 25'h04000);
	wire dn_main_cs   = dn_wr && (dn_addr >= 25'h04000) && (dn_addr < 25'h0C000);
	wire dn_vec_cs    = dn_wr && (dn_addr >= 25'h0C000) && (dn_addr < 25'h0D000);
	wire dn_aud_cs    = dn_wr && (dn_addr >= 25'h0D000) && (dn_addr < 25'h11000);
	wire dn_mb_cs     = dn_wr && (dn_addr >= 25'h11100) && (dn_addr < 25'h12100);

	// Compute base-relative addresses for each ROM region
	wire [13:0] dn_banked_addr = dn_addr[13:0];                         // 0x0000 base, naturally aligned
	wire [14:0] dn_main_addr   = (dn_addr[14:0] - 15'h4000);             // 0x4000 base → 0x0000-0x7FFF
	wire [11:0] dn_vec_addr    = dn_addr[11:0];                          // 0xC000 base → low 12 bits
	wire [13:0] dn_aud_addr    = (dn_addr[13:0] - 14'h1000);             // 0xD000 base → 0x0000-0x3FFF
	wire [11:0] dn_mb_addr     = (dn_addr[11:0] - 12'h100);              // 0x11100 base → 0x000-0xFFF

	// Mathbox (Matrix Processor)
	wire math_run;
	wire [7:0] math_dout;
	
	mathbox mbox (
		.clk(clk_12),
		.ce(ce_1m5),
		.reset(reset),
		.prng_reset(~outlatch[5]),
		.cpu_addr(main_addr),
		.cpu_din(main_dout),
		.cpu_dout(math_dout),
		.cpu_rw(main_rw),
		.cpu_vma(main_vma),
		.math_run(math_run),
		// ROM Download (address offset from 0x11100 base)
		.dn_addr({13'd0, dn_mb_addr}),
		.dn_data(dn_data),
		.dn_wr(dn_mb_cs)
	);

	// ADC (Analog Controls) - MiSTer joystick to arcade pot mapping
	reg [7:0] adc_data;
	wire adc_start_0 = (main_addr == 16'h46C0) && !main_rw && main_vma; // Pitch (Y)
	wire adc_start_1 = (main_addr == 16'h46C1) && !main_rw && main_vma; // Yaw (X)
	
	// MiSTer joystick analog is signed -128..+127. 
	// Arcade expects 0x00..0xFF centered at 0x80.
	wire signed [8:0] analog_y_s = $signed(analog_y);
	wire signed [8:0] analog_x_s = $signed(analog_x);
	
	// Add offset to center (0x80 = 0)
	wire signed [8:0] digital_y_w = analog_y_s + 9'sd128;
	wire signed [8:0] digital_x_w = analog_x_s + 9'sd128;
	wire [7:0] digital_y = digital_y_w[7:0];
	wire [7:0] digital_x = digital_x_w[7:0];

	always @(posedge clk_12) begin
		if (adc_start_0) adc_data <= digital_y;
		else if (adc_start_1) adc_data <= digital_x;
	end

	wire adc_cs = (main_addr >= 16'h4380 && main_addr <= 16'h439F) && main_vma;

	// Outlatch (0x4680 - 0x4687)
	reg [7:0] outlatch;
	wire outlatch_we = (main_addr >= 16'h4680 && main_addr <= 16'h4687) && !main_rw && main_vma;
	always @(posedge clk_12) begin
		if (reset) outlatch <= 8'h00;
		else if (outlatch_we) outlatch[main_addr[2:0]] <= main_dout[7];
	end
	
	// Bank select is bit 4
	reg rom_bank;
	always @(*) rom_bank = outlatch[4];

	// =========================================================================
	// INTER-CPU COMMUNICATION LATCHES
	// =========================================================================

	reg [7:0] mainlatch;
	reg [7:0] soundlatch;
	reg       mainlatch_full;
	reg       soundlatch_full;

	// Main CPU writes to Soundlatch (0x4400)
	wire soundlatch_we = (main_addr == 16'h4400) && !main_rw && main_vma;
	
	// Audio CPU reads from Soundlatch (0x0800 - 0x0FFF)
	wire soundlatch_re = (aud_addr >= 16'h0800 && aud_addr <= 16'h0FFF) && aud_rw && aud_vma;

	// Audio CPU writes to Mainlatch (0x0000 - 0x07FF)
	wire mainlatch_we = (aud_addr >= 16'h0000 && aud_addr <= 16'h07FF) && !aud_rw && aud_vma;

	// Main CPU reads from Mainlatch (0x4400)
	wire mainlatch_re = (main_addr == 16'h4400) && main_rw && main_vma;

	always @(posedge clk_12) begin
		if (reset) begin
			mainlatch_full <= 1'b0;
			soundlatch_full <= 1'b0;
			mainlatch <= 8'h00;
			soundlatch <= 8'h00;
		end else if (ce_1m5 && soundrst_we) begin
			mainlatch_full <= 1'b0;
			soundlatch_full <= 1'b0;
		end else if (ce_1m5) begin
			if (soundlatch_we) begin
				soundlatch <= main_dout;
				soundlatch_full <= 1'b1;
			end else if (soundlatch_re) begin
				soundlatch_full <= 1'b0;
			end

			if (mainlatch_we) begin
				mainlatch <= aud_dout;
				mainlatch_full <= 1'b1;
			end else if (mainlatch_re) begin
				mainlatch_full <= 1'b0;
			end
		end
	end

	// =========================================================================
	// AVG DECLARATIONS
	// =========================================================================
	wire        avg_halted;
	wire        cpu_avg_halted;
	wire [10:0] avg_x;
	wire [10:0] avg_y;
	wire [7:0]  avg_z;
	wire [2:0]  avg_rgb;
	wire [15:0] avg_dbg;
	wire [15:0] avg_addr;
	wire  [7:0] avg_din;

	// =========================================================================
	// MEMORY SUBSYSTEM
	// =========================================================================

	// Main RAM (0x0000 - 0x2FFF, 12KB used, 16KB allocated)
	// Shared between Main CPU (Port A) and AVG (Port B)
	(* ramstyle = "M10K" *) reg [7:0] main_ram [0:16383];
	wire main_ram_cs = (main_addr < 16'h3000) && main_vma;
	reg [7:0] main_ram_dout;
	reg [7:0] avg_ram_dout;
	
	always @(posedge clk_12) begin
		if (main_ram_cs && ~main_rw) main_ram[main_addr[13:0]] <= main_dout;
		main_ram_dout <= main_ram[main_addr[13:0]];
		avg_ram_dout <= main_ram[avg_addr[13:0]];
	end

	// CPU Math RAM (2KB: 0x4800 - 0x4FFF)
	(* ramstyle = "M10K" *) reg [7:0] cpu_math_ram [0:2047];
	wire cpu_math_ram_cs = (main_addr >= 16'h4800 && main_addr <= 16'h4FFF) && main_vma;
	reg [7:0] cpu_math_ram_dout;
	
	always @(posedge clk_12) begin
		if (cpu_math_ram_cs && ~main_rw) cpu_math_ram[main_addr[10:0]] <= main_dout;
		cpu_math_ram_dout <= cpu_math_ram[main_addr[10:0]];
	end

	// Vector ROM (4KB: 0x3000 - 0x3FFF)
	wire [7:0] vec_rom_dout_cpu;
	wire [7:0] vec_rom_dout_avg;
	rom_download #(12) vec_rom (
		.clk(clk_12),
		.dn_addr(dn_vec_addr), .dn_data(dn_data), .dn_wr(dn_vec_cs),
		.cpu_addr_a(main_addr[11:0]), .cpu_dout_a(vec_rom_dout_cpu),
		.cpu_addr_b(avg_addr[11:0]),  .cpu_dout_b(vec_rom_dout_avg)
	);
	
	// Banked ROM (8KB window at 0x6000-0x7FFF, 2 × 8KB pages = 16KB total)
	wire [7:0] banked_rom_dout;
	rom_download #(14) banked_rom (
		.clk(clk_12),
		.dn_addr(dn_banked_addr), .dn_data(dn_data), .dn_wr(dn_banked_cs),
		.cpu_addr_a({rom_bank, main_addr[12:0]}), .cpu_dout_a(banked_rom_dout),
		.cpu_addr_b(14'h0), .cpu_dout_b() // Unused
	);

	// Main ROM (32KB: 0x8000 - 0xFFFF)
	wire [7:0] main_rom_dout;
	rom_download #(15) main_rom (
		.clk(clk_12),
		.dn_addr(dn_main_addr), .dn_data(dn_data), .dn_wr(dn_main_cs),
		.cpu_addr_a(main_addr[14:0]), .cpu_dout_a(main_rom_dout),
		.cpu_addr_b(15'h0), .cpu_dout_b() // Unused
	);

	// Audio ROM (16KB: 0x4000 - 0x7FFF, mirrored at 0xC000 - 0xFFFF)
	wire [7:0] aud_rom_dout;
	rom_download #(14) aud_rom (
		.clk(clk_12),
		.dn_addr(dn_aud_addr), .dn_data(dn_data), .dn_wr(dn_aud_cs),
		.cpu_addr_a(aud_addr[13:0]), .cpu_dout_a(aud_rom_dout),
		.cpu_addr_b(14'h0), .cpu_dout_b() // Unused
	);

	// Audio RAM (2KB: 0x2000 - 0x27FF)
	reg [7:0] aud_ram [0:2047];
	wire aud_ram_cs = (aud_addr >= 16'h2000 && aud_addr <= 16'h27FF) && aud_vma;
	reg [7:0] aud_ram_dout;
	
	always @(posedge clk_12) begin
		if (aud_ram_cs && ~aud_rw) aud_ram[aud_addr[10:0]] <= aud_dout;
		aud_ram_dout <= aud_ram[aud_addr[10:0]];
	end

	// NVRAM (256 bytes: 0x4500 - 0x45FF)
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] nvram [0:255];
	wire nvram_cs = (main_addr >= 16'h4500 && main_addr <= 16'h45FF) && main_vma;
	reg [7:0] nvram_dout;
	
	always @(posedge clk_12) begin
		if (nvram_cs && ~main_rw) nvram[main_addr[7:0]] <= main_dout;
		nvram_dout <= nvram[main_addr[7:0]];
	end

	always @(posedge clk_12) begin
		if (nvram_wr_ext) nvram[nvram_addr_ext] <= nvram_din_ext;
		nvram_dout_ext <= nvram[nvram_addr_ext];
	end

	reg old_nvram_wr;
	always @(posedge clk_12) old_nvram_wr <= (nvram_cs && ~main_rw);
	assign nvram_write_pulse = (nvram_cs && ~main_rw) & ~old_nvram_wr;

	// AVG Memory Mux
	assign avg_din = (avg_addr < 16'h3000) ? avg_ram_dout : vec_rom_dout_avg;

	// CPU Data In Mux
	reg [7:0] main_din_mux;
	always @(*) begin
		main_din_mux = 8'hFF;
		if (main_addr < 16'h3000) main_din_mux = main_ram_dout;
		else if (main_addr >= 16'h3000 && main_addr <= 16'h3FFF) main_din_mux = vec_rom_dout_cpu;
		else if (main_addr >= 16'h4700 && main_addr <= 16'h4707) main_din_mux = math_dout;
		else if (main_addr >= 16'h4500 && main_addr <= 16'h45FF) main_din_mux = nvram_dout;
		else if (main_addr >= 16'h4800 && main_addr <= 16'h4FFF) main_din_mux = cpu_math_ram_dout;
		else if (main_addr >= 16'h5000 && main_addr <= 16'h5FFF) main_din_mux = math_dout;
		else if (main_addr >= 16'h6000 && main_addr <= 16'h7FFF) main_din_mux = banked_rom_dout;
		else if (main_addr >= 16'h8000) main_din_mux = main_rom_dout;
		else if (adc_cs) main_din_mux = adc_data;
		
		// Communication
		else if (main_addr == 16'h4400) main_din_mux = mainlatch;
		else if (main_addr == 16'h4401) main_din_mux = {soundlatch_full, mainlatch_full, 6'h00};
		
		// Input ports (active-low, accent bits per original schematics)
		// IN0: D7=L.Fire D6=R.Fire D5=Spare(1) D4=SelfTest D3=Slam(1) D2=AuxCoin D1=CoinL D0=CoinR
		else if (main_addr >= 16'h4300 && main_addr <= 16'h431F) main_din_mux = {~fire_l, ~fire_r, 1'b1, ~test_mode, 1'b1, ~aux_coin, ~coin1, ~coin2}; // IN0
		// IN1: D7=MathRun D6=VGHalt D5=L.Shield D4=R.Shield D3=Spare(1) D2=Diag(1) D1,D0=unused(1)
		else if (main_addr >= 16'h4320 && main_addr <= 16'h433F) main_din_mux = {math_run, avg_halted, ~shield_l, ~shield_r, 1'b1, 1'b1, 1'b1, 1'b1}; // IN1
		else if (main_addr >= 16'h4340 && main_addr <= 16'h435F) main_din_mux = dsw0; // DSW0
		else if (main_addr >= 16'h4360 && main_addr <= 16'h437F) main_din_mux = dsw1; // DSW1
	end
	assign main_din = main_din_mux;

	// AVG (Analog Vector Generator)
	wire avg_go = (main_addr >= 16'h4600 && main_addr <= 16'h461F) && !main_rw && main_vma;
	wire avg_rst_cmd = (main_addr >= 16'h4620 && main_addr <= 16'h463F) && !main_rw && main_vma;

	wire [15:0] avg_dn_addr = dn_addr[15:0];
	avg vector_generator (
		.clk(clk_12),
		.clken(ce_1m5),
		
		// CPU Interface (Internal registers / GO / RST)
		.cpu_addr(main_addr[13:0]),
		.cpu_cs_l(1'b1), // CPU does not read AVG internal RAM anymore
		.cpu_rw_l(main_rw),
		.cpu_data_in(),
		.cpu_data_out(main_dout),
		
		.vgrst(reset | avg_rst_cmd),
		.vggo(avg_go),
		.halted(avg_halted),
		
		// External Memory for Vector Instructions
		.avg_addr_out(avg_addr),
		.avg_data_in(avg_din),
		
		// Vector Outputs
		.xout(avg_x),
		.yout(avg_y),
		.zout(avg_z),
		.rgbout(avg_rgb),
		
		.dbg(avg_dbg),
		.dn_addr(avg_dn_addr),
		.dn_data(dn_data),
		.dn_wr(dn_wr)
	);

	// Audio Chips (POKEY x4)
	wire [7:0] pokey0_dout, pokey1_dout, pokey2_dout, pokey3_dout;
	wire [7:0] pokey0_out, pokey1_out, pokey2_out, pokey3_out;
	
	// Star Wars POKEY interleaved mapping (0x1800 - 0x183F)
	wire [1:0] pokey_num = aud_addr[4:3];
	wire [3:0] pokey_reg = {aud_addr[5], aud_addr[2:0]};
	wire pokey_area = (aud_addr >= 16'h1800 && aud_addr <= 16'h183F) && aud_vma;
	
	wire pokey0_cs = pokey_area && (pokey_num == 2'd0);
	wire pokey1_cs = pokey_area && (pokey_num == 2'd1);
	wire pokey2_cs = pokey_area && (pokey_num == 2'd2);
	wire pokey3_cs = pokey_area && (pokey_num == 2'd3);
	
	// POKEY 0
	POKEY pokey0 (
		.CLK(clk_12),
		.ENA(ce_1m5),
		.ADDR(pokey_reg),
		.DIN(aud_dout),
		.RW_L(aud_rw),
		.CS(pokey0_cs),
		.CS_L(~pokey0_cs),
		.PIN(8'hFF),
		.DOUT(pokey0_dout),
		.DOUT_OE_L(),
		.AUDIO_OUT(pokey0_out)
	);

	// POKEY 1
	POKEY pokey1 (
		.CLK(clk_12),
		.ENA(ce_1m5), 
		.ADDR(pokey_reg),
		.DIN(aud_dout),
		.RW_L(aud_rw),
		.CS(pokey1_cs),
		.CS_L(~pokey1_cs),
		.PIN(8'hFF),
		.DOUT(pokey1_dout),
		.DOUT_OE_L(),
		.AUDIO_OUT(pokey1_out)
	);

	// POKEY 2
	POKEY pokey2 (
		.CLK(clk_12),
		.ENA(ce_1m5),
		.ADDR(pokey_reg),
		.DIN(aud_dout),
		.RW_L(aud_rw),
		.CS(pokey2_cs),
		.CS_L(~pokey2_cs),
		.PIN(8'hFF),
		.DOUT(pokey2_dout),
		.DOUT_OE_L(),
		.AUDIO_OUT(pokey2_out)
	);

	// POKEY 3
	POKEY pokey3 (
		.CLK(clk_12),
		.ENA(ce_1m5),
		.ADDR(pokey_reg),
		.DIN(aud_dout),
		.RW_L(aud_rw),
		.CS(pokey3_cs),
		.CS_L(~pokey3_cs),
		.PIN(8'hFF),
		.DOUT(pokey3_dout),
		.DOUT_OE_L(),
		.AUDIO_OUT(pokey3_out)
	);

	// RIOT (MOS 6532) for TMS5220
	wire [7:0] riot_d_out;
	wire [7:0] riot_pa_out;
	wire [7:0] riot_pb_out;
	wire [7:0] riot_pa_in;
	wire [7:0] riot_pb_in;
	wire riot_cs = (aud_addr >= 16'h1000 && aud_addr <= 16'h109F) && aud_vma;
	wire riot_rs = (aud_addr >= 16'h1080); // 1 = IO, 0 = RAM

	A6532 riot (
		.clk(clk_12),
		.ph2_en(ce_1m5),
		.r(aud_rw),
		.rs(riot_rs),
		.cs(riot_cs),
		.irq(aud_irq_n),
		.d_in(aud_dout),
		.d_out(riot_d_out),
		.pa_in(riot_pa_in),
		.pa_out(riot_pa_out),
		.pb_in(riot_pb_in),
		.pb_out(riot_pb_out),
		.pa7(soundlatch_full),
		.a(aud_addr[6:0])
	);

	// TMS5220 Speech
	wire tms_ready_n;
	wire [7:0] tms_data_out;
	wire signed [13:0] tms_audio;

	assign riot_pa_in = {soundlatch_full, mainlatch_full, 3'b111, tms_ready_n, 2'b00}; // PA7=soundlatch_full, PA6=mainlatch_full, PA2=tms_ready_n
	assign riot_pb_in = tms_data_out; // Direct connect from TMS O_DBUS

	// TMS Clock Generation (~672kHz pulse)
	reg [4:0] tms_clk_div;
	reg tms_ena;
	always @(posedge clk_12) begin
		tms_ena <= 1'b0; // Default low
		if (tms_clk_div == 5'd17) begin
			tms_clk_div <= 5'd0;
			tms_ena <= 1'b1; // Pulse high for 1 cycle
		end else begin
			tms_clk_div <= tms_clk_div + 5'd1;
		end
	end

	TMS5220 tms (
		.I_OSC(clk_12),
		.I_ENA(tms_ena),
		.I_WSn(riot_pa_out[0]),
		.I_RSn(riot_pa_out[1]),
		.I_DATA(1'b0),
		.I_TEST(1'b0),
		.I_DBUS(riot_pb_out),
		.O_DBUS(tms_data_out),
		.O_RDYn(tms_ready_n),
		.O_INTn(),
		.O_SPKR(tms_audio)
	);

	// CPU Audio Data In Mux
	reg [7:0] aud_din_mux;
	always @(*) begin
		aud_din_mux = 8'hFF;
		if (pokey0_cs) aud_din_mux = pokey0_dout;
		else if (pokey1_cs) aud_din_mux = pokey1_dout;
		else if (pokey2_cs) aud_din_mux = pokey2_dout;
		else if (pokey3_cs) aud_din_mux = pokey3_dout;
		else if (riot_cs) aud_din_mux = riot_d_out;
		else if (aud_addr >= 16'h2000 && aud_addr <= 16'h27FF) aud_din_mux = aud_ram_dout;
		else if (aud_addr >= 16'h4000 && aud_addr <= 16'h7FFF) aud_din_mux = aud_rom_dout;
		else if (aud_addr >= 16'hB000) aud_din_mux = aud_rom_dout; // Mirrored
		else if (aud_addr >= 16'h0800 && aud_addr <= 16'h0FFF) aud_din_mux = soundlatch;
	end
	assign aud_din = aud_din_mux;

	// =========================================================================
	// AUDIO MIXING (Based on original Atari schematic SP-225 Sheet 16A/16B)
	// =========================================================================
	// Summing Amplifier: TL084 (1/4 4C), Feedback R30 = 12K
	// POKEY 0, 1 (CO0, CO1): R21, R23 = 47K -> Gain = 12/47 = 0.255
	// POKEY 2, 3 (CO2, CO3): R25, R27 = 82K -> Gain = 12/82 = 0.146
	// TMS5220 (SPEECH):      R29 = 15K      -> Gain = 12/15 = 0.800
	//
	// POKEY buffers are transimpedance amps (CO current -> voltage via
	// R20/R22/R24/R26 = 1000 ohm feedback). TMS5220 SPEECH is AC-coupled
	// (C41=0.1uF, R28=100K bias) through a TL084 buffer stage.
	// TMS SPKR output via R17=10K/R18=1800 produces estimated ~1.0-1.5 Vpp.
	// Exact voltage depends on DAC current range; 5.3:1 ratio chosen as
	// perceptual midpoint between pure resistor ratio (3.1:1) and full
	// voltage-corrected estimate (8.0:1).
	//
	// All weights use shift-and-add:
	//   POKEY 0,1: x24 = (<<4) + (<<3)   [47K channels]
	//   POKEY 2,3: x14 = (<<4) - (<<1)   [82K channels]
	//   TMS5220:   x2  = (<<1)            [15K channel]
	//
	// Ratio check: TMS/P01 = (8191*2)/(128*24) = 5.3:1
	//              Pure resistor ratio = (12/15)/(12/47) = 47/15 = 3.1:1
	//              5.3:1 accounts for slightly higher TMS output voltage
	//              P23/P01 = 14/24 = 0.583  (schematic: 12/82 / 12/47 = 0.573)

	// 1. Convert POKEYs to signed (remove DC offset)
	wire signed [8:0] p0_s = $signed({1'b0, pokey0_out}) - 9'sd128;
	wire signed [8:0] p1_s = $signed({1'b0, pokey1_out}) - 9'sd128;
	wire signed [8:0] p2_s = $signed({1'b0, pokey2_out}) - 9'sd128;
	wire signed [8:0] p3_s = $signed({1'b0, pokey3_out}) - 9'sd128;

	// 2. Pair sums
	wire signed [9:0] pair_p01 = p0_s + p1_s;
	wire signed [9:0] pair_p23 = p2_s + p3_s;

	// 3. Apply weights using shift-and-add
	// POKEY 0,1: x24 = (<<4) + (<<3)
	wire signed [16:0] mix_p01 = ({{3{pair_p01[9]}}, pair_p01, 4'b0})    // <<4
	                            + ({{4{pair_p01[9]}}, pair_p01, 3'b0});   // <<3

	// POKEY 2,3: x14 = (<<4) - (<<1)
	wire signed [16:0] mix_p23 = ({{3{pair_p23[9]}}, pair_p23, 4'b0})    // <<4
	                            - ({{6{pair_p23[9]}}, pair_p23, 1'b0});   // <<1

	// TMS5220: x2 = (<<1)
	wire signed [16:0] tms_ext = {{3{tms_audio[13]}}, tms_audio};
	wire signed [16:0] mix_tms = tms_ext <<< 1;                           // x2

	// 4. Raw mix (17-bit signed, max ~26110, fits within 16-bit mostly)
	wire signed [16:0] raw_mix = mix_p01 + mix_p23 + mix_tms;

	// =========================================================================
	// AUDIO PROCESSING (Sheet 16B: Filter + Reticon R5106 Delay/Stereo)
	// =========================================================================

	// --- 48 kHz clock enable from 12 MHz (divide by 250) ---
	reg [7:0] aud_div;
	reg       ce_48k;
	always @(posedge clk_12) begin
		ce_48k <= 1'b0;
		if (aud_div == 8'd249) begin
			aud_div <= 8'd0;
			ce_48k  <= 1'b1;
		end else begin
			aud_div <= aud_div + 8'd1;
		end
	end

	// --- TL084 MFB Low-Pass Filter (~4.9 kHz) ---
	wire signed [16:0] filtered_mix;
	audio_filter_tl084 pcb_filter (
		.clk(clk_12),
		.reset(reset),
		.ce(ce_48k),
		.enable(osd_audio_filter),
		.audio_in(raw_mix),
		.audio_out(filtered_mix)
	);

	// --- Reticon R5106 Delay (13.5 ms) — Pseudo-Stereo ---
	// The original PCB routes the delayed signal to stereo summing amps
	// (Sheet 16B, fig 2) alongside the dry signal. My interpretation:
	// Left = dry + wet, Right = dry − wet (“synthesized stereo” per SWSIG.DOC).
	wire signed [16:0] final_mix_l;
	wire signed [16:0] delay_wet;
	reticon_r5106 pcb_delay (
		.clk(clk_12),
		.reset(reset),
		.ce(ce_48k),
		.enable(osd_audio_delay),
		.audio_in(filtered_mix),
		.audio_out(final_mix_l),
		.audio_wet(delay_wet)
	);

	// Right channel: dry − wet
	wire signed [16:0] final_mix_r = filtered_mix - delay_wet;

	// =========================================================================
	// AUDIO OUTPUT (16-bit signed, saturating clip, stereo)
	// =========================================================================
	reg signed [15:0] audio_out_l_reg;
	reg signed [15:0] audio_out_r_reg;
	always @(posedge clk_12) begin
		if (ce_48k) begin
			// Left channel (dry + wet)
			if (final_mix_l > 17'sd32767)
				audio_out_l_reg <= 16'sd32767;
			else if (final_mix_l < -17'sd32768)
				audio_out_l_reg <= 16'h8000;
			else
				audio_out_l_reg <= final_mix_l[15:0];

			// Right channel (dry − wet)
			if (final_mix_r > 17'sd32767)
				audio_out_r_reg <= 16'sd32767;
			else if (final_mix_r < -17'sd32768)
				audio_out_r_reg <= 16'h8000;
			else
				audio_out_r_reg <= final_mix_r[15:0];
		end
	end
	assign audio_out_l = audio_out_l_reg;
	assign audio_out_r = audio_out_r_reg;

	// Boost Z-intensity by 3x to compensate for 1-pixel line width
	wire [9:0] boosted_z = (avg_z << 1) + avg_z;

	// Clamp to 5-bit (0-31) for palette Z-level
	wire [4:0] final_z = (boosted_z > 10'd255) ? 5'd31 : boosted_z[7:3];
	
	// =========================================================================
	// Aspect-Correct Coordinate Scaling (980 × 700 framebuffer)
	// =========================================================================
	// AVG outputs 11-bit signed values (half-pixel precision).
	// Game content spans ±560 half-pixels (= ±280 integer pixels = 2× DAC range).
	// Original arcade CRT is 250 (X) × 280 (Y), portrait orientation.
	// Y scale: ×1.25 = val + val/4        → ±700 half-pixels → ±350 pixels
	// X scale: ×1.75 = val*2 - val/4      → ±980 half-pixels → ±490 pixels
	// X/Y ratio = 1.75/1.25 = 1.4 = 280/200, restoring the 14:10 aspect ratio.
	
	// Sign-extend 11-bit AVG outputs for arithmetic
	wire signed [11:0] avg_x_ext = {{1{avg_x[10]}}, avg_x};
	wire signed [11:0] avg_y_ext = {{1{avg_y[10]}}, avg_y};
	
	// Y × 1.25 = val + val/4  (result: ±700 half-pixels, 12 bits)
	wire signed [11:0] y_scaled = avg_y_ext + {{2{avg_y_ext[11]}}, avg_y_ext[11:2]};
	
	// X × 1.75 = val×2 - val/4  (result: ±980 half-pixels, 12 bits)
	wire signed [11:0] x_scaled = {avg_x_ext[10:0], 1'b0} - {{2{avg_x_ext[11]}}, avg_x_ext[11:2]};
	
	// Convert half-pixels to pixels (arithmetic right shift by 1)
	wire signed [10:0] y_pixel = y_scaled[11:1];  // ±350
	wire signed [10:0] x_pixel = x_scaled[11:1];  // ±490
	
	// Center in framebuffer and invert Y
	wire signed [11:0] new_x = {x_pixel[10], x_pixel} + 12'sd490;
	wire signed [11:0] new_y = 12'sd349 - {y_pixel[10], y_pixel};  // Inverted Y

	// Do not clamp the coordinates. If clamped, off-screen lines "slide" along the border.
	// Instead, pass the raw truncated bits, but turn the beam OFF if the signed value is out of bounds.
	wire [9:0] final_x = new_x[9:0];
	wire [9:0] final_y = new_y[9:0];

	wire beam_in_bounds = (new_x >= 0 && new_x < 980) && (new_y >= 0 && new_y < 700);

	// Vector to Raster Conversion
	wire fifo_full_led;
	vector_fb_ddram rasterizer (
		.reset(reset),
		.clk_sys(clk_50),
		.clk_12(clk_12),

		.X_VECTOR(final_x),
		.Y_VECTOR(final_y),
		.Z_VECTOR(final_z),
		.RGB(avg_rgb),
		.BEAM_ENA(1'b1),
		.BEAM_ON(|avg_z && beam_in_bounds),
		
		.START_FRAME(avg_go),
		.FRAME_DONE(avg_halted),
		.OSD_FLICKER(osd_raster_flicker),
		.FIFO_FULL_LED(fifo_full_led),

		.DDRAM_CLK(DDRAM_CLK),
		.DDRAM_BUSY(DDRAM_BUSY),
		.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
		.DDRAM_ADDR(DDRAM_ADDR),
		.DDRAM_DOUT(DDRAM_DOUT),
		.DDRAM_DOUT_READY(DDRAM_DOUT_READY),
		.DDRAM_RD(DDRAM_RD),
		.DDRAM_DIN(DDRAM_DIN),
		.DDRAM_BE(DDRAM_BE),
		.DDRAM_WE(DDRAM_WE),

		.FB_EN(FB_EN),
		.FB_FORMAT(FB_FORMAT),
		.FB_WIDTH(FB_WIDTH),
		.FB_HEIGHT(FB_HEIGHT),
		.FB_BASE(FB_BASE),
		.FB_STRIDE(FB_STRIDE),
		.FB_VBL(FB_VBL),
		.FB_LL(FB_LL),
		.FB_FORCE_BLANK(FB_FORCE_BLANK),
		.FB_PAL_CLK(FB_PAL_CLK),
		.FB_PAL_ADDR(FB_PAL_ADDR),
		.FB_PAL_DOUT(FB_PAL_DOUT),
		.FB_PAL_DIN(FB_PAL_DIN),
		.FB_PAL_WR(FB_PAL_WR)
	);

	assign video_r = 3'b000;
	assign video_g = 3'b000;
	assign video_b = 3'b000;

	// Video timing generator
	// clk_vid is always 109 MHz (PLL outclk_3).
	// ce_pix toggles for 60Hz (~54.5 MHz effective) or stays high for 120Hz.
	// Both modes use identical timing: 1056 × 861.
	//   60Hz:  1056 × 861 @ 54.545 MHz = 59.98 Hz
	//   120Hz: 1056 × 861 @ 109.09 MHz = 119.96 Hz
	reg ce_pix;
	always @(posedge clk_vid) begin
		if (osd_120hz_mode)
			ce_pix <= 1'b1;       // Full 109 MHz → 120Hz
		else
			ce_pix <= ~ce_pix;    // ~54.5 MHz → 60Hz
	end

	reg [10:0] h_cnt = 0;
	reg [10:0] v_cnt = 0;

	// Timing parameters — identical for both modes
	wire [10:0] h_total  = 11'd1055;
	wire [10:0] v_total  = 11'd860;
	wire [10:0] hs_start = 11'd1004;
	wire [10:0] hs_end   = 11'd1036;
	wire [10:0] vs_start = 11'd703;
	wire [10:0] vs_end   = 11'd709;

	wire h_end = (h_cnt == h_total);
	wire v_end = (v_cnt == v_total);

	always @(posedge clk_vid) begin
		if (ce_pix) begin
			if (h_end) begin
				h_cnt <= 0;
				if (v_end) v_cnt <= 0;
				else v_cnt <= v_cnt + 1'd1;
			end else begin
				h_cnt <= h_cnt + 1'd1;
			end
		end
	end

	assign hsync  = ~(h_cnt >= hs_start && h_cnt < hs_end); // Active low
	assign vsync  = ~(v_cnt >= vs_start && v_cnt < vs_end);  // Active low
	assign hblank = (h_cnt >= 11'd980);
	assign vblank = (v_cnt >= 11'd700);
	

	assign led = {~outlatch[6], ~outlatch[3], (~outlatch[2]) | fifo_full_led};

endmodule