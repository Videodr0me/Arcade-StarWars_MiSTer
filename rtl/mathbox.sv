// Star Wars Matrix Processor (Mathbox) implementation matching
// original Atari hardware by Videodr0me 2026
//
// Hardware reference:
//   - 4x 1Kx4 Microcode PROMs (136021-110 through 136021-113)
//   - 74LS384 serial subtractor-multiplier-accumulator
//   - 2Kx16 shared Math RAM ($5000-$5FFF as CPU sees it)
//   - 15-bit unsigned fractional divider
//   - 23-bit PRNG (LFSR)
//
// Timing:
//   - Each microcode step: 5 master clock cycles (12.096 MHz)
//   - MAC (LDC) adds 33 extra cycles (total 38 per LDC step)
//   - Divider: 15 iterations at master clock rate
//
// Based on SWMP.DOC, TCODE2.MAC, SWSIG.DOC, and original schematics:
//   - SP-225 Sheet 5B & 6A: Divider, Matrix Processor, and Multiplier-Accumulator Block Diagrams
//   - SP-225 Sheet 9A, 9B: 15-bit Restoring Divider
//   - SP-225 Sheet 10A: Multiplier/Accumulator Serial Circuitry & Registers
//   - SP-225 Sheet 10B: Block Index Counter (BIC) & Microprogram Program Address Logic (MPA/MPAC)
//   - SP-225 Sheet 11A: Shared RAM, Address MUX, 4x 1Kx4 PROMs & Strobes.

