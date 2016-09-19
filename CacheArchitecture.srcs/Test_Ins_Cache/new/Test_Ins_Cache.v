`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: H.A.R.T Wijesekara
// 
// Create Date: 07/29/2016 12:45:35 PM
// Design Name: 
// Module Name: Test_Ins_Cache
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

module Test_Ins_Cache ();
    // Fixed parameters
    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 32;
    
    // Primary parameters
    parameter S = 17;                    // Size of the cache will be 2^S bits
    parameter B = 9;                     // Size of a block will be 2^B bits
    parameter a = 1;                     // Associativity of the cache would be 2^a
    parameter T = 3;                     // Width to depth translation amount
    parameter W = 7;                     // Width of the L2-L1 bus would be 2^W
        
    parameter L2_DELAY = 7;
    
    // Calculated parameters
    localparam L2_BUS_WIDTH = 1 << W;
    localparam L2_BURST = 1 << (B - W);
        
    // Constants
    reg TRUE = 1;
    reg FALSE = 0;    
        
    reg CLK;
    reg RSTN;
    
    reg [ADDR_WIDTH - 1 : 0] BRANCH_ADDR_IN;
    reg BRANCH;
    wire [DATA_WIDTH - 1 : 0] DATA_TO_PROC;
    reg PROC_READY;
    wire CACHE_READY;
        
    wire [ADDR_WIDTH - 3 : 0] ADDR_TO_L2;
    reg ADDR_TO_L2_READY;
    wire ADDR_TO_L2_VALID;
        
    reg [L2_BUS_WIDTH - 1 : 0] DATA_FROM_L2;
    reg DATA_FROM_L2_VALID;
    wire DATA_FROM_L2_READY;
        
    Ins_Cache # (
        .S(S),
        .B(B),
        .a(a),
        .T(T),
        .W(W)
    ) uut (
        .CLK(CLK),
        .RSTN(RSTN),
        
        .BRANCH_ADDR_IN(BRANCH_ADDR_IN),
        .BRANCH(BRANCH),
        .DATA_TO_PROC(DATA_TO_PROC),
        .CACHE_READY(CACHE_READY),
        .PROC_READY(PROC_READY),
                
        .ADDR_TO_L2(ADDR_TO_L2),
        .ADDR_TO_L2_READY(ADDR_TO_L2_READY),
        .ADDR_TO_L2_VALID(ADDR_TO_L2_VALID),
        
        .DATA_FROM_L2(DATA_FROM_L2),
        .DATA_FROM_L2_VALID(DATA_FROM_L2_VALID),
        .DATA_FROM_L2_READY(DATA_FROM_L2_READY)
    );
    
    integer fileTrace, readTrace;
    integer i, j, k, l;
    
    
    initial begin
        CLK = 0;
        RSTN = 0;
        PROC_READY = 0;
        BRANCH = 0;
        ADDR_TO_L2_READY = 1;
        fileTrace = $fopen("K:/University/GrandFinale/Project/Simulation_Traces/Instruction_Cache/trace.txt", "r");
        
        #106;
        RSTN = 1;
        PROC_READY = 1;
        BRANCH = 1;
        readTrace = $fscanf(fileTrace, "%x ", BRANCH_ADDR_IN);
        #10;
        for (i = 0; i < 1000; i = i + 1) begin
            if (CACHE_READY & PROC_READY) begin
                readTrace = $fscanf(fileTrace, "%x ", BRANCH_ADDR_IN);
            end
            #10;
        end 
        
    end
    
    wire [ADDR_WIDTH - 1 : 0] output_addr;
    
    reg l2_read [0 : L2_DELAY - 1];
    reg [L2_BURST - 1 : 0] l2_input_state;
    
    wire fifo_empty;    
    reg mem_requests [0 : L2_DELAY - 3];
    reg [ADDR_WIDTH - 3 : 0] mem_addresses [0 : L2_DELAY - 3];
        
    reg [ADDR_WIDTH - 1 : 0] output_addr_reg = 0;
    reg [L2_BURST - 1 : 0] output_data_state = 0;
        
    always @(posedge CLK) begin
        mem_requests[0] <= ADDR_TO_L2_VALID && ADDR_TO_L2_READY;
        mem_addresses[0] <= ADDR_TO_L2;
        for (j = 1; j < L2_DELAY; j = j + 1) begin
            mem_requests[j] <= mem_requests[j - 1];
            mem_addresses[j] <= mem_addresses[j - 1];
        end
        
        if (ADDR_TO_L2_VALID && ADDR_TO_L2_READY) begin
            ADDR_TO_L2_READY <= 0;
            l2_input_state <= 1;           
        end else if (l2_input_state != 0) begin
            l2_input_state <= l2_input_state << 1;
        end
        
        if(l2_input_state[L2_BURST - 2]) begin
            ADDR_TO_L2_READY <= 1;
        end
        
        if (mem_requests[L2_DELAY - 3]) begin
            output_addr_reg <= {mem_addresses[L2_DELAY - 3], 2'b00};
            output_data_state <= 1;
        end else if (output_data_state != 0) begin
            output_data_state <= output_data_state << 1;
        end
        
        if (output_data_state != 0) begin            
            DATA_FROM_L2_VALID <= 1;
        end else begin
            DATA_FROM_L2_VALID <= 0;
        end
        
        for (k = 0; k < L2_BURST; k = k + 1) begin
            if (output_data_state[k] == 1) begin
                for (l = 0; l < (1 << W - 5); l = l + 1) begin
                    DATA_FROM_L2[l * DATA_WIDTH +: 2] <= 2'b00;
                    DATA_FROM_L2[l * DATA_WIDTH + 2 +: W - 5] <= l;
                    DATA_FROM_L2[l * DATA_WIDTH + W - 3 +: B - W] <= output_addr_reg[2 + W - 5 +: B - W] + k;
                    DATA_FROM_L2[l * DATA_WIDTH + B - 3 +: (ADDR_WIDTH + 3 - B)] <= output_addr_reg[ADDR_WIDTH - 1 : B - 3];
                end
            end
        end
        
    end
    
    always begin
        CLK = #5 !CLK;
    end
    
endmodule