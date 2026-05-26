//===========================================================================
// Motorola 6809E FPGA Wrapper for Star Wars by Videodr0me 2026
// Based on Cavnex mc6809e Verilog Core (Greg Miller, 2014)
//===========================================================================
//
// This wrapper:
//   1. Generates quadrature E/Q clock enables from 12 MHz master clock
//   2. Latches combinatorial outputs at phase 1 to prevent glitches
//   3. Translates AVMA→VMA: forces VMA=1 on reads (original hardware
//      does not gate chip selects with AVMA, only with E clock)
//   4. Gates write strobe to second half of E cycle (phase_cnt[2]=1)

module cpu09 (
    input  wire        clk,      // Master clock input (12 MHz)
    input  wire        ce,       // Clock enable (1.5 MHz pulse)
    input  wire        rst,      // reset input (active high)
    output wire        vma,      
    output wire        lic_out,  
    output wire        ifetch,   
    output wire        opfetch,  
    output wire        ba,       
    output wire        bs,       
    output wire [15:0] addr,     
    output wire        rw,       
    output wire [7:0]  data_out, 
    input  wire [7:0]  data_in,  
    input  wire        irq,      
    input  wire        firq,     
    input  wire        nmi,      
    input  wire        halt      
);

    // Track the 8 phases between 'ce' pulses (12MHz / 8 = 1.5MHz)
    reg [2:0] phase_cnt;
    always @(posedge clk) begin
        if (ce) phase_cnt <= 3'd0;
        else    phase_cnt <= phase_cnt + 3'd1;
    end

    // Q leads E by 90 degrees.
    // E falls at the end of the cycle (ce is high at phase 7)
    // Q falls 2 ticks earlier (phase 5)
    wire ce_e_fall = ce | rst;
    wire ce_q_fall = (phase_cnt == 3'd5) | rst;

    wire nRESET = ~rst;
    wire nIRQ   = ~irq;
    wire nFIRQ  = ~firq;
    wire nNMI   = ~nmi;
    wire nHALT  = ~halt;

    wire [15:0] cpucore_addr;
    wire [7:0]  cpucore_data_out;
    wire        cpucore_rw;
    wire        cpucore_vma;
    wire        lic_w;
    wire        ba_w;
    wire        bs_w;

    mc6809e cpucore (
        .D        (data_in),
        .DOut     (cpucore_data_out),
        .ADDR     (cpucore_addr),
        .RnW      (cpucore_rw),
        .CLK_ROOT (clk),
        .CE_E_FALL(ce_e_fall),
        .CE_Q_FALL(ce_q_fall),
        .BS       (bs_w),
        .BA       (ba_w),
        .nIRQ     (nIRQ),
        .nFIRQ    (nFIRQ),
        .nNMI     (nNMI),
        .AVMA     (cpucore_vma),
        .BUSY     (),
        .LIC      (lic_w),
        .nHALT    (nHALT),
        .nRESET   (nRESET)
    );

    // The mc6809i core has combinatorial outputs. We wait until phase 1, when 
    // the combinatorial signals are fully settled, and latch them, so they 
    // remain stable for the entire 1.5MHz cycle.
    reg [15:0] safe_addr;
    reg [7:0]  safe_data;
    reg        safe_rw;
    reg        safe_vma;

    always @(posedge clk) begin
        if (rst) begin
            safe_addr <= 16'h0000;
            safe_data <= 8'h00;
            safe_rw   <= 1'b1;
            safe_vma  <= 1'b0;
        end else if (phase_cnt == 3'd1) begin
            safe_addr <= cpucore_addr;
            safe_data <= cpucore_data_out;
            safe_rw   <= cpucore_rw;
            // The core outputs AVMA (predictive: next cycle valid), not VMA
            // (current cycle valid). Force VMA=1 during reads to match the
            // original hardware where chip selects are not AVMA-gated.
            // Writes still respect AVMA to prevent spurious writes.
            safe_vma  <= cpucore_vma | cpucore_rw;
        end
    end

    assign addr     = safe_addr;
    assign data_out = safe_data;
    // Gate write strobe: force RW=1 (read) during first half of E cycle
    // (phase_cnt[2]=0, phases 0-3) so writes only assert in the second half
    // (phases 4-7), matching 6809E bus timing where write data is valid late.
    assign rw       = safe_rw | ~phase_cnt[2];
    assign vma      = safe_vma;

    assign ba       = ba_w;
    assign bs       = bs_w;
    assign lic_out  = lic_w;
    assign ifetch   = lic_w;
    assign opfetch  = lic_w;

endmodule

