-- Atari Star Wars Analog Vector Generator (AVG) by Videodr0me 2026
--
-- PROM-based state machine matching original hardware timing.
-- Cycle exact including normalization substates.
-- The 256x4 state PROM is loaded via the MRA download interface.
-- States advance at 1.5 MHz (one state per clken tick = 8 master clocks at
-- 12.096 MHz). During normalization (STROBE 0), the PROM state freezes
-- (matching hardware SA signal) while LS194-style shifts run at 12 MHz.
-- Vector_drawer receives normalized coordinates.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity avg is
    Port (  cpu_data_in : out  STD_LOGIC_VECTOR (7 downto 0);
        	cpu_data_out : in  STD_LOGIC_VECTOR (7 downto 0);
        	cpu_addr : in  STD_LOGIC_VECTOR (13 downto 0);
        	cpu_cs_l : in  STD_LOGIC;
        	cpu_rw_l : in  STD_LOGIC;
			vgrst : in STD_LOGIC; 
			vggo : in STD_LOGIC;
			halted : out STD_LOGIC;
        	xout : out  STD_LOGIC_VECTOR (13 downto 0);
        	yout : out  STD_LOGIC_VECTOR (13 downto 0);
        	zout : out  STD_LOGIC_VECTOR (7 downto 0);
        	rgbout : out  STD_LOGIC_VECTOR (2 downto 0);
        	is_dot : out STD_LOGIC;
			clken: in STD_LOGIC;
        	clk : in  STD_LOGIC;
			  
			-- External memory interface for AVG
			avg_addr_out : out STD_LOGIC_VECTOR(15 downto 0);
			avg_data_in  : in  STD_LOGIC_VECTOR(7 downto 0);
			 
			dn_addr   : in std_logic_vector(7 downto 0);
			dn_data   : in std_logic_vector(7 downto 0);
			dn_wr     : in std_logic			  
		);
end avg;

-- Instruction encoding (6809 big-endian: high byte at lower address):
--   First byte read (LATCH 1): contains opcode in bits 7:5
--   Second byte read (LATCH 0): contains low data byte
--
--  Opcode                     Hex      Binary (hi byte, lo byte)
--    VCTR  (draw long)         0x00     000YYYYY YYYYYYYY  IIIXXXXX XXXXXXXX
--    HALT                      0x20     00100000 00000000
--    SVEC  (draw short)        0x40     010YYYYY IIIXXXXX
--    STAT  (color, U=0)        0x60     0110_RGB IIIIIIII
--    STAT  (scale, U=1)        0x70     0111_SSS LLLLLLLL
--    CENTER                    0x80     10000000 0DDDDDDD  (DVY sets timer via norm)
--    JSRL  (call subroutine)   0xA0     101AAAAA AAAAAAAA
--    RTSL  (return)            0xC0     11000000 00000000
--    JMPL  (jump)              0xE0     111AAAAA AAAAAAAA

