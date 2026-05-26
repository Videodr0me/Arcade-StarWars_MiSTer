-- Draws vectors. Gets relative x and y directions and scale, and use these
-- to draw a vector from the starting point. It's supposed to be a workalike
-- for the Atari AVGs analog stuff plus timers plus normalizer, but this 
-- implementation differs from it quite a bit. If anything it means the timing
-- probably is way off... hope the software doesn't mind.

-- Black Widow arcade hardware implemented in an FPGA
-- (C) 2012 Jeroen Domburg (jeroen AT spritesmods.com)
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

-- MODIFICATION HISTORY (Videodr0me 2026, Star Wars MiSTer port):
--   1. Added linear_scale input: beam velocity multiplier (256 - linear_scale),
--      separated from timer threshold which now uses bin_scale only
--   2. Widened accumulators 26-bit -> 34-bit (26 integer + 8 fractional)
--      to preserve precision from the 13x9 signed velocity multiply
--   3. Widened output 10-bit -> 11-bit with guard-bit overflow saturation
--   4. Output extraction: xpos(30:20) / ypos(30:20) instead of xpos(22:13)


library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity vector_drawer is
    Port ( clk : in  STD_LOGIC;
           clk_ena: in STD_LOGIC;
           scale : in  STD_LOGIC_VECTOR (12 downto 0);
           linear_scale : in STD_LOGIC_VECTOR (7 downto 0);
           rel_x : in  STD_LOGIC_VECTOR (12 downto 0);
           rel_y : in  STD_LOGIC_VECTOR (12 downto 0);
           zero: in STD_LOGIC;
           draw : in  STD_LOGIC;
           done : out STD_LOGIC;
           xout : out  STD_LOGIC_VECTOR (10 downto 0);
           yout : out  STD_LOGIC_VECTOR (10 downto 0)
     );
end vector_drawer;

architecture Behavioral of vector_drawer is
    -- Position accumulators: 34 bits = 26 integer + 8 fractional.
    signal xpos: STD_LOGIC_VECTOR(33 downto 0);
    signal ypos: STD_LOGIC_VECTOR(33 downto 0);
    signal normrel_x : STD_LOGIC_VECTOR (12 downto 0);
    signal normrel_y : STD_LOGIC_VECTOR (12 downto 0);
    signal normscale : STD_LOGIC_VECTOR (12 downto 0);
    signal itsdone: std_logic;
    signal normsteps: STD_LOGIC_VECTOR(3 downto 0);
    signal timer: STD_LOGIC_VECTOR(16 downto 0);

    -- Linear scale velocity multiplier
    -- scale_factor = 256 - linear_scale (9-bit unsigned, range 1..256)
    signal scale_factor : STD_LOGIC_VECTOR(8 downto 0);

    -- Scaled step signals (normrel x scale_factor)
    -- 13-bit signed x 9-bit unsigned = 23-bit signed product
    signal step_x_full : STD_LOGIC_VECTOR(22 downto 0);
    signal step_y_full : STD_LOGIC_VECTOR(22 downto 0);
begin

    -- Linear scale velocity multiplier (combinatorial)
    scale_factor <= ("100000000") - ('0' & linear_scale);

    -- Signed multiply: normrel (13-bit signed) x scale_factor (9-bit unsigned)
    step_x_full <= SIGNED(normrel_x) * UNSIGNED(scale_factor);
    step_y_full <= SIGNED(normrel_y) * UNSIGNED(scale_factor);

    -- Main clocked process: iterative normalization + linear_scale multiply
    process(clk)
    begin
        if clk'event and clk='1' then
            if zero='1' then
                xpos<=(others=>'0');
                ypos<=(others=>'0');
                --Remain at (0,0) for a while to give the beam a chance to zero out.
                --Implemented by drawing a line with dx=dy=0.
                normsteps<="0000";
                normrel_x<=(others=>'0');
                normrel_y<=(others=>'0');
                timer<=(others=>'0');
                normscale<="0000010000000";
                itsdone<='0';
            elsif itsdone='1' then
                if draw='1' then
                    --restart drawing the vector
                    itsdone<='0';
                    normsteps<="1011"; -- 12-bit values can be shifted by 11 at most
                    normrel_x<=rel_x;
                    normrel_y<=rel_y;
                    normscale<=scale;
                    timer<=(others=>'0');
                end if;
            elsif normsteps/="0000" then
                --Normalize: shift coords left, scale right.
                if normrel_x(12)=normrel_x(11) and normrel_y(12)=normrel_y(11) and normscale(0)='0' then
                    normsteps<=normsteps-"0001";
                    normrel_x(12 downto 1)<=normrel_x(11 downto 0);
                    normrel_x(0)<='0';
                    normrel_y(12 downto 1)<=normrel_y(11 downto 0);
                    normrel_y(0)<='0';
                    normscale(11 downto 0)<=normscale(12 downto 1);
                    normscale(12)<='0';
                else
                    normsteps<="0000";
                end if;
            else
                if timer(16 downto 4)>=normscale then
                    itsdone<='1';
                else
                    -- Apply linear_scale as velocity multiplier.
                    -- Accumulate full 23-bit product into 34-bit xpos/ypos.
                    xpos<=xpos+sxt(step_x_full, xpos'length);
                    ypos<=ypos+sxt(step_y_full, ypos'length);
                    --timer<=timer+"00000000000000001";
                    --timer<=timer+"00000000000000010";
                    timer<=timer+"00000000000000100";
                end if;
            end if;
        end if;
    end process;
    done <= itsdone;

    -- Output extraction: xpos(30:20) = 11-bit signed output, 19:0 = sub-pixel
    -- Guard-bit overflow: bit 33 = sign, bits 32:30 must all match sign for in-range.
    -- (Checking 32:30, not just 32:31, so positions ±1024..±2047 are correctly saturated
    --  instead of wrapping the 11-bit output through the sign boundary.)
    xout <= "01111111111" when (xpos(33)='0' and xpos(32 downto 30) /= "000") else
            "10000000000" when (xpos(33)='1' and xpos(32 downto 30) /= "111") else
            xpos(30 downto 20);

    yout <= "01111111111" when (ypos(33)='0' and ypos(32 downto 30) /= "000") else
            "10000000000" when (ypos(33)='1' and ypos(32 downto 30) /= "111") else
            ypos(30 downto 20);
end Behavioral;