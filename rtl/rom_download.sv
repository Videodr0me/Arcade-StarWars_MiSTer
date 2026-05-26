module rom_download #(
    parameter ADDR_WIDTH = 10
) (
    input clk,
    
    // Download Port (active during ROM loading)
    input  [ADDR_WIDTH-1:0] dn_addr,
    input             [7:0] dn_data,
    input                   dn_wr,
    
    // CPU Port A (Read-only)
    input  [ADDR_WIDTH-1:0] cpu_addr_a,
    output reg        [7:0] cpu_dout_a,

    // CPU Port B (Read-only)
    input  [ADDR_WIDTH-1:0] cpu_addr_b,
    output reg        [7:0] cpu_dout_b
);

    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] rom [0:(1<<ADDR_WIDTH)-1];

    // Port A: Download write OR CPU read A
    // Since the CPU is in reset during download, we can safely multiplex
    // the address of Port A. This keeps it down to 2 physical ports total!
    always @(posedge clk) begin
        if (dn_wr) begin
            rom[dn_addr] <= dn_data;
            cpu_dout_a <= rom[dn_addr];
        end else begin
            cpu_dout_a <= rom[cpu_addr_a];
        end
    end

    // Port B: CPU read B only
    always @(posedge clk) begin
        cpu_dout_b <= rom[cpu_addr_b];
    end

endmodule