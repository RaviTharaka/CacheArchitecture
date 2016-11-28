`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/21/2016 02:50:52 PM
// Design Name: 
// Module Name: Ins_Cache_Control
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////


module Ins_Cache_Control #(
        // Fixed parameters
        localparam ADDR_WIDTH = 32,
        localparam DATA_WIDTH = 32,
        
        // Primary parameters
        parameter S         = 17,                    // Size of the cache will be 2^S bits
        parameter B         = 9,                     // Size of a block will be 2^B bits
        parameter a         = 1,                     // Associativity of the cache would be 2^a
        parameter T         = 3,                     // Width to depth translation amount
        parameter N         = 3,                     // Number of stream buffers
        parameter W         = 7,                     // Width of the L2-L1 bus would be 2^W
        parameter L2_DELAY  = 5,                     // Delay of the second level of cache
                
        // Calculated parameters        
        localparam ASSOCIATIVITY = 1 << a,
        localparam TAG_WIDTH = ADDR_WIDTH + 3 + a - S,
        
        localparam TAG_RAM_WIDTH = TAG_WIDTH + 1,
        localparam LINE_RAM_WIDTH   = 1 << (B - T),
        localparam L2_BUS_WIDTH     = 1 << W
    ) (
        input CLK,
        input RSTN,
        
        // Cache hit status
        input CACHE_HIT,
        input BRANCH,
        
        // Addr_to_L2 section status
        input PC_DEL_1_EQUALS_2,                                    // Whether PC[t-2] == PC[t-1]
        input PC_DEL_0_EQUALS_2,                                    // Whether PC[t-2] == PC[t]
        output SEND_ADDR_TO_L2,                                     // Instucts Addr_To_L2 section to sample the PC[t-2] register
        
        // Processor cache communications
        output CACHE_READY,                                         // Signal from cache to processor that its pipeline is currently ready to work
        input PROC_READY,                                           // Signal from processor to cache that its pipeline is currently ready to work
                
        // Multiplexer selects
        output [1 : 0] PC_SEL,                                       // Mux select for PC [pc_sel = {0(PC+4), 1 (Delayed PC), 2or3 (Branch path)}]
        output [1 : 0] ADDR_TO_L2_SEL,                               // Mux select for ADDR_TO_L2 [addr_to_L2_sel = {0 or 1(Delayed PC), 2(Prefetch queue), 3(Fetch queue)}]
        output [1 : 0] LIN_MEM_DATA_IN_SEL,                          // Mux select for line RAM input [lin_mem_data_in_sel = {0(direct path), x (xth stream buffer)}]
        
        // Pipeline enable signals
        output CACHE_PIPE_ENB,                                              // Enable for cache's pipeline registers
        output PC_PIPE_ENB,                                                 // Enable for PC's pipeline registers
        output DATA_TO_PROC_ENB,                                            // Enable signal for the IR register
        
        // Tag memory control signals
        output TAG_MEM_RD_ENB,                                       // Common read enable for the tag memories
        output [ASSOCIATIVITY - 1 : 0] TAG_MEM_WR_ENB,               // Individual write enables for the tag memories
        output [S - a - B     - 1 : 0] TAG_MEM_WR_ADDR,              // Common write address for the the tag memories 
        output [TAG_RAM_WIDTH - 1 : 0] TAG_MEM_DATA_IN,              // Common data in for the tag memories
        
        // Line memory control signals
        output LIN_MEM_RD_ENB,                                       // Common read enables for the line memories
        output LIN_MEM_OUT_ENB,                                      // Common output register enable for the line memories
        output [ASSOCIATIVITY - 1 : 0] LIN_MEM_WR_ENB,               // Individual write enables for the line memories
        output [S - a - B + T  - 1 : 0] LIN_MEM_WR_ADDR,             // Common write address for the line memories
        
        // Ongoing queue control signals
        input ONGOING_QUEUE_EMPTY,
        input ONGOING_QUEUE_FULL
    );
    
    assign DATA_TO_PROC_ENB = CACHE_HIT;
    assign PC_SEL[1] = BRANCH;
    assign PC_SEL[0] = !CACHE_HIT;
    assign PC_PIPE_ENB = 1;
    assign CACHE_PIPE_ENB = 1;
    assign LIN_MEM_RD_ENB = 1;
    assign LIN_MEM_OUT_ENB = 1;
    assign TAG_MEM_RD_ENB = 1;
        
    // FSM for the overall control of the cache
    localparam HITTING = 8'd1, M = 8'd2, MM = 8'd4, MH = 8'd8, MMM = 8'd16, MMH = 8'd32, MHM = 8'd64, MHH = 8'd128;
    reg [7 : 0] state = 8'd0;
    
    // Controlling Addr_To_L2 section
    reg send_addr_to_L2;
    assign SEND_ADDR_TO_L2 = !CACHE_HIT & send_addr_to_L2;
    reg pc_del_1_equals_2_reg;
    reg pc_del_0_equals_2_reg;
        
    initial begin
        pc_del_1_equals_2_reg = 0;
        pc_del_0_equals_2_reg = 0;
        send_addr_to_L2 = 1;
        state = HITTING;
    end    
        
    always @(posedge CLK) begin
        case (state)
            HITTING : begin
                if (CACHE_HIT) begin
                    state <= HITTING;
                    send_addr_to_L2 <= 1'd1;
                end else begin   
                    state <= M;
                    send_addr_to_L2 <= !PC_DEL_1_EQUALS_2;
                    pc_del_1_equals_2_reg <= PC_DEL_1_EQUALS_2;
                    pc_del_0_equals_2_reg <= PC_DEL_0_EQUALS_2;
                end    
            end
            M : begin
                if (CACHE_HIT) begin
                    state <= MH;
                    send_addr_to_L2 <= !pc_del_1_equals_2_reg & !pc_del_0_equals_2_reg;
                end else begin
                    state <= MM;
                    send_addr_to_L2 <= !pc_del_1_equals_2_reg & !pc_del_0_equals_2_reg;
                end    
            end
            MH : begin
                if (CACHE_HIT) begin
                    state <= MHH;
                    send_addr_to_L2 <= 1'd0;
                end else begin
                    state <= MHM;
                    send_addr_to_L2 <= 1'd0;
                end    
            end    
            MM : begin
                if (CACHE_HIT) begin
                    state <= MMH;
                    send_addr_to_L2 <= 1'd0;
                end else begin
                    state <= MMM;
                    send_addr_to_L2 <= 1'd0;
                end    
            end    
        endcase            
    end
    
    
endmodule