architecture Behavioral of avg is
	type stackarraytype is array (natural range <>) of std_logic_vector(13 downto 0);

	-- ================================================================
	-- AVG State PROM (256 x 4 bits)
	-- Loaded from ROM set via dn_addr/dn_data/dn_wr during download.
	-- Hardware: 136021-109.4b bipolar PROM
	--
	-- Address bits: A7 = NOT_HALT (running), A6..A4 = OP2..OP0, A3..A0 = ST3..ST0
	-- Output: 4-bit next state (ST3..ST0)
	--
	-- When ST3=1, a latch/strobe fires based on ST2..ST0:
	--   $8 = LATCH 0  (load DVY low byte)
	--   $9 = LATCH 1  (load DVY high byte + opcode)
	--   $A = LATCH 2  (load DVX low byte)
	--   $B = LATCH 3  (load DVX high byte + intensity)
	--   $C = STROBE 0 (normalize / push PC)
	--   $D = STROBE 1 (scale / SP adjust)
	--   $E = STROBE 2 (load STAT or PC for JMP/JSR/RTS)
	--   $F = STROBE 3 (GO draw / HALT / CENTER)
	--
	-- When ST3=0 (states $0-$7): idle tick, no strobe fires.
	-- ================================================================
	type prom_array_t is array (0 to 255) of std_logic_vector(3 downto 0);
	signal avg_prom : prom_array_t;

	signal pc: STD_LOGIC_VECTOR(13 downto 0);
	signal instruction: STD_LOGIC_VECTOR(15 downto 0);
	signal operand: STD_LOGIC_VECTOR(15 downto 0);
	signal stack: stackarraytype(3 downto 0);
	signal sp: STD_LOGIC_VECTOR(1 downto 0);
	signal memory_din: STD_LOGIC_VECTOR(7 downto 0);
	signal memory_addr: STD_LOGIC_VECTOR(13 downto 0);

	signal vec_dx: STD_LOGIC_VECTOR(12 downto 0);
	signal vec_dy: STD_LOGIC_VECTOR(12 downto 0);
	signal vec_zero: STD_LOGIC;
	signal vec_draw: STD_LOGIC;
	signal vec_done: STD_LOGIC;
	signal retryRead: STD_LOGIC;
	signal intensity: STD_LOGIC_VECTOR(7 downto 0);
	signal intens_mod: STD_LOGIC_VECTOR(2 downto 0);
	signal rgb: STD_LOGIC_VECTOR(2 downto 0);
	signal z_mult: STD_LOGIC_VECTOR(10 downto 0);
	-- Linear scale register (SWSIG.DOC: see LF13201 multiplying DAC, schematic p.26).
	-- On the original PCB, linear_scale controls the beam VELOCITY via an
	-- analog multiplier (LF13201), while the LS161 timer chain controls
	-- draw DURATION. The two are independent hardware paths.
	signal linear_scale_reg: STD_LOGIC_VECTOR(7 downto 0);
	-- Binary scale register: 3-bit value (0-7) from STAT instruction.
	-- On hardware, this is latched by the LS175 (6L, schematic p.25 Fig.1)
	-- from DVY10-DVY8, and drives the LS191 down-counter that gates
	-- additional fill-bit shifts into the timer at STROBE 1.
	signal bin_scale: STD_LOGIC_VECTOR(2 downto 0);

	-- PROM state machine signals (256x4 PROM 136021-109.4b, schematic p.24 Fig.3)
	signal prom_state: STD_LOGIC_VECTOR(3 downto 0); -- current state (ST3..ST0)
	signal op: STD_LOGIC_VECTOR(2 downto 0);          -- current opcode (OP0-OP2)
	signal halt_flag: STD_LOGIC;                       -- set by HALT instruction
	-- GO flag (schematic p.24 Fig.3: 2E LS32 pin 8).
	-- On hardware, GO = VCTR OR CNTR.  When GO=1 the PROM address A7 is
	-- forced low (AM7 = NOR(HALT*, GO) = 0), putting the PROM on the idle
	-- page ($00-$7F) where all states have ST3=0 (no latches/strobes fire).
	-- The state machine keeps ticking at 1.5 MHz; it just loops through
	-- idle states while the timer counts down.
	-- /STOP clears the VCTR/CNTR JK flip-flops -> GO=0 -> PROM returns to
	-- active page -> next instruction starts.
	signal go_flag: STD_LOGIC;                         -- drawing in progress (VCTR/CNTR set)

	-- Normalization at 12 MHz (schematic p.24 Fig.0: Normalization Flag circuit).
	-- STROBE 0 + OP0=0 sets NORM (LS74 5K). NORM asserts SA (freezes PROM)
	-- and enables /ENORM (via S10) to clock LS194 shift registers at 12 MHz.
	-- Terminates when DVY12!=DVY11 or DVX12!=DVX11 (S86 XOR → S260 NOR).
	signal norm_active: STD_LOGIC;                     -- normalization in progress
	signal norm_count: STD_LOGIC_VECTOR(3 downto 0);   -- shift counter (diagnostic)
	-- 15-bit Vector Timer (schematic p.25 Fig.0: four cascaded LS161 counters
	-- 1D/1C/1B/2B, clocked at 12 MHz during draw, enabled by PR111 (+5V pull-up),
	-- loaded via fill-bit shifts during normalization and bin_scale).
	-- VCTR (OP1=0): full 15-bit timer. Draw time = timer counts to overflow.
	-- SVEC (OP1=1): 8-bit timer (LS02 gate 2A routes OP1 into bit 7 fill,
	-- LS20 NAND 2A generates STOP from 8-bit overflow).
	signal hw_timer: STD_LOGIC_VECTOR(14 downto 0);    -- 15-bit hardware timer
	signal is_svec: STD_LOGIC;                          -- OP1: '1' for SVEC, '0' for VCTR
	-- Bin_scale shift mechanism at STROBE 1 (schematic p.25 Fig.1: Vector Scaling).
	-- LS191 counter (6M) counts down from bin_scale value at 12 MHz, gating
	-- additional fill-bit shifts into the timer chain after normalization.
	signal binscale_active: STD_LOGIC;                  -- bin_scale shifting in progress
	signal binscale_count: STD_LOGIC_VECTOR(2 downto 0); -- current shift count

