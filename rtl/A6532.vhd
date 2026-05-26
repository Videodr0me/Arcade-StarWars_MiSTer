-- A6532 RAM-I/O-Timer (RIOT)
-- Copyright 2006, 2010 Retromaster
--
--  This file is part of A2601.
--
--  A2601 is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 3 of the License,
--  or any later version.
--
--  A2601 is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with A2601.  If not, see <http://www.gnu.org/licenses/>.
--
-- Modified for Star Wars Arcade MiSTer by Videodr0me 2026
-- Changes from original Retromaster A2601 implementation:
--   1. Fixed PA7 polarity mapping (was inverted: A0=0 triggered rising instead of falling)
--   2. Fixed post-timeout timer: now continues at 1T rate (was frozen at $00)
--   3. PA7 edge detection runs at master clock for metastability protection
--   4. Removed timer d_in-1 init bug (off-by-one; writing 0 gave 256-cycle timeout)
--
-- Star Wars PCB context (SP-225 Sheet 15B, Sound PCB):
--   Port A: PA7=Sound Latch Full, PA6=Main Latch Full, PA2=TMS5220 /READY
--           PA1/PA0=TMS5220 /RS and /WS (directly from riot_pa_out)
--   Port B: Directly connected to TMS5220 data bus (D0-D7)
--   IRQ:    Directly wired to Audio 6809 CPU /IRQ line
--
-- Reference: MOS 6532 datasheet, MAME mos6532_device, Stella M6532

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ramx8 is
    generic(addr_width : integer := 7);
    port(clk: in std_logic;
         we: in std_logic;
         d_in: in std_logic_vector(7 downto 0);
         d_out: out std_logic_vector(7 downto 0);
         a: in std_logic_vector(addr_width - 1 downto 0));
end ramx8;

architecture arch of ramx8 is
    type ram_type is array (0 to 2**addr_width - 1) of
        std_logic_vector(7 downto 0);
    signal ram: ram_type;
