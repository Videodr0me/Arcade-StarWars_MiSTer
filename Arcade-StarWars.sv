//============================================================================
//  Arcade: Star Wars
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

module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
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

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* signals to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;

assign VGA_F1    = 0;
assign VGA_SCALER= 1;
assign VGA_DISABLE = 0;
assign VGA_SL = 0;
assign USER_OUT  = '1;
wire [2:0] core_led;
assign LED_USER  = core_led[2] | ioctl_download;
assign LED_DISK  = 2'b00;
assign LED_POWER = 2'b00;
assign BUTTONS   = 0;
assign AUDIO_MIX = 0;
assign HDMI_FREEZE = 0;

assign CLK_VIDEO = clk_108; // Direct PLL output (107.14 MHz)
assign VGA_HS = hs;
assign VGA_VS = vs;
assign VGA_DE = ~(hblank | vblank);
assign VGA_R = 0;
assign VGA_G = 0;
assign VGA_B = 0;

wire [1:0] ar = status[15:14];

// Auto-detect optimal aspect ratio from HDMI output resolution.
// Match the internal framebuffer size to ensure exactly 4:3 or 1.4:1 scaling.
reg [12:0] auto_arx, auto_ary;
always @(*) begin
	if (HDMI_HEIGHT >= 1050) begin
		// 1080p Mode (1472x1050 Framebuffer)
		auto_arx = 13'h1000 | 13'd1472;
		auto_ary = 13'h1000 | 13'd1050;
	end else if (HDMI_HEIGHT >= 700) begin
		// 720p Mode (980x700 Framebuffer)
		auto_arx = 13'h1000 | 13'd980;
		auto_ary = 13'h1000 | 13'd700;
	end else if (HDMI_HEIGHT >= 400) begin
		// 480p Mode (640x480 Framebuffer) - Integer Scale (1:1)
		auto_arx = 13'h1000 | 13'd640;
		auto_ary = 13'h1000 | 13'd480;
	end else begin
		// 240p (15kHz) Mode (640x240 Framebuffer) - Integer Scale (1:1)
		auto_arx = 13'h1000 | 13'd640;
		auto_ary = 13'h1000 | 13'd240;
	end
end

assign VIDEO_ARX = (ar == 0) ? auto_arx :  // Optimized (auto-detect)
                   (ar == 1) ? 13'd0 :     // Stretched
                               auto_arx;   // Pixel Perfect (1:1)

assign VIDEO_ARY = (ar == 0) ? auto_ary :  // Optimized (auto-detect)
                   (ar == 1) ? 13'd0 :     // Stretched
                               auto_ary;   // Pixel Perfect (1:1)

// 120Hz MODE — SAFE ACTIVATION
// The HPS restores saved status bits (including status[25]=120Hz ON)
// during boot, BEFORE HDMI_HEIGHT is valid during initialization -> HDMI sync loss.

// --- Stage 1: Boot holdoff (~1.3 seconds after FPGA config) ---
// Core ALWAYS starts outputting 60Hz timing regardless of saved settings.
reg [26:0] boot_cnt = 0;
reg boot_done = 0;
always @(posedge clk_50) begin
	if (!boot_cnt[26])
		boot_cnt <= boot_cnt + 1'd1;
	else
		boot_done <= 1;
end

// --- Stage 2: HDMI_HEIGHT validation
// Require height to be in a valid range (600-720) and stable for ~335ms.
wire is_720p_valid = (HDMI_HEIGHT >= 12'd600) & (HDMI_HEIGHT <= 12'd720);
reg [24:0] stable_720p_cnt = 0;
reg is_720p_stable = 0;
always @(posedge clk_50) begin
	if (!is_720p_valid) begin
		stable_720p_cnt <= 0;
		is_720p_stable <= 0;
	end else if (!stable_720p_cnt[24]) begin
		stable_720p_cnt <= stable_720p_cnt + 1'd1;
	end else begin
		is_720p_stable <= 1;
	end
end

// --- Stage 3: 120Hz mode signal
// If boot holdoff expired, user wants 120Hz, and HDMI_HEIGHT has been stable.
wire osd_120hz_mode = boot_done & status[25] & is_720p_stable;
wire not_720p = ~is_720p_stable;

