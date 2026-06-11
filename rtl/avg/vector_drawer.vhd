-- Vector drawer: digital replacement for the Atari AVG's analog integrators
-- and timer circuitry. Receives pre-normalized DVX/DVY and hw_timer from
-- the AVG state machine (avg.vhd) and rasterizes vectors into the framebuffer.
-- (C) 2012 Jeroen Domburg (jeroen AT spritesmods.com)
--
-- Modified by Videodr0me for the Star Wars MiSTer Port 2026.
--
-- On the original PCB (SWSIG.DOC, Jed Margolin 5/1/83):
--   - The LS161 timer chain (schematic p.25 Fig.0) counts up at 12 MHz.
--   - The AM6012 DACs (schematic p.26) convert DVX/DVY into analog voltages.
--   - LF13201 multiplying DACs apply linear_scale as a velocity multiplier.
--   - Op-amp integrators accumulate the DAC voltages into beam position.
--   - The timer overflow generates STOP, ending the draw phase.
--   - Normalization substates (matching hardware LS194 shift registers
--     clocked at 12 MHz with PROM frozen via SA, schematic p.24 Fig.0).
--   - VCTR uses 15-bit timer (0x8000 - hw_timer), SVEC uses 8-bit sub-timer (0x0100 - hw_timer[7:0]).
-- This module replaces the analog pipeline with digital accumulators.
--
-- ============================================================================
-- HARDWARE SIGNAL MAPPING
-- ============================================================================
--
--  Our Signal  | Hardware Equivalent           | Source/Destination
--  ------------|-------------------------------|-----------------------------
--  zero        | CENTER analog signal          | /CNTR AND /HALT (LS08 2H)
--              | (schematic p.24 Fig.4)        | -> LF13201 DAC pin 9/10
--              |                               | Resets integrators to center
--  draw        | STROBE3 + VCTR/CNTR set       | J-input of K2F JK-FF
--              | (schematic p.24 Fig.3/4)      | Sets GO flag, starts timer
--  done        | STOP (timer overflow)         | LS161 carry chain -> LS02 NOR
--              | (schematic p.25 Fig.0)        | K-input clears VCTR/CNTR
--  xpos/ypos   | Integrator output voltage     | TL082 op-amp (7A/8A)
--  normrel_x/y | DAC output × linear_scale     | AM6012 -> LF13201 (6A/7B)
--  hw_timer    | LS161 counter chain value     | 1D/1C/1B/2B cascaded counters
--
-- CENTER sets CNTR=1 -> GO=1, and /CENTER resets integrators. On hardware
-- the timer counts from the normalization fill value until overflow -> /STOP.
-- We model this as zero='1' + draw='1' arriving simultaneously:
--   - zero clears xpos/ypos (integrator reset)
--   - draw latches hw_timer and starts timer-based wait
--   - beam sits at center for the full timer duration
--
-- ============================================================================
-- 
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
-- 
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
-- 
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.





library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity vector_drawer is
    Port ( clk : in  STD_LOGIC;
           clk_ena: in STD_LOGIC;
           hw_timer : in  STD_LOGIC_VECTOR (14 downto 0);
           is_svec : in STD_LOGIC;
           linear_scale : in STD_LOGIC_VECTOR (7 downto 0);
           rel_x : in  STD_LOGIC_VECTOR (12 downto 0);
           rel_y : in  STD_LOGIC_VECTOR (12 downto 0);
           zero: in STD_LOGIC;
           draw : in  STD_LOGIC;
           done : out STD_LOGIC;
           is_dot : out STD_LOGIC;
           xout: out STD_LOGIC_VECTOR(13 downto 0);
           yout: out STD_LOGIC_VECTOR(13 downto 0)
     );
end vector_drawer;

architecture Behavioral of vector_drawer is
    -- Position accumulators: 34 bits = 2 extra sign/guard + 14 output (11 integer + 3 fraction) + 18 low sub-pixel.
    -- Output extraction at xpos(31:18), saturation checked via bits 33 and 32:31.
    signal xpos: STD_LOGIC_VECTOR(33 downto 0);
    signal ypos: STD_LOGIC_VECTOR(33 downto 0);
    signal normrel_x : STD_LOGIC_VECTOR (12 downto 0);
    signal normrel_y : STD_LOGIC_VECTOR (12 downto 0);
    -- Draw target in master clocks (12 MHz).
    -- VCTR (OP1=0): (0x8000 - hw_timer), up to 32768 master clocks
    -- SVEC (OP1=1): (0x100 - hw_timer[7:0]), up to 256 master clocks
    signal draw_target : STD_LOGIC_VECTOR (15 downto 0);
    signal itsdone: std_logic;
    signal draw_counter: STD_LOGIC_VECTOR(15 downto 0);  -- counts master clock
    -- Linear scale velocity multiplier (schematic p.26: LF13201 multiplying DAC).
    signal scale_factor : STD_LOGIC_VECTOR(8 downto 0);

    -- Scaled step signals (normrel x scale_factor)
    -- 13-bit signed x 9-bit unsigned = 23-bit signed product
    signal step_x_full : STD_LOGIC_VECTOR(22 downto 0);
    signal step_y_full : STD_LOGIC_VECTOR(22 downto 0);
