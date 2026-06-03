-- Atari SLAPSTIC 137412-101 (Empire Strikes Back / Tetris) — faithful FPGA port
-- of MAME's DECAPPED slapstic (src/mame/atari/slapstic.{cpp,h}, Aaron Giles &
-- Frank Palazzolo). derpyder 2026.
--
-- WHY THIS EXISTS (supersedes rtl/slapstic.vhd for ESB):
--   rtl/slapstic.vhd is a verbatim translation of an OLD, *unconfirmed* MAME
--   slapstic. For type 101 it carried alt1 = {0x007f, UNKNOWN(0xFFFF)} — a value
--   that can NEVER match — and it only ever saw in-range ($8000-$9FFF) accesses.
--   That is enough for ESB's *direct* banking (attract: ping-pongs banks 1<->3),
--   so the game boots & renders. But ESB *gameplay* uses ALTERNATE ("devious")
--   banking, confirmed via MAME (-log) over real play: 51 full
--   alt-start/valid/select/commit sequences reaching banks 0/2.  The old core
--   cannot do it, so the first gameplay alt-switch lands the wrong bank and the
--   6809 jumps through a bad pointer into non-ROM ~5 vggos in. THE crash.
--
-- KEY DECAPPED FACTS (type 101, 13 address lines A0-A12, banked region $8000-$9FFF):
--   * range_mask = 0xE000, input_mask = 0x1FFF, range_value = 0x8000
--   * test_in(mv)   : inside ($8000-$9FFF)  AND (a & mv.mask)=mv.value
--   * test_any(mv)  :                            (a & mv.mask)=mv.value   (no range gate)
--   * test_reset    : a = $8000
--   * test_bank(b)  : a = $8000 | b
--   * ALTERNATE banking for 101/102 REQUIRES the 2nd step to be done OUTSIDE the
--     bank region — in practice the 6809's dummy/VMA cycle drives $FFFF (which our
--     mc6809i.v core also defaults addr to). MAME taps the WHOLE space; so must we.
--     Hence this block is stepped once per 6809 bus cycle with the FULL 16-bit
--     address (NOT gated to $8000-$9FFF).
--
-- type-101 data (decapped):
--   bankstart 3 ; bank = {0x0080,0x0090,0x00a0,0x00b0}
--   alt1 {0x1f00,0x1e00}  alt2 {0x1fff,0x1fff}(any/outside)  alt3 {0x1ffc,0x1b5c}  alt4 {0x1fcf,0x0080}  altshift 0
--   bit1 {0x1ff0,0x1540}  bit2 {0x1fcf,0x0080}
--   bit3c0 {0x1ff3,0x1540} bit3s0 {0x1ff3,0x1541} bit3c1 {0x1ff3,0x1542} bit3s1 {0x1ff3,0x1543}  bit4 {0x1ff8,0x1550}

library ieee;
	use ieee.std_logic_1164.all;

entity slapstic101 is
	port(
		I_CK    : in  std_logic;                       -- 12 MHz master clock
		I_STEP  : in  std_logic;                       -- 1-clk pulse, once per 6809 bus cycle
		I_RESET : in  std_logic;                       -- power-on reset (active high)
		I_A     : in  std_logic_vector(15 downto 0);   -- full 6809 address for this cycle
		O_BS    : out std_logic_vector( 1 downto 0)    -- bank select (0..3)
	);
end slapstic101;

architecture rtl of slapstic101 is
	type sm_t is (S_IDLE, S_ACTIVE, S_ALT_VALID, S_ALT_SELECT, S_ALT_COMMIT,
	              S_BIT_LOAD, S_BIT_ODD, S_BIT_EVEN);
	signal state  : sm_t := S_IDLE;
	signal cur    : std_logic_vector(1 downto 0) := "11";  -- bankstart = 3
	signal loaded : std_logic_vector(1 downto 0) := "00";

	-- masked compare: (a & m) = v
	function m(a : std_logic_vector(15 downto 0);
	          mk : std_logic_vector(15 downto 0);
	          v : std_logic_vector(15 downto 0)) return boolean is
	begin
		return (a and mk) = v;
	end function;
