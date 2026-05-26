# tms_clk constraint removed

# Our PLL outputs are in different clock domains (clk_50, clk_12, clk_108).
# The system SDC groups them together since they come from the same PLL.
# Explicitly declare them as asynchronous to each other.
# The CDC crossings are safe: control signals are quasi-static (OSD settings),
# and data paths use handshake protocols (DDRAM interface).

set emu_clk_50  [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set emu_clk_12  [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set emu_clk_108 [get_clocks {emu|pll|pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}]

# Cut timing between our three clock domains
set_clock_groups -asynchronous \
   -group $emu_clk_50 \
   -group $emu_clk_12 \
   -group $emu_clk_108