begin

    -- Combinational flag ensures the effect tag is immediately available
    is_dot <= '1' when (rel_x = "0000000000000" and rel_y = "0000000000000") else '0';

    -- DAC transfer function: output = input × (N+1)/256, where N = NOT(linear_scale).
    -- Range: 1 (linear_scale=0xFF, near-zero) to 256 (linear_scale=0x00, max speed).
    scale_factor <= (('0' & (linear_scale xor x"FF")) + 1);

    -- Signed multiply: normrel (13-bit signed) x scale_factor (9-bit unsigned)
    step_x_full <= SIGNED(normrel_x) * UNSIGNED(scale_factor);
    step_y_full <= SIGNED(normrel_y) * UNSIGNED(scale_factor);

    -- Main clocked process: 3-state priority FSM
    process(clk)
    begin
        if clk'event and clk='1' then
            -- ── STATE: ZERO (Priority 1) ──────────────────────────
            -- Asserted by avg.vhd during: VGRST, halt, CENTER.
            -- /CENTER analog signal resets integrators (zero clears xpos/ypos),
            -- while CNTR=1 → GO=1 starts the timer (draw latches hw_timer).
            if zero='1' then
                xpos<=(others=>'0');
                ypos<=(others=>'0');
                if draw='1' then
                    -- CENTER: zero position AND start timer-based wait.
                    -- rel_x/rel_y are 0 (set by avg.vhd for CENTER).
                    normrel_x<=rel_x;
                    normrel_y<=rel_y;
                    if is_svec='1' then
                        draw_target <= x"0100" - (x"00" & hw_timer(7 downto 0));
                    else
                        draw_target <= x"8000" - ('0' & hw_timer);
                    end if;
                    draw_counter<=(others=>'0');
                    itsdone<='0';
                else
                    -- Pure zero (VGRST, halt): no draw, just clear.
                    normrel_x<=(others=>'0');
                    normrel_y<=(others=>'0');
                    draw_counter<=(others=>'0');
                    draw_target<=(others=>'0');
                    itsdone<='0'; -- enters DRAWING briefly (draw_target=0 -> resolves in 1 clk)
                end if;

            -- ── STATE: IDLE (Priority 2) ─────────────────────────
            -- itsdone='1': drawer is ready, waiting for draw pulse.
            -- draw='1': pulse from avg.vhd at STROBE3 (VCTR/SVEC).
            -- Latches normrel_x/y and computes draw_target from
            -- hw_timer. Transitions to DRAWING state.
            -- draw='0': stay IDLE, do nothing.
            elsif itsdone='1' then
                if draw='1' then
                    itsdone<='0';
                    normrel_x<=rel_x;
                    normrel_y<=rel_y;
                    if is_svec='1' then
                        -- SVEC: 8-bit sub-timer.
                        draw_target <= x"0100" - (x"00" & hw_timer(7 downto 0));
                    else
                        -- VCTR: full 15-bit timer.
                        draw_target <= x"8000" - ('0' & hw_timer);
                    end if;
                    draw_counter<=(others=>'0');
                end if;
            -- ── STATE: DRAWING (Priority 3, itsdone='0') ─────────
            -- draw_counter >= draw_target, transitions to IDLE.
            else
                if draw_counter >= draw_target then
                    itsdone<='1';
                else
                    -- Digital equivalent of analog integrator accumulation.
                    xpos<=xpos+sxt(step_x_full, xpos'length);
                    ypos<=ypos+sxt(step_y_full, ypos'length);
                end if;
                draw_counter <= draw_counter + 1;
            end if;
        end if;
    end process;
    done <= itsdone;

    -- Output extraction: xpos(31:21) = 11-bit signed integer, 20:18 = 3-bit fraction
    -- Total 14-bit output (31 downto 18).
    -- Guard-bit overflow: bit 33 = sign, bits 32:31 must all match sign for in-range.
    -- (Checking 32:31 so positions ±1024..±2047 are correctly saturated
    --  instead of wrapping the output through the sign boundary.)
    xout <= "01111111111000" when (xpos(33)='0' and xpos(32 downto 31) /= "00") else
            "10000000000000" when (xpos(33)='1' and xpos(32 downto 31) /= "11") else
            xpos(31 downto 18);

    yout <= "01111111111000" when (ypos(33)='0' and ypos(32 downto 31) /= "00") else
            "10000000000000" when (ypos(33)='1' and ypos(32 downto 31) /= "11") else
            ypos(31 downto 18);
end Behavioral;