// --- Video mode change notification ---
reg new_vmode_toggle = 0;
reg mode_120_prev = 0;
reg boot_done_prev = 0;
always @(posedge clk_50) begin
	boot_done_prev <= boot_done;

	if (!boot_done) begin
		// During boot: silently track status[25] without firing vmode
		mode_120_prev <= status[25];
	end else begin
		// After boot: fire vmode on user OSD toggle
		mode_120_prev <= status[25];
		if (mode_120_prev != status[25])
			new_vmode_toggle <= ~new_vmode_toggle;
	end

	// Fire once when boot holdoff expires and 120Hz is activating
	if (boot_done & !boot_done_prev & osd_120hz_mode)
		new_vmode_toggle <= ~new_vmode_toggle;
end

// Status Bit Map:
//             Upper                             Lower              
// 0         1         2         3          4         5         6   
// 01234567890123456789012345678901 23456789012345678901234567890123
// 0123456789ABCDEFGHIJKLMNOPQRSTUV 0123456789ABCDEFGHIJKLMNOPQRSTUV
// XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX XXXXX                           
`include "build_id.v" 
localparam CONF_STR = {
	"Star Wars;;",
	"-;",
	"P3,Video Options;",
	"P3-;",
	"P3OEF,Aspect ratio,Optimized,Stretched,Pixel Perfect;",
	"D3P3OP,120Hz (720p only),Off,On;",
	"P3O2,Unbuffered Vectors,Off,On;",
	"P3-;",
	"P3OSTU,CRT Dot Bloom,Auto,Pixel,Double,Elipse;",
	"P3OQ,CRT Hit Flash,On,Off;",
	"P3OV,Tone Mapping,Legacy (SDR),Modern (HDR);",
	 "-;",
	"P2,Cabinet Audio Hardware;",
	"P2-;",
	"P2O5,TL 084 Filter,On,Off;",
	"P2O6,Reticon Del/Rev,On,Off;",
	"-;",
	"P4,Input Controls;",
	"P4o01,Input,Analog,Digital,Auto;",
	"D4P4o23,Digital Sensitivity,Medium,Low,High,Max;",
	"P4-;",
	"P4o4,Y-Axis,Normal,Inverted;",
	"-;",
	"P1,DIP Settings;",
	"P1-,* Change setup via Testmode;",
	"P1-,* in Demo Loop - not DIPs!;",
	"P1O1,Test Mode,Off,On;",
	"P1-;",
	// Star Wars DIPs
	"h1P1O78,Starting Shields,8,9,6,7;",
	"h1P1O9A,Difficulty,Moderate,Hard,Hardest,Easy;",
	"h1P1OBC,Bonus Shields,1,2,3,0;",
	"h1P1OD,Demo Sounds,On,Off;",
	"h1P1OHI,Coinage,1 Play/Coin,2 Coins/Play,Free Play,2 Plays/Coin;",
	"h1P1OJK,Right Coin,x1,x4,x5,x6;",
	"h1P1OL,Left Coin,x1,x2;",
	"h1P1OMNO,Bonus Coin Adder,None,2 gives 1,4 gives 1,4 gives 2,5 gives 1,3 gives 1;",
	"h1P1OG,Freeze,Off,On;",
	// Empire Strikes Back DIPs
	"h2P1O78,Starting Shields,4,5,2,3;",
	"h2P1O9A,Difficulty,Hard,Hardest,Easy,Moderate;",
	"h2P1OBC,JEDI Letter Mode,Increment,Level,Inc. Only,Level Only;",
	"h2P1OD,Demo Sounds,On,Off;",
	"h2P1OHI,Coinage,1 Play/Coin,2 Coins/Play,Free Play,2 Plays/Coin;",
	"h2P1OJK,Right Coin,x1,x4,x5,x6;",
	"h2P1OL,Left Coin,x1,x2;",
	"h2P1OMNO,Bonus Coin Adder,None,2 gives 1,4 gives 1,4 gives 2,5 gives 1,3 gives 1;",
	"h2P1OG,Freeze,Off,On;",
	"P1-;",
	"P1-,* DIPs need Clear & Reset !;",
	"P1T3,Clear NVRAM;",
	"-;",
	"OR,Autosave NVRAM,Off,On;",
	"T4,Save NVRAM;",
	"-;",
	"R0,Reset;",
	"J1,Fire L,Shield L,Aux Coin,Coin L,Coin R,Fire R,Shield R;",
	"jn,A,B,Start,R,L,Y,Z;",
	"V,v1.02.",`BUILD_DATE
};

////////////////////   CLOCKS   ///////////////////