module mathbox (
	input         clk,    // Master clock (12.096 MHz)
	input         ce,     // 1.512 MHz Clock Enable (E Clock strobe)
	input         reset,
	input         prng_reset, // PRNG reset from outlatch[5] at $4685

	// CPU Interface
	input  [15:0] cpu_addr,
	input   [7:0] cpu_din,
	output  [7:0] cpu_dout,
	input         cpu_rw,
	input         cpu_vma,

	output        math_run, // Flags if MP is currently running

	// ROM Download
	input [24:0] dn_addr,
	input  [7:0] dn_data,
	input        dn_wr
);


	// =========================================================================
	// Control Registers
	// =========================================================================
	reg  [9:0] mpa;              // Microcode Program Address (10-bit, top 2 = page)
	reg  [8:0] bic;              // Block Index Counter (9-bit)
	reg [15:0] divisor;
	reg [15:0] dividend;
	reg [15:0] quotient;

	// Execution State
	reg signed [31:0] acc;       // 32-bit accumulator (upper 16 readable by CPU)
	reg signed [15:0] reg_a;
	reg signed [15:0] reg_b;
	reg signed [15:0] reg_c /* synthesis preserve */; // Hardware reg C (written but not CPU-readable)
	reg        running;
	reg  [2:0] state;            // Pipeline state (0-4 normal, 5 = MAC stall)
	reg  [5:0] mac_count;        // MAC cycle counter (counts down from 33)

	// Divider State
	reg [4:0] div_state;
	reg [15:0] temp_q;
	reg [15:0] temp_d;

	assign math_run = running | (div_state > 0);

	// =========================================================================
	// Math RAM (2K x 16, split hi/lo for M10K dual-port inference)
	// Port A: CPU access (read/write, gated by CE to single-clock write pulse)
	// Port B: Mathbox access (read during fetch, write during SAC)
	// =========================================================================
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] math_ram_hi [0:2047];
	(* ramstyle = "M10K, no_rw_check" *) reg [7:0] math_ram_lo [0:2047];

	wire ram_sel  = (cpu_addr >= 16'h5000 && cpu_addr <= 16'h5FFF) && cpu_vma;
	wire ctrl_sel = (cpu_addr >= 16'h4700 && cpu_addr <= 16'h4707) && cpu_vma;

	wire [10:0] cpu_word_addr = cpu_addr[11:1];
	wire        cpu_byte_sel  = cpu_addr[0]; // 0: MSB, 1: LSB

	// Port A: CPU read/write
	reg [7:0] cpu_ram_hi_out, cpu_ram_lo_out;
	always @(posedge clk) begin
		// CPU writes gated by CE: single clock pulse per CPU write cycle,
		// instead of 8 repeated writes. Reduces mixed-port collision window.
		if (ce && ram_sel && ~cpu_rw && ~cpu_byte_sel) math_ram_hi[cpu_word_addr] <= cpu_din;
		if (ce && ram_sel && ~cpu_rw &&  cpu_byte_sel) math_ram_lo[cpu_word_addr] <= cpu_din;
		cpu_ram_hi_out <= math_ram_hi[cpu_word_addr];
		cpu_ram_lo_out <= math_ram_lo[cpu_word_addr];
	end
	wire [7:0] cpu_ram_dout = cpu_byte_sel ? cpu_ram_lo_out : cpu_ram_hi_out;

	// Port B: Mathbox read/write
	reg [10:0] mb_addr;
	reg [15:0] mb_rdata;
	reg        mb_wr;
	reg  [7:0] mb_wdata_hi;
	reg  [7:0] mb_wdata_lo;

	always @(posedge clk) begin
		if (mb_wr) begin
			math_ram_hi[mb_addr] <= mb_wdata_hi;
			math_ram_lo[mb_addr] <= mb_wdata_lo;
		end
		mb_rdata <= {math_ram_hi[mb_addr], math_ram_lo[mb_addr]};
	end

	// =========================================================================
	// Microcode PROMs (4x 1024x4)
	// PROM0 = bits [15:12] (LDA, LDB, LDC, CLA)
	// PROM1 = bits [11:8]  (IBC, HALT, SAC, LAC)
	// PROM2 = bits [7:4]   (address mode + addr high)
	// PROM3 = bits [3:0]   (addr low)
	// =========================================================================
	(* ramstyle = "M10K" *) reg [3:0] prom0 [0:1023]; // bits 15-12
	(* ramstyle = "M10K" *) reg [3:0] prom1 [0:1023]; // bits 11-8
	(* ramstyle = "M10K" *) reg [3:0] prom2 [0:1023]; // bits 7-4
	(* ramstyle = "M10K" *) reg [3:0] prom3 [0:1023]; // bits 3-0

	// PROM download write
	wire prom0_wr = dn_wr && (dn_addr[11:10] == 2'd0);
	wire prom1_wr = dn_wr && (dn_addr[11:10] == 2'd1);
	wire prom2_wr = dn_wr && (dn_addr[11:10] == 2'd2);
	wire prom3_wr = dn_wr && (dn_addr[11:10] == 2'd3);

	// Microcode Instruction Fetch (reads every cycle, output registered)
	reg [3:0] ip0, ip1, ip2, ip3;
	always @(posedge clk) begin
		if (prom0_wr) prom0[dn_addr[9:0]] <= dn_data[3:0];
		ip0 <= prom0[mpa];
	end
	always @(posedge clk) begin
		if (prom1_wr) prom1[dn_addr[9:0]] <= dn_data[3:0];
		ip1 <= prom1[mpa];
	end
	always @(posedge clk) begin
		if (prom2_wr) prom2[dn_addr[9:0]] <= dn_data[3:0];
		ip2 <= prom2[mpa];
	end
	always @(posedge clk) begin
		if (prom3_wr) prom3[dn_addr[9:0]] <= dn_data[3:0];
		ip3 <= prom3[mpa];
	end

	wire [15:0] ip    = {ip0, ip1, ip2, ip3};
	wire  [7:0] ip15_8 = ip[15:8];
	wire        ip7    = ip[7];
	wire  [6:0] ip6_0  = ip[6:0];

	// Strobe definitions (bits of ip15_8, from TCODE2.MAC):
	//   [7] LDA     - Load A from RAM
	//   [6] LDB     - Load B from RAM
	//   [5] LDC     - Load C from RAM + start MAC
	//   [4] CLA     - Clear Accumulator
	//   [3] IBC     - Increment Block Index Counter
	//   [2] MHALT   - Halt execution
	//   [1] SAC     - Store Accumulator to RAM
	//   [0] LAC     - Load Accumulator from RAM

	// =========================================================================
	// RAM Address Generation
	// Direct mode (IP7=1): MA = IP6_0 (addresses 0-127)
	// Indexed mode (IP7=0): MA = {BIC[8:0], IP1_0} (512 blocks x 4 words)
	// =========================================================================
	wire [10:0] ma = ip7 ? {4'b0000, ip6_0}
	                      : ({4'b0000, ip6_0 & 7'h03} | ({2'b00, bic & 9'h1FF} << 2));

	// Registered strobes for use across pipeline stages
	reg [7:0] exec_strobe;       // Latched strobe bits for execution
	reg [10:0] exec_addr;        // Latched RAM address for execution/writeback

	// =========================================================================
	// PRNG (23-bit LFSR, runs continuously at ~3MHz)
	// Polynomial: x^23 + x^5 + 1 (prime), feedback inverted
	// Only bits [15:8] readable by CPU at $4703
	// =========================================================================
	reg [22:0] prng;
	reg [1:0] prng_div;
	always @(posedge clk) begin
		if (reset || prng_reset) begin
			prng <= 23'h0;
			prng_div <= 0;
		end else begin
			prng_div <= prng_div + 2'd1;
			if (prng_div == 0) begin // ~3MHz from 12MHz
				prng <= {prng[21:0], ~(prng[4] ^ prng[22])};
			end
		end
	end

	// =========================================================================
	// CPU Read Mux
	// =========================================================================
	reg [7:0] dout;
	always @(*) begin
		dout = 8'hFF;
		if (ram_sel) begin
			dout = cpu_ram_dout;
		end else if (ctrl_sel) begin
			case (cpu_addr[2:0])
				3'h0: dout = quotient[15:8]; // REH - quotient high
				3'h1: dout = quotient[7:0];  // REL - quotient low
				3'h3: dout = prng[15:8];     // PRNG
				default: ;
			endcase
		end
	end
	assign cpu_dout = dout;

	// =========================================================================
	// Divider (restoring division, 15 iterations)
	// Ones-complement + 1 subtraction, bit 16 = borrow
	// =========================================================================
	wire [16:0] div_sub = {1'b0, temp_d} + {1'b0, divisor ^ 16'hFFFF} + 17'd1;

	// =========================================================================
	// Serial Multiplier State (74LS384 model)
	// ACC += (A-B) * C * 4  (the <<2 models 74LS384 pipeline alignment)
	// A-B is computed at 16-bit width (wraps, matching hardware)
	// Then sign-extended for the serial multiply
	// =========================================================================
	reg signed [32:0] mac_shift;   // (A-B) shifted left each cycle
	reg        [15:0] mac_c;       // C register, shifts right each cycle
	reg signed [32:0] mac_prod;    // Accumulated product

	// A-B difference (17-bit signed to prevent overflow)
	wire signed [15:0] next_a = exec_strobe[7] ? mb_rdata : reg_a;
	wire signed [15:0] next_b = exec_strobe[6] ? mb_rdata : reg_b;
	wire signed [16:0] ab_diff = {next_a[15], next_a} - {next_b[15], next_b};

	// =========================================================================
	// Main State Machine
	//
	// 5-cycle pipeline per instruction step (matching hardware):
	//   State 0 (T0): MPA on PROM address bus. PROM read initiated.
	//   State 1 (T1): IP valid. Compute MA. Set RAM read address.
	//   State 2 (T2): RAMWORD valid from RAM.
	//   State 3 (T3): Execute all strobes. Write RAM if SAC. Start MAC if LDC.
	//   State 4 (T4): Advance MPA. Check HALT. → State 0.
	//
	// MAC stall (state 5): 33 additional cycles for serial multiply.
	//   After 33 cycles → State 4.
	//
	// Total: 5 cycles per normal step, 38 cycles per LDC step.
	// =========================================================================
	always @(posedge clk) begin
		if (reset) begin
			running   <= 0;
			mpa       <= 0;
			bic       <= 0;
			acc       <= 0;
			reg_a     <= 0;
			reg_b     <= 0;
			reg_c     <= 0;
			state     <= 0;
			mac_count <= 0;
			divisor   <= 0;
			dividend  <= 0;
			quotient  <= 0;
			div_state <= 0;
			temp_q    <= 0;
			temp_d    <= 0;
			mb_wr     <= 0;
		end else begin

			mb_wr <= 0; // Default: no RAM write

			// === Divider State Machine (independent, runs in parallel) ===
			if (div_state > 0) begin
				if (div_state <= 15) begin
					if (div_sub[16]) begin // Carry out = subtraction succeeded
						temp_q <= (temp_q << 1) | 16'd1;
						temp_d <= div_sub[15:0] << 1;
					end else begin
						temp_q <= temp_q << 1;
						temp_d <= temp_d << 1;
					end
					div_state <= div_state + 5'd1;
				end else begin
					quotient  <= temp_q;
					div_state <= 0;
				end
			end

			// === CPU Write Handling (gated by CE = 1.5MHz clock enable) ===
			if (ce && ctrl_sel && ~cpu_rw) begin
				case (cpu_addr[2:0])
					3'h0: begin // MW0 — Load MPA and START execution
						// On real hardware, MW0 is a simple latch write — it always
						// loads MPA and (re)starts the PROM state machine, even if
						// already running. No running guard exists in the original
						// hardware. The write is CE-gated (one pulse per E cycle)
						// so there is no risk of multiple starts per CPU write.
						mpa     <= {cpu_din, 2'b00};
						running <= 1;
						state   <= 0;
					end
					3'h1: bic <= {cpu_din[0], bic[7:0]};       // MW1 — BIC high bit
					3'h2: bic <= {bic[8], cpu_din[7:0]};       // MW2 — BIC low byte
					3'h4: begin // DVSRH — Divisor high + prep
						divisor <= {cpu_din, divisor[7:0]};
						temp_q  <= 16'd0;
						temp_d  <= dividend;
					end
					3'h5: begin // DVSRL — Divisor low + START divide
						divisor   <= {divisor[15:8], cpu_din};
						// Guard: only start division if idle. Once started, the
						// 15-cycle restoring division runs to completion.
						if (div_state == 0) begin
							div_state <= 1;
						end
					end
					3'h6: dividend <= {cpu_din, dividend[7:0]}; // DVDDH
					3'h7: dividend <= {dividend[15:8], cpu_din}; // DVDDL
					default: ;
				endcase
			end

			// === Matrix Processor Execution ===
			if (running) begin
				case (state)
					// ----- T0: PROM fetch initiated -----
					// mpa drives PROM address. ip will be valid next cycle.
					3'd0: state <= 3'd1;

					// ----- T1: IP valid, compute MA, initiate RAM read -----
					3'd1: begin
						mb_addr    <= ma;       // Set RAM read address
						exec_addr  <= ma;       // Latch for writeback
						exec_strobe <= ip15_8;  // Latch strobes for execution
						state <= 3'd2;
					end

					// ----- T2: RAMWORD valid from RAM -----
					3'd2: state <= 3'd3;

					// ----- T3: Execute all strobes -----
					3'd3: begin
						// CLEAR_ACC (bit 4, 0x10)
						if (exec_strobe[4]) acc <= 0;

						// LAC (bit 0, 0x01) — Load ACC from RAM (clears LSB)
						if (exec_strobe[0]) acc <= {mb_rdata, 16'h0000};

						// SAC/READ_ACC (bit 1, 0x02) — Store ACC to RAM
						if (exec_strobe[1]) begin
							mb_wr       <= 1;
							mb_addr     <= exec_addr;
							mb_wdata_hi <= acc[31:24];
							mb_wdata_lo <= acc[23:16];
						end

						// INC_BIC (bit 3, 0x08)
						if (exec_strobe[3]) bic <= (bic + 9'd1) & 9'h1FF;

						// LDB (bit 6, 0x40)
						if (exec_strobe[6]) reg_b <= mb_rdata;

						// LDA (bit 7, 0x80)
						if (exec_strobe[7]) reg_a <= mb_rdata;

						// LDC (bit 5, 0x20) — Load C + start MAC
						if (exec_strobe[5]) begin
							reg_c <= mb_rdata;

							// Initialize serial multiplier (74LS384)
							// A-B at 17-bit width (prevents wrapping),
							// then sign-extended to 33 bits
							mac_shift <= {{16{ab_diff[16]}}, ab_diff};
							mac_c     <= mb_rdata;
							mac_prod  <= 0;

							// A and B become sign-extended after MAC (ls384 serial behavior)
							// ONLY if they are not being loaded by LDA/LDB in the same cycle!
							if (!exec_strobe[7]) reg_a <= (reg_a[15]) ? 16'hFFFF : 16'h0000;
							if (!exec_strobe[6]) reg_b <= (reg_b[15]) ? 16'hFFFF : 16'h0000;

							mac_count <= 6'd33;
							state     <= 3'd5; // Enter MAC stall
						end else begin
							state <= 3'd4; // No MAC, advance MPA
						end
					end

					// ----- T4: Advance MPA, check HALT -----
					3'd4: begin
						// MPA wraps within 256-entry pages (top 2 bits = page select)
						mpa <= {mpa[9:8], mpa[7:0] + 8'd1};

						// M_HALT (bit 2, 0x04)
						if (exec_strobe[2]) running <= 0;

						state <= 3'd0;
					end

					// ----- MAC Stall: 33 cycles for serial multiply -----
					// Models the 74LS384 serial subtractor-multiplier-accumulator.
					// Processes 16 bits of C (15 magnitude + 1 sign) over first 16 cycles,
					// then waits for remaining 17 cycles (ACC ring rotation in hardware).
					3'd5: begin
						if (mac_count > 6'd1) begin
							// Active serial multiply (first 16 cycles: mac_count 33..18)
							if (mac_count > 6'd17) begin
								if (mac_count == 6'd18) begin
									// 16th cycle: C[15] = sign bit (subtract)
									if (mac_c[0]) mac_prod <= mac_prod - mac_shift;
								end else begin
									// Cycles 1-15: C[0..14] = magnitude bits (add)
									if (mac_c[0]) mac_prod <= mac_prod + mac_shift;
								end
								mac_shift <= mac_shift <<< 1;
								mac_c     <= {1'b0, mac_c[15:1]};
							end

							mac_count <= mac_count - 6'd1;
						end else begin
							// Final cycle (mac_count == 1): add product to ACC
							// The <<2 likely models pipeline alignment in the 74LS384
							// (My interpretation — matches MAME and all test results)
							acc       <= acc + (mac_prod[31:0] <<< 2);
							mac_count <= 0;
							state     <= 3'd4; // Continue to MPA advance
						end
					end

					default: state <= 3'd0;
				endcase
			end
		end
	end

endmodule
