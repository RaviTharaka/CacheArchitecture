`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: H.A.R.T Wijesekara
// 
// Create Date: 01/12/2017 12:45:35 PM
// Design Name: 
// Module Name: Test_Data_Cache
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

module Test_Data_Cache ();
    // Fixed parameters
    localparam ADDR_WIDTH = 32;
    localparam DATA_WIDTH = 32;
    
    // Primary parameters
    parameter S                 = 17;                    // Size of the cache will be 2^S bits
    parameter B                 = 9;                     // Size of a block will be 2^B bits
    parameter a                 = 1;                     // Associativity of the cache would be 2^a
    parameter T                 = 1;                     // Width to depth translation amount
    parameter W                 = 7;                     // Width of the L2-L1 bus would be 2^W
    parameter L2_DELAY          = 7;                     // Delay of the second level of cache
    parameter V                 = 2;                     // Size of the victim cache will be 2^V cache lines
            
    // Calculated parameters
    localparam L2_BUS_WIDTH     = 1 << W;
    localparam L2_BURST         = 1 << (B - W);
        
    // Constants
    reg                              TRUE = 1;
    reg                              FALSE = 0;    
        
    reg                              CLK;
    
    reg                              PROC_READY;
    wire                             CACHE_READY;
        
    wire [ADDR_WIDTH        - 3 : 0] RD_ADDR_TO_L2;
    wire                             RD_ADDR_TO_L2_READY;
    wire                             RD_ADDR_TO_L2_VALID;
        
    reg [L2_BUS_WIDTH       - 1 : 0] DATA_FROM_L2;
    reg                              DATA_FROM_L2_VALID;
    wire                             DATA_FROM_L2_READY;
    
    reg                              WR_TO_L2_READY;
    wire                             WR_TO_L2_VALID;
    wire [ADDR_WIDTH    - 2 - 1 : 0] WR_ADDR_TO_L2;
    wire [L2_BUS_WIDTH      - 1 : 0] DATA_TO_L2;
    wire                             WR_CONTROL_TO_L2;
    reg                              WR_COMPLETE;
      
    reg  [2                 - 1 : 0] CONTROL_FROM_PROC;              // CONTROL_FROM_PROC = {00(idle), 01(read), 10(write), 11(flush address from cache)}
    reg  [ADDR_WIDTH        - 1 : 0] ADDR_FROM_PROC;
    reg  [DATA_WIDTH        - 1 : 0] DATA_FROM_PROC;
    wire [DATA_WIDTH        - 1 : 0] DATA_TO_PROC;
              
    Data_Cache # (
        .S(S),
        .B(B),
        .a(a),
        .T(T),
        .W(W),
        .L2_DELAY(L2_DELAY),
        .V(V)
    ) uut (
        .CLK(CLK),
       // Ports towards the processor
        .CONTROL_FROM_PROC(CONTROL_FROM_PROC),              // CONTROL_FROM_PROC = {00(idle), 01(read), 10(write), 11(flush address from cache)}
        .ADDR_FROM_PROC(ADDR_FROM_PROC),
        .DATA_FROM_PROC(DATA_FROM_PROC),
        .DATA_TO_PROC(DATA_TO_PROC),
                
        .PROC_READY(PROC_READY),
        .CACHE_READY(CACHE_READY),
                
        // Ports towards the L2 cache
        .WR_TO_L2_READY(WR_TO_L2_READY),
        .WR_TO_L2_VALID(WR_TO_L2_VALID),
        .WR_ADDR_TO_L2(WR_ADDR_TO_L2),
        .DATA_TO_L2(DATA_TO_L2),
        .WR_CONTROL_TO_L2(WR_CONTROL_TO_L2),
        .WR_COMPLETE(WR_COMPLETE),
                
        .RD_ADDR_TO_L2_READY(RD_ADDR_TO_L2_READY),
        .RD_ADDR_TO_L2_VALID(RD_ADDR_TO_L2_READY),
        .RD_ADDR_TO_L2(RD_ADDR_TO_L2_READY),
                
        .DATA_FROM_L2_VALID(DATA_FROM_L2_VALID),
        .DATA_FROM_L2_READY(DATA_FROM_L2_READY),
        .DATA_FROM_L2(DATA_FROM_L2)       
    );
    
    integer fileTrace, readTrace;
    //integer fileResult, writeResult;
    integer i, j, k, l;
    integer instruction_no;
    
    reg read_address;
    initial begin
        CLK = 0;
        
        PROC_READY = 0;
        
        CONTROL_FROM_PROC = 0;              
        ADDR_FROM_PROC = 0;
        DATA_FROM_PROC = 0;
                    
        fileTrace = $fopen("E:/University/GrandFinale/Project/Simulation_Traces/Data_Cache/gcc.trac", "r");
        
        instruction_no = 0;
                
        #106;
        PROC_READY = 1;
        
        readTrace = $fscanf(fileTrace, "%x ", CONTROL_FROM_PROC);
        readTrace = $fscanf(fileTrace, "%x ", ADDR_FROM_PROC);
        readTrace = $fscanf(fileTrace, "%x ", DATA_FROM_PROC);
        #10;
        
        for (i = 0; i > -1; i = i + 1) begin
            if (read_address) begin
                readTrace = $fscanf(fileTrace, "%x ", CONTROL_FROM_PROC);
                readTrace = $fscanf(fileTrace, "%x ", ADDR_FROM_PROC);
                readTrace = $fscanf(fileTrace, "%x ", DATA_FROM_PROC);
                instruction_no = instruction_no + 1;
            end  
            #10;      
        end                
    end
    
    always @(posedge CLK) begin
        read_address <= CACHE_READY & PROC_READY;
    end
        
    always begin
        CLK = #5 !CLK;
    end
    
endmodule