begin
	O_BS <= cur;

	process(I_CK)
		variable a       : std_logic_vector(15 downto 0);
		variable inside  : boolean;
		variable isreset : boolean;
	begin
		if rising_edge(I_CK) then
			if I_RESET = '1' then
				state  <= S_IDLE;
				cur    <= "11";       -- reset to bankstart (3)
				loaded <= "00";
			elsif I_STEP = '1' then
				a       := I_A;
				inside  := (a(15 downto 13) = "100");      -- $8000-$9FFF
				isreset := (a = x"8000");                  -- test_reset

				case state is
					-- waits for a reset access to enable
					when S_IDLE =>
						if isreset then state <= S_ACTIVE; end if;

					-- enabled: direct bank select, or enter alt / bitwise
					when S_ACTIVE =>
						if    a = x"8080" then cur <= "00"; state <= S_IDLE;   -- bank0
						elsif a = x"8090" then cur <= "01"; state <= S_IDLE;   -- bank1
						elsif a = x"80A0" then cur <= "10"; state <= S_IDLE;   -- bank2
						elsif a = x"80B0" then cur <= "11"; state <= S_IDLE;   -- bank3
						elsif inside and m(a, x"1F00", x"1E00") then state <= S_ALT_VALID;  -- alt1
						elsif inside and m(a, x"1FF0", x"1540") then state <= S_BIT_LOAD;   -- bit1
						end if;

					-- alt: 2nd access MUST be OUTSIDE the range (the $FFFF dummy)
					when S_ALT_VALID =>
						if isreset then
							state <= S_ACTIVE;
						elsif (not inside) and m(a, x"1FFF", x"1FFF") then     -- alt2 (test_any, outside)
							state <= S_ALT_SELECT;
						else
							state <= S_ACTIVE;                                 -- sequence break
						end if;

					-- alt: in-range select, low 2 bits = target bank
					when S_ALT_SELECT =>
						if isreset then
							state <= S_ACTIVE;
						elsif inside and m(a, x"1FFC", x"1B5C") then           -- alt3
							loaded <= a(1 downto 0);                           -- (a >> altshift=0) & 3
							state  <= S_ALT_COMMIT;
						else
							state <= S_ACTIVE;                                 -- sequence break
						end if;

					-- alt: commit on an in-range bank-region access
					when S_ALT_COMMIT =>
						if isreset then
							state <= S_ACTIVE;
						elsif inside and m(a, x"1FCF", x"0080") then           -- alt4
							cur   <= loaded;
							state <= S_IDLE;
						end if;

					-- bitwise: load current bank
					when S_BIT_LOAD =>
						if isreset then
							state <= S_ACTIVE;
						elsif inside and m(a, x"1FCF", x"0080") then           -- bit2
							loaded <= cur;
							state  <= S_BIT_ODD;
						end if;

					-- bitwise: twiddle bits (odd parity), or commit
					when S_BIT_ODD =>
						if isreset then
							state <= S_ACTIVE;
						elsif inside and m(a, x"1FF3", x"1540") then loaded <= loaded and "10"; state <= S_BIT_EVEN; -- clear0
						elsif inside and m(a, x"1FF3", x"1541") then loaded <= loaded or  "01"; state <= S_BIT_EVEN; -- set0
						elsif inside and m(a, x"1FF3", x"1542") then loaded <= loaded and "01"; state <= S_BIT_EVEN; -- clear1
						elsif inside and m(a, x"1FF3", x"1543") then loaded <= loaded or  "10"; state <= S_BIT_EVEN; -- set1
						elsif inside and m(a, x"1FF8", x"1550") then cur <= loaded; state <= S_IDLE;                 -- bit4 commit
						end if;

					-- bitwise: twiddle bits (even parity = swapped mapping), or commit
					when S_BIT_EVEN =>
						if isreset then
							state <= S_ACTIVE;
						elsif inside and m(a, x"1FF3", x"1543") then loaded <= loaded and "10"; state <= S_BIT_ODD; -- clear0 (bit3s1)
						elsif inside and m(a, x"1FF3", x"1542") then loaded <= loaded or  "01"; state <= S_BIT_ODD; -- set0  (bit3c1)
						elsif inside and m(a, x"1FF3", x"1541") then loaded <= loaded and "01"; state <= S_BIT_ODD; -- clear1(bit3s0)
						elsif inside and m(a, x"1FF3", x"1540") then loaded <= loaded or  "10"; state <= S_BIT_ODD; -- set1  (bit3c0)
						elsif inside and m(a, x"1FF8", x"1550") then cur <= loaded; state <= S_IDLE;                -- bit4 commit
						end if;
				end case;
			end if;
		end if;
	end process;
end rtl;