wire clk_6, clk_12, clk_50, clk_108;
wire pll_locked;

pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_50),
	.outclk_1(clk_12),
	.outclk_2(clk_6),
	.outclk_3(clk_108),
	.locked(pll_locked)
);


///////////////////////////////////////////////////

wire [63:0] status;
wire  [1:0] buttons;
wire        forced_scandoubler;
wire        direct_video;

wire [21:0] gamma_bus;

wire        ioctl_download;
wire        ioctl_upload;
wire        ioctl_upload_req;
wire        ioctl_wr;
wire        ioctl_rd;
wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_din;
wire  [7:0] ioctl_index;

wire [15:0] joy_0, joy_1;
wire [15:0] joy = joy_0 | joy_1;
wire [15:0] joy_l_analog_0;
wire        rom_download = ioctl_download && !ioctl_index;
wire        nvram_download = ioctl_download && (ioctl_index == 8'd4);
wire [24:0] dl_addr = ioctl_addr;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_12),
	.HPS_BUS(HPS_BUS),

	.buttons(buttons),
	.status(status),
	.status_menumask({is_analog_input, not_720p, mod_esb, mod_starwars, direct_video}),
	.forced_scandoubler(forced_scandoubler),
	.gamma_bus(gamma_bus),
	.direct_video(direct_video),
	.new_vmode(new_vmode_toggle),

	.ioctl_download(ioctl_download),
	.ioctl_upload(ioctl_upload),
	.ioctl_upload_req(ioctl_upload_req),
	.ioctl_upload_index(8'd4),
	.ioctl_wr(ioctl_wr),
	.ioctl_rd(ioctl_rd),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_din(ioctl_din),
	.ioctl_index(ioctl_index),

	.joystick_0(joy_0),
	.joystick_1(joy_1),
	.joystick_l_analog_0(joy_l_analog_0)
);

// DIP switch loading — currently unused (game settings via Test Mode / NVRAM)
// reg [7:0] sw[8];
// always @(posedge clk_12) if (ioctl_wr && (ioctl_index==254) && !ioctl_addr[24:3]) sw[ioctl_addr[2:0]] <= ioctl_dout;

wire m_fire_l   = joy[4];          // Left fire (Button A)
wire m_fire_r   = joy[9];          // Right fire (Button Y)
wire m_shield_l = joy[5];          // Left shield/thumb (Button B)
wire m_shield_r = joy[10];         // Right shield/thumb (Button Z)
wire m_auxcoin  = joy[6];          // Aux coin / self-test advance
wire m_coin     = joy[7];
wire m_coin2    = joy[8];

wire m_right = joy[0];
wire m_left  = joy[1];
wire m_down  = joy[2];
wire m_up    = joy[3];