begin
	-- External memory interface
	avg_addr_out <= "00" & memory_addr;
	memory_din <= avg_data_in;
	
	z_mult <= intens_mod * intensity;

	-- PROM download: write during ROM loading
	process (clk) begin
		if clk'event and clk='1' then
			if dn_wr='1' then
				avg_prom(conv_integer(dn_addr)) <= dn_data(3 downto 0);
			end if;
		end if;
	end process;
	
	vectordrawer: entity work.vector_drawer port map (
		clk => clk,
		clk_ena => clken,
		hw_timer => hw_timer,
		is_svec => is_svec,
		linear_scale => linear_scale_reg,
		rel_x => vec_dx,
		rel_y => vec_dy,
		zero => vec_zero,
		draw => vec_draw,
		done => vec_done,
		is_dot => is_dot,
		xout => xout,
		yout => yout
	);
	
	-- =================================================================
	-- Main PROM-driven state machine process
	-- Each clken tick = 1 tick at 1.5 MHz = 8 master clocks (662 ns)
	-- =================================================================
	process (clk)
		variable prom_addr : std_logic_vector(7 downto 0);
		variable next_state : std_logic_vector(3 downto 0);
		variable running : std_logic;
	begin
		if clk'event and clk='1' then
			-- vec_zero and vec_draw must be 1-clock pulses at 12 MHz.
			-- On hardware, VCTR/CNTR are edge-triggered JK flip-flops
			-- (2F LS76) that set on a single VGCK edge at STROBE3.
			vec_zero<='0';
			vec_draw<='0';

			if clken='1' then
				if vgrst='1' then
					-- ===== VGRST: Full reset =====
					pc<="00000000000000";
					instruction<=x"0000";
					operand<=x"0000";
					prom_state<=x"0";
					op<="000";
					halt_flag<='1';
					go_flag<='0';
					norm_active<='0';
					norm_count<="0000";
					sp<="00";
					rgb<="000";
					intensity<=(others=>'0');
					intens_mod<=(others=>'0');
					linear_scale_reg<=(others=>'0');
					bin_scale<="000";
					vec_dx<=(others=>'0');
					vec_dy<=(others=>'0');
					hw_timer<=(others=>'0');
					is_svec<='0';
					binscale_active<='0';
					binscale_count<="000";
					vec_zero<='1';
					vec_draw<='0';
					retryRead<='0';

				elsif halt_flag='1' then
					-- ===== Halted: wait for VGGO =====
					pc<=(others=>'0');
					rgb<="000";
					vec_zero<='1';
					if vggo='1' then
						halt_flag<='0';
						prom_state<=x"0";
						sp<="00";
					end if;

				elsif norm_active='1' then
					-- ===== Normalization in progress =====
					-- PROM state is FROZEN (matching hardware SA mechanism).
					null;

				elsif binscale_active='1' then
					-- ===== Bin_scale shifting in progress =====
					-- PROM state is FROZEN while bin_scale shifts execute at 12 MHz.
					null;

				elsif cpu_cs_l='0' then
					-- ===== VMEM bus arbitration: CPU accessing vector memory =====
					-- On real hardware (schematic p.24 Fig.3), EVMEM from the main
					-- board gates the state machine clock via NOR gate 3E (LS02).
					-- When /VMEM=1 (CPU accessing $0000-$3FFF), the NOR output is
					-- forced LOW, blocking SM_CLK and freezing the PROM state machine.
					-- Stall for exactly 1 tick (matching 1 E-cycle = 1 SM_CLK period)
					null;

				else
					-- ===== Normal PROM tick =====
					-- Clear go_flag when drawer finishes (hardware: /STOP
					-- clears VCTR/CNTR JK flip-flops via /K input).
					if go_flag='1' and vec_done='1' then
						go_flag <= '0';
					end if;

					-- Compute PROM address: {running, op[2:0], state[3:0]}
					-- Hardware: AM7 = NOR(HALT*, GO).  AM7=1 (running) only
					-- when not halted AND not drawing.  During draws, AM7=0
					-- forces the PROM to the idle page ($00-$7F) where all
					-- states have ST3=0 — no latches/strobes fire.
					running := not halt_flag and not go_flag;
					prom_addr := running & op & prom_state;
					
					-- Read next state from PROM
					next_state := avg_prom(conv_integer(prom_addr));
					
					-- Execute action for the NEW state
					if next_state(3)='1' then
						-- ST3=1: a latch or strobe fires
						case next_state(2 downto 0) is

							when "001" =>
								-- LATCH 1 (state $9): Read hi byte → opcode + DVY high.
								-- /LATCH1 clears three chip groups (schematic p.23):
								--   5F,5H (Fig.2): DVY0-7 async cleared to 0
								--   5A,5B,5C (Fig.2): DVX0-11 async cleared to 0
								--   3C (Fig.0): Z0-Z2 + DVX12 async cleared to 0
								-- 6H(DVY8-11) has /CLR=PR110 (not cleared here).
								-- 4H(OP,DVY12) has /CLR=PR110 (not cleared here).
								instruction(15 downto 8) <= memory_din;
								op <= memory_din(7 downto 5);
								instruction(7 downto 0) <= (others => '0');  -- DVY0-7 (5F,5H /CLR)
								operand(11 downto 0) <= (others => '0');     -- DVX0-11 (5A,5B,5C /CLR)
								operand(12) <= '0';                          -- DVX12 (3C /CLR)
								intens_mod <= "000";                         -- Z0-Z2 (3C /CLR)
								pc <= pc + "00000000000001";

							when "000" =>
								-- LATCH 0 (state $8): Read lo byte -> DVY low
								instruction(7 downto 0) <= memory_din;
								pc <= pc + "00000000000001";

							when "011" =>
								-- LATCH 3 (state $B): Read hi byte -> DVX high + intensity
								operand(15 downto 8) <= memory_din;
								pc <= pc + "00000000000001";

							when "010" =>
								-- LATCH 2 (state $A): Read lo byte -> DVX low
								operand(7 downto 0) <= memory_din;
								pc <= pc + "00000000000001";

							when "100" =>
								-- STROBE 0 (state $C): Push PC for JSR, or start normalization
								if op="101" then -- JSRL: push PC
									if (sp="00") then stack(0)<=pc; end if;
									if (sp="01") then stack(1)<=pc; end if;
									if (sp="10") then stack(2)<=pc; end if;
									if (sp="11") then stack(3)<=pc; end if;
								else
									-- STROBE0 + OP0=0 sets NORM (LS74 5K, p.24 Fig.0).
									-- Applies to: VCTR(000), SVEC(010), CENTER(100).
									if op="000" or op="010" or op="100" then
										norm_active <= '1';
										norm_count <= "0000";
										hw_timer <= (others => '0');
										is_svec <= op(1);
									end if;
								end if;

							when "101" =>
								-- STROBE 1 (state $D): SP adjust for JSR/RTS,
								-- or Vector Scaling (schematic p.25 Fig.1) for VCTR/SVEC.
								if op="101" then    -- JSRL: sp++
									sp <= sp + "01";
								elsif op="110" then -- RTSL: sp--
									sp <= sp - "01";
								elsif op="000" or op="010" then
									-- VCTR/SVEC: start LS191 bin_scale count-down,
									-- gating fill-bit shifts into the LS161 timer chain
									if bin_scale /= "000" then
										binscale_active <= '1';
										binscale_count <= "000";
									end if;
								end if;

							when "110" =>
								-- STROBE 2 (state $E): Load STAT or update PC
								if op="011" then
									-- STAT instruction
									if instruction(12)='0' then
										-- Color/intensity (0110_RGB IIIIIIII)
										intensity <= instruction(7 downto 0);
										rgb <= instruction(10 downto 8);
									else
										-- Scale (0111_SSS LLLLLLLL)
										-- SSS = bin_scale → LS175 latch (6L) → LS191 counter (6M)
										-- LLLLLLLL = linear_scale → LF13201 DAC (schematic p.26)
										linear_scale_reg <= instruction(7 downto 0);
										bin_scale <= instruction(10 downto 8);
									end if;

								elsif op="101" or op="111" then
									-- JSRL or JMPL: PC = instruction(12:0) << 1
									pc(13 downto 1) <= instruction(12 downto 0);
									pc(0) <= '0';
								elsif op="110" then
									-- RTSL: pop PC from stack
									-- SP was already decremented by STROBE 1, so read stack[sp] directly
									if (sp="00") then pc<=stack(0); end if;
									if (sp="01") then pc<=stack(1); end if;
									if (sp="10") then pc<=stack(2); end if;
									if (sp="11") then pc<=stack(3); end if;
								end if;

							when "111" =>
								-- STROBE 3 (state $F): GO draw / HALT / CENTER
								-- VCTR/SVEC: OP2=0,OP0=0 -> VCTR flag set -> GO=1 -> draw
								-- CENTER:    OP2=1 -> CNTR flag set -> GO=1 -> timer wait
								-- HALT:      OP0=1 -> halt flag set
								if op="000" or op="010" then
									-- VCTR or SVEC: draw vector
									-- VCTR/SVEC: pass normalized DVY/DVX to drawer.
									vec_dy <= instruction(12 downto 0);
									vec_dx <= operand(12 downto 0);
									intens_mod <= operand(15 downto 13);
									vec_draw <= '1';
									go_flag <= '1';
								elsif op="001" then
									-- HALT
									halt_flag <= '1';
								elsif op="100" then
									-- CENTER: DVY was loaded by LATCH1+LATCH0 and
									-- normalized at STROBE0 (sets timer duration).
									-- CNTR=1 -> GO=1 -> timer counts -> /STOP.
									-- /CENTER resets integrators to screen center.
									-- Modeled as zero+draw: position resets, timer waits.
									vec_dx <= (others => '0');
									vec_dy <= (others => '0');
									intens_mod <= "000";
									vec_zero <= '1';
									vec_draw <= '1';
									go_flag <= '1';
								end if;

							when others => null;
						end case;
					end if;
					-- ST3=0 (states $0-$7): idle tick, no action
					
					-- Advance PROM state
					prom_state <= next_state;

				end if;
			end if;

			-- ============================================================
			-- 12 MHz Normalization Block (runs OUTSIDE clken gate)
			-- Schematic p.23 Fig.2: LS194 shift registers (3A-3D, 4A-4D)
			-- shift DVX/DVY left at 12 MHz, gated by ENORM.
			-- Schematic p.25 Fig.0: LS161 timer chain (1D/1C/1B/2B)
			-- shifts right simultaneously, filling from the top.
			-- Schematic p.24 Fig.0: NORM flag freezes PROM via SA.
			-- ============================================================
			if norm_active='1' then
				-- Termination: S86 XOR (4F, p.24 Fig.0) checks
				-- DVY12!=DVY11 or DVX12!=DVX11 -> NORM_CLR=0 -> NORM cleared.
				if instruction(12) /= instruction(11)
				   or operand(12) /= operand(11)
				   or norm_count >= "1111" then
					norm_active <= '0';
					-- SVEC (OP1=1): the hardware uses an 8-bit sub-timer
					-- (LS20 NAND 2A and LS02 gate route OP1 into bit 7,
					-- and STOP is generated from the low-byte overflow).
					-- Clearing bits 14:8 simulates the 8-bit timer boundary.
					if is_svec='1' then
						hw_timer(14 downto 8) <= (others => '0');
					end if;
				else
					-- LS194 shift registers: DVY shifts left by 1
					instruction(12 downto 1) <= instruction(11 downto 0);
					instruction(0) <= '0';
					-- LS194 shift registers: DVX shifts left by 1
					operand(12 downto 1) <= operand(11 downto 0);
					operand(0) <= '0';
					-- Note: Bit 14 is inherently set by the +5V pull-up PR111
					-- loading '1's into the timer during normalization shifts.
					-- Bit 7: LS02 gate 2A routes OP1 — set to '1' for SVEC,
					-- otherwise normal shift-in from bit 8.
					hw_timer(14) <= '1';
					hw_timer(13 downto 8) <= hw_timer(14 downto 9);
					if is_svec='1' then
						hw_timer(7) <= '1';
					else
						hw_timer(7) <= hw_timer(8);
					end if;
					hw_timer(6 downto 0) <= hw_timer(7 downto 1);
					norm_count <= norm_count + "0001";
				end if;
			end if;

			-- ============================================================
			-- 12 MHz Bin_Scale Block (runs OUTSIDE clken gate)
			-- Schematic p.25 Fig.1: Vector Scaling circuit.
			-- LS191 counter (6M) counts down from the loaded bin_scale
			-- value (DVY10-DVY8 latched by LS175 at STROBE1+OP2).
			-- Each count-down tick performs the same fill-bit shift on
			-- the LS161 timer chain as normalization.
			-- SVEC: timer masked to 8 bits when LS191 reaches zero.
			-- ============================================================
			if binscale_active='1' then
				if binscale_count >= bin_scale then
					binscale_active <= '0';
					-- SVEC: 8-bit timer boundary (LS20/LS02 STOP circuit)
					if is_svec='1' then
						hw_timer(14 downto 8) <= (others => '0');
					end if;
				else
					-- Same LS161 fill-bit shift as normalization
					hw_timer(14) <= '1';
					hw_timer(13 downto 8) <= hw_timer(14 downto 9);
					if is_svec='1' then
						hw_timer(7) <= '1';
					else
						hw_timer(7) <= hw_timer(8);
					end if;
					hw_timer(6 downto 0) <= hw_timer(7 downto 1);
					binscale_count <= binscale_count + "001";
				end if;
			end if;

		end if;
	end process;
	
	-- Memory address tracking: always follows PC
	process (clk) begin
		if clk'event and clk='1' then
			memory_addr <= pc;
			cpu_data_in <= x"00"; 
		end if;
	end process;

	-- VGHALT output: active when halted
	halted <= halt_flag;
	
	zout <= z_mult(10 downto 3);
	
	rgbout <= rgb;
end Behavioral;
