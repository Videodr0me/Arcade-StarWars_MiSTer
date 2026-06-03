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
-- Modified for Star Wars Arcade MiSTer by Videodr0me 2026
-- Refactor Applied:
--   1. Synthesis Fix: Separated read (combinational) and write (synchronous) processes to stop latch inference.
--   2. Timer 1T Fix: Decoupled 1T decrement state from the IRQ flag.
--   3. PA7: Added a 3-stage synchronizer chain for edge detection.
--   4. PA7: Only sets the flag if it evaluates true against the CURRENT active polarity.
--   5. PA7: Interrupt clears on Edge Control Register writes OR Interrupt reads.
--
-- Reference: MOS 6532 datasheet, mos6532_device, Stella M6532, MAME

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
    type ram_type is array (0 to 2**addr_width - 1) of std_logic_vector(7 downto 0);
    signal ram: ram_type;
begin
    process (clk)
    begin
        if rising_edge(clk) then
            d_out <= ram(to_integer(unsigned(a)));
            if (we = '1') then
                ram(to_integer(unsigned(a))) <= d_in;
            end if;
        end if;
    end process;
end arch;

-------------------------------------------------------------------------------

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
    signal timer_underflow: std_logic := '0'; -- Decouples 1T logic from interrupt flag
    signal timer_intvl: std_logic_vector(1 downto 0) := "11";
    signal timer_dvdr: std_logic_vector(10 downto 0) := "00000000001";
    signal timer_inc: std_logic;
    signal timer_irq_en: std_logic := '0';

    signal edge_pol: std_logic := '0';
    signal edge_irq_en: std_logic := '0';
    signal edge_intr: std_logic := '0';
    signal pa7_sync: std_logic_vector(2 downto 0) := "000"; -- sync chain

    signal intr_read: std_logic;
    signal edge_write: std_logic;

    signal ram_d_out: std_logic_vector(7 downto 0);
    signal ram_we: std_logic;

begin

    -- I/O Ports
    io: for i in 0 to 7 generate
        pa_out(i) <= pa_reg(i);
        pb_out(i) <= pb_reg(i);
        pa_read(i) <= pa_in(i) when pa_ddr(i) = '0' else pa_reg(i);
        pb_read(i) <= pb_in(i) when pb_ddr(i) = '0' else pb_reg(i);
    end generate;

    -- Local RAM
    ram: entity work.ramx8 port map(clk, ram_we, d_in, ram_d_out, a);

    -- Internal Decoding Signals
    ram_we      <= (not r) and (not rs) and cs and ph2_en;
    timer_write <= (not r) and rs and a(2) and a(4) and cs;
    timer_read  <= r and rs and a(2) and (not a(0)) and cs;
    intr_read   <= r and rs and a(0) and a(2) and cs;
    edge_write  <= (not r) and rs and a(2) and (not a(4)) and cs;

    -- Active-Low Open-Drain-Style IRQ
    irq <= not ((timer_intr and timer_irq_en) or (edge_intr and edge_irq_en));


    -- PROCESS 1: Combinational CPU Reads
    process(cs, r, rs, a, ram_d_out, pa_read, pa_ddr, pb_read, pb_ddr, timer, timer_intr, edge_intr)
    begin
        d_out <= "00000000"; -- Default prevents hardware latches when reading isn't active
        if (r = '1' and cs = '1') then
            if rs = '0' then
                d_out <= ram_d_out;
            elsif a(2) = '0' then
                case a(1 downto 0) is
                    when "00" => d_out <= pa_read;
                    when "01" => d_out <= pa_ddr;
                    when "10" => d_out <= pb_read;
                    when "11" => d_out <= pb_ddr;
                    when others => null;
                end case;
            elsif a(0) = '0' then
                d_out <= timer;
            elsif a(0) = '1' then
                d_out <= timer_intr & edge_intr & "000000";
            end if;
        end if;
    end process;

    -- PROCESS 2: Synchronous Writes for I/O & Configuration
    process(clk)
    begin
        if rising_edge(clk) then
            if (cs = '1' and ph2_en = '1' and r = '0' and rs = '1') then
                if a(2) = '0' then
                    case a(1 downto 0) is
                        when "00" => pa_reg <= d_in;
                        when "01" => pa_ddr <= d_in;
                        when "10" => pb_reg <= d_in;
                        when "11" => pb_ddr <= d_in;
                        when others => null;
                    end case;
                elsif a(4) = '0' then
                    edge_pol <= a(0);
                    edge_irq_en <= a(1);
                end if;
            end if;
        end if;
    end process;


    -- PROCESS 3: PA7 Edge Detection
    process(clk)
    begin
        if rising_edge(clk) then
            -- 3-stage synchronizer steps async PA7 into the clk domain
            pa7_sync <= pa7_sync(1 downto 0) & pa7;
            
            -- CPU actions (clearing the flag) happen on the CPU clock enable
            if (ph2_en = '1' and (intr_read = '1' or edge_write = '1')) then
                edge_intr <= '0';
            end if;

            -- Hardware edge detection runs continuously at the master clock rate.
            -- Because this appears AFTER the CPU clear condition, a hardware edge
            -- that coincides with a CPU clear will take priority.
            if (edge_pol = '1' and pa7_sync(2) = '0' and pa7_sync(1) = '1') then
                edge_intr <= '1'; -- Rising edge
            elsif (edge_pol = '0' and pa7_sync(2) = '1' and pa7_sync(1) = '0') then
                edge_intr <= '1'; -- Falling edge
            end if;
        end if;
    end process;


    -- PROCESS 4: Timer Countdown & Flags    
    -- Timer Prescaler Mux
    with timer_intvl select timer_inc <=
        timer_dvdr(0)  when "00", -- /1
        timer_dvdr(3)  when "01", -- /8
        timer_dvdr(6)  when "10", -- /64
        timer_dvdr(10) when "11", -- /1024
        '-' when others;

    process(clk)
    begin
        if rising_edge(clk) then
            if ph2_en = '1' then
                
                -- Prescaler Counter
                if (timer_inc = '1') then
                    timer_dvdr <= "00000000001";
                else
                    timer_dvdr <= timer_dvdr + 1;
                end if;

                -- Timer Value Arithmetic
                if (timer_write = '1') then
                    timer <= d_in - 1;
                    timer_intvl <= a(1 downto 0);
                    timer_dvdr <= "00000000001";
                    timer_underflow <= '0';       -- Reset back to prescaler mode
                elsif (timer_underflow = '0') then
                    timer <= timer - timer_inc;   -- Prescaler mode subtraction active
                else
                    timer <= timer - 1;           -- 1T Post-underflow subtraction active
                end if;

                -- Quirk: IRQ Enable flag updates whenever the CPU Writes AND Reads the timer (A3 behavior)
                if (timer_write = '1' or timer_read = '1') then
                    timer_irq_en <= a(3);
                end if;

                -- CPU Flag Clearing
                if (timer_read = '1' or timer_write = '1') then
                    timer_intr <= '0';            -- Clear interrupt flag (timer_underflow is NOT cleared!)
                end if;

                -- Interrupt / 1T Activation Handling
                -- Placed after clear to prevent lost timeouts during reads
                if (timer = X"00" and timer_inc = '1' and timer_underflow = '0' and timer_write = '0') then
                    timer_intr <= '1';            -- Flag the CPU
                    timer_underflow <= '1';       -- Enter 1T continuous decrement mode
                end if;

            end if;
        end if;
    end process;

end arch;