// ESB mod selector.  The MRA's <rom index="1"><part>1</part></rom>
// drives ioctl_index=1 with data=0x01 when ESB is loaded; mod=0 (the
// default at boot) selects Star Wars.  Sticky after rom_download
// completes so the value survives once the MRA is in.
reg [7:0] mod_byte = 8'h00;
always @(posedge clk_12) begin
	if (ioctl_wr && (ioctl_index == 8'd1)) mod_byte <= ioctl_dout;
end
wire mod_esb = (mod_byte == 8'h01);
wire mod_starwars = !mod_esb;

// Video signals
wire hblank, vblank;
wire hs, vs;
wire [3:0] r,g,b;

wire reset = (RESET | status[0] |  buttons[1] | rom_download | nvram_download);

// Digital Joystick and Y-Axis Inversion Handling
wire [1:0] input_mode = status[33:32];
wire is_analog_input = (input_mode == 2'd0);
wire digital_yoke_forced = (input_mode == 2'd1);
wire [3:0] digital_yoke_step =
	status[35:34] == 2'b01 ? 4'd1 :
	status[35:34] == 2'b10 ? 4'd4 :
	status[35:34] == 2'b11 ? 4'd8 :
	                          4'd2;
wire [7:0] digital_yoke_move_step = {4'd0, digital_yoke_step};
// Separated for future enhancements (e.g., independent auto-centering speed)
wire [7:0] digital_yoke_center_step = digital_yoke_move_step;

function automatic signed [8:0] step_digital_yoke_axis;
	input signed [8:0] current;
	input signed [8:0] target;
	input [7:0] step;
	reg signed [9:0] diff;
	reg signed [9:0] step_s;
	begin
		diff = $signed({target[8], target}) - $signed({current[8], current});
		step_s = $signed({2'd0, step});

		if (diff > step_s)
			step_digital_yoke_axis = current + $signed({1'b0, step});
		else if (diff < -step_s)
			step_digital_yoke_axis = current - $signed({1'b0, step});
		else
			step_digital_yoke_axis = target;
	end
endfunction

wire input_y_reverse = status[36];
wire m_digital_up = input_y_reverse ? m_down : m_up;
wire m_digital_down = input_y_reverse ? m_up : m_down;
wire digital_yoke_x_active = m_left ^ m_right;
wire digital_yoke_y_active = m_digital_up ^ m_digital_down;
wire digital_yoke_direction = m_left | m_right | m_up | m_down;
wire signed [8:0] analog_yoke_x = $signed({joy_l_analog_0[7], joy_l_analog_0[7:0]});
wire signed [8:0] analog_yoke_y = $signed({joy_l_analog_0[15], joy_l_analog_0[15:8]});
wire analog_yoke_active =
	(analog_yoke_x > 9'sd24) || (analog_yoke_x < -9'sd24) ||
	(analog_yoke_y > 9'sd24) || (analog_yoke_y < -9'sd24);
wire signed [8:0] digital_yoke_target_x = (m_left ^ m_right) ? (m_right ? 9'sd127 : -9'sd128) : 9'sd0;
wire signed [8:0] digital_yoke_target_y = digital_yoke_y_active ? (m_digital_down ? 9'sd127 : -9'sd128) : 9'sd0;
reg signed [8:0] digital_yoke_x;
reg signed [8:0] digital_yoke_y;
reg [15:0] digital_yoke_tick_div;
wire digital_yoke_tick = (digital_yoke_tick_div == 16'd0);

reg digital_auto_latched;
wire digital_yoke_mode = (digital_yoke_forced || digital_auto_latched) && !is_analog_input;

always @(posedge clk_12) begin
	if (reset) begin
		digital_auto_latched <= 1'b0;
		digital_yoke_x <= 9'sd0;
		digital_yoke_y <= 9'sd0;
		digital_yoke_tick_div <= 16'd0;
	end else begin
		if (digital_yoke_forced || is_analog_input)
			digital_auto_latched <= 1'b0;
		else if (digital_yoke_direction)
			digital_auto_latched <= 1'b1;
		else if (analog_yoke_active)
			digital_auto_latched <= 1'b0;

		digital_yoke_tick_div <= digital_yoke_tick_div + 16'd1;

		if (!digital_yoke_mode) begin
			digital_yoke_x <= 9'sd0;
			digital_yoke_y <= 9'sd0;
			digital_yoke_tick_div <= 16'd0;
		end else if (digital_yoke_tick) begin
			digital_yoke_x <= step_digital_yoke_axis(
				digital_yoke_x,
				digital_yoke_target_x,
				digital_yoke_x_active ? digital_yoke_move_step : digital_yoke_center_step
			);
			digital_yoke_y <= step_digital_yoke_axis(
				digital_yoke_y,
				digital_yoke_target_y,
				digital_yoke_y_active ? digital_yoke_move_step : digital_yoke_center_step
			);
		end
	end
end

wire [7:0] raw_analog_y = joy_l_analog_0[15:8];
wire [7:0] final_analog_y = input_y_reverse ? ~raw_analog_y : raw_analog_y;
wire [7:0] yoke_x = digital_yoke_mode ? digital_yoke_x[7:0] : joy_l_analog_0[7:0];
wire [7:0] yoke_y = digital_yoke_mode ? digital_yoke_y[7:0] : final_analog_y;

// AUDIO OUT
wire [15:0] audio_l, audio_r;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_S = 1;
wire vgade;

// DIP SWITCHES (SW0)
wire [7:0] m_dsw0 = {
	~status[16],                                    // [7] Freeze (OG, 0=Off, 1=On -> ~0 = 1 = Off)
	mod_esb ? ~status[13] : status[13],             // [6] Demo Sounds (OD, 0=On, 1=Off)
	mod_esb ? ((status[12:11] == 2'b00) ? 2'b11 :
			   (status[12:11] == 2'b11) ? 2'b00 : status[12:11]) :
			   (status[12:11] + 2'd1),              // [5:4] Bonus Shields / JEDI Letters (OBC)
	mod_esb ? status[10:9] : (status[10:9] + 2'd1), // [3:2] Difficulty (O9A)
	mod_esb ? ~status[8:7] : (status[8:7] + 2'd2)   // [1:0] Starting Shields (O78)
};
// DIP SWITCHES (SW1)	
wire [7:0] m_dsw1 = {
	status[24:22],       // [7:5] Bonus Coin Adder (OMNO)
	status[21],          // [4] Left Coin (OL)
	status[20:19],       // [3:2] Right Coin (OJK)
	status[18:17] + 2'd2 // [1:0] Coinage (OHI, rotated +2: 0=1P/C,1=2C/P,2=Free,3=2P/C)
};

starwars starwars_core
(
	.clk_12(clk_12),
	.clk_50(clk_50),
	.clk_vid(clk_108),
	.reset(reset),

	.osd_raster_flicker(status[2]),
	.osd_audio_filter(~status[5]),   // Inverted: OSD 0=On, 1=Off
	.osd_audio_delay(~status[6]),    // Inverted: OSD 0=On, 1=Off
	.osd_120hz_mode(osd_120hz_mode),
	.osd_star_pattern(status[30:28]),
	.osd_tonemapping(status[31]),
	.osd_disable_flash(status[26]),
	.HDMI_HEIGHT(HDMI_HEIGHT),

	.mod_esb(mod_esb),
	
	.CE_PIXEL(CE_PIXEL),

	// DDRAM Framebuffer Interface
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
	.FB_PAL_WR(FB_PAL_WR),
	
	.audio_out_l(audio_l),
	.audio_out_r(audio_r),
	
	.video_r(r),
	.video_g(g),
	.video_b(b),
	.hsync(hs),
	.vsync(vs),
	.vblank(vblank),
	.hblank(hblank),
	
	.dsw0(m_dsw0),
	.dsw1(m_dsw1),
	.coin1(m_coin),
	.coin2(m_coin2),
	.aux_coin(m_auxcoin),
	.fire_l(m_fire_l),
	.fire_r(m_fire_r),
	.shield_l(m_shield_l),
	.shield_r(m_shield_r),
	.test_mode(status[1]),
	.analog_x(yoke_x),
	.analog_y(yoke_y),
	
	.led(core_led),
	
	// ROM Download
	.dn_addr(dl_addr),
	.dn_data(ioctl_dout),
	.dn_wr(ioctl_wr & rom_download),
	
	.nvram_write_pulse(nvram_write_pulse),
	.nvram_wr_ext(nvram_wr_ext),
	.nvram_addr_ext(nvram_addr_ext),
	.nvram_din_ext(nvram_din_ext),
	.nvram_dout_ext(nvram_dout_ext)
);

// --- NVRAM Save/Load/Clear Logic ---
wire nvram_cs_ioctl = (ioctl_index == 8'd4);
wire nvram_wr_ioctl = nvram_cs_ioctl && ioctl_download && ioctl_wr;

reg [7:0] clear_addr;
reg clearing;
reg old_clear_req;

always @(posedge clk_12) begin
	old_clear_req <= status[3];
	if (status[3] && !old_clear_req) begin
		clearing <= 1;
		clear_addr <= 0;
	end else if (clearing) begin
		if (clear_addr == 255) clearing <= 0;
		clear_addr <= clear_addr + 8'd1;
	end
end

wire        nvram_wr_ext   = nvram_wr_ioctl || clearing;
wire  [7:0] nvram_addr_ext = clearing ? clear_addr : ioctl_addr[7:0];
wire  [7:0] nvram_din_ext  = clearing ? 8'h00 : ioctl_dout;
wire  [7:0] nvram_dout_ext;
wire        nvram_write_pulse;

// --- NVRAM Auto-Save & Manual Save  ---
reg nvram_dirty;
reg force_save;


always @(posedge clk_12) begin
	if (reset) begin
		nvram_dirty <= 0;
		force_save <= 0;
	end else begin
		if (ioctl_upload && ioctl_index == 8'd4) begin
			nvram_dirty <= 0;
			force_save <= 0;
		end else if (nvram_write_pulse) begin
			nvram_dirty <= 1;
		end

		// If NVRAM is cleared we force a save.
		if (clearing && clear_addr == 255) begin
			force_save <= 1;
		end
	end
end

assign ioctl_upload_req = (status[27] & nvram_dirty) | status[4] | force_save;
assign ioctl_din = (ioctl_index == 8'd4) ? nvram_dout_ext : 8'h00;

endmodule