begin

    process (clk)
    begin
        if (clk'event and clk = '1') then
            d_out <= ram(to_integer(unsigned(a)));
            if (we = '1') then
                ram(to_integer(unsigned(a))) <= d_in;
            end if;
        end if;
    end process;

end arch;

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity A6532 is
    port(clk: in std_logic;
         ph2_en: in std_logic;
         r: in std_logic;
         rs: in std_logic;
         cs: in std_logic;
         irq: out std_logic;
         d_in: in std_logic_vector(7 downto 0);
         d_out: out std_logic_vector(7 downto 0);
         pa_in: in std_logic_vector(7 downto 0);
         pa_out: out std_logic_vector(7 downto 0);
         pb_in: in std_logic_vector(7 downto 0);
         pb_out: out std_logic_vector(7 downto 0);
         pa7: in std_logic;
         a: in std_logic_vector(6 downto 0));
end A6532;

architecture arch of A6532 is

    signal pa_reg: std_logic_vector(7 downto 0) := "00000000";
    signal pb_reg: std_logic_vector(7 downto 0) := "00000000";
    signal pa_ddr: std_logic_vector(7 downto 0) := "00000000";
    signal pb_ddr: std_logic_vector(7 downto 0) := "00000000";
    
    signal pa_read: std_logic_vector(7 downto 0);
    signal pb_read: std_logic_vector(7 downto 0);

    signal timer: std_logic_vector(7 downto 0) := "00000000";
    signal timer_write: std_logic;
    signal timer_read: std_logic;
    signal timer_intr: std_logic := '0';
    signal timer_intvl: std_logic_vector(1 downto 0) := "11";
    signal timer_dvdr: std_logic_vector(10 downto 0) := "00000000001";
    signal timer_inc: std_logic;
    signal timer_irq_en: std_logic := '0';

    signal edge_pol: std_logic := '0';
    signal edge_irq_en: std_logic := '0';
    signal edge_intr_lo: std_logic := '0';
    signal edge_intr_hi: std_logic := '0';
    signal edge_intr: std_logic;

    signal intr_read: std_logic;

    signal ram_d_out: std_logic_vector(7 downto 0);
    signal ram_we: std_logic;
    signal pa7_last: std_logic := '0';

begin

    io: for i in 0 to 7 generate
        pa_out(i) <= pa_reg(i);
        pb_out(i) <= pb_reg(i);
        pa_read(i) <= pa_in(i) when pa_ddr(i) = '0' else pa_reg(i);
        pb_read(i) <= pb_in(i) when pb_ddr(i) = '0' else pb_reg(i);
    end generate;

    ram: entity work.ramx8 port map(clk, ram_we, d_in, ram_d_out, a);

    ram_we <= '1' when (rs = '0' and r = '0' and cs = '1' and ph2_en = '1') else '0';

    timer_write <= (not r) and rs and a(2) and a(4) and cs;
    timer_read <= r and rs and a(2) and (not a(0)) and cs;
    intr_read <=  r and rs and a(0) and a(2) and cs;

    irq <= not ((timer_intr and timer_irq_en) or (edge_intr and edge_irq_en));
    edge_intr <= edge_intr_hi when edge_pol = '0' else edge_intr_lo;

    process(clk, ph2_en, cs, r, rs, a, ram_d_out, pa_read, pa_ddr, pb_read, pb_ddr, timer, timer_intr, edge_intr)
    begin
        if r = '1' then
            if (cs = '0') then
                d_out <= "00000000";
            elsif rs = '0' then
                d_out <= ram_d_out;
            elsif a(2) = '0' then
                case a(1 downto 0) is
                    when "00" =>
                        d_out <= pa_read;
                    when "01" =>
                        d_out <= pa_ddr;
                    when "10" =>
                        d_out <= pb_read;
                    when "11" =>
                        d_out <= pb_ddr;
                    when others =>
                        null;
                end case;
            elsif a(0) = '0' then
                d_out <= timer;
            elsif a(0) = '1' then
                d_out <= timer_intr & edge_intr & "000000";
            else
                d_out <= "00000000";
            end if;
        else
            d_out <= "00000000";
            if (clk'event and clk = '1' and cs = '1' and ph2_en = '1') then
                if (rs = '1') then
                    if a(2) = '0' then
                        case a(1 downto 0) is
                            when "00" =>
                                pa_reg <= d_in;
                            when "01" =>
                                pa_ddr <= d_in;
                            when "10" =>
                                pb_reg <= d_in;
                            when "11" =>
                                pb_ddr <= d_in;
                            when others =>
                                null;
                        end case;
                    elsif a(4) = '0' then
                        edge_pol <= a(0);
                        edge_irq_en <= a(1);
                    end if;
                end if;
            end if;
        end if;
    end process;

    process(clk)
    begin
        if (clk'event and clk = '1') then
            pa7_last <= pa7;
            
            if (ph2_en = '1' and intr_read = '1') then
                edge_intr_lo <= '0';
            elsif (pa7 = '1' and pa7_last = '0') then
                edge_intr_lo <= '1';
            end if;

            if (ph2_en = '1' and intr_read = '1') then
                edge_intr_hi <= '0';
            elsif (pa7 = '0' and pa7_last = '1') then
                edge_intr_hi <= '1';
            end if;
        end if;
    end process;

    with timer_intvl select timer_inc <=
        timer_dvdr(0) when "00",
        timer_dvdr(3) when "01",
        timer_dvdr(6) when "10",
        timer_dvdr(10) when "11",
        '-' when others;

    process(clk, ph2_en)
    begin
        if (clk'event and clk = '1' and ph2_en = '1') then
            if (timer_inc = '1') then
                timer_dvdr <= "00000000001";
            else
                timer_dvdr <= timer_dvdr + 1;
            end if;

            if (timer_write = '1') then
                timer <= d_in;
                timer_intvl <= a(1 downto 0);
                timer_irq_en <= a(3);
                timer_dvdr <= "00000000001";
            elsif (timer_intr = '0') then
                timer <= timer - timer_inc;
            else
                timer <= timer - 1;
            end if;

            if (timer = X"00" and timer_inc = '1' and timer_intr = '0' and timer_write = '0') then
                timer_intr <= '1';
            elsif (timer_read = '1' or timer_write = '1') then
                timer_intr <= '0';
            end if;
        end if;
    end process;

end arch;
