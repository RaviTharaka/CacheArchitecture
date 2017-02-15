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
    parameter L2_DELAY_RD       = 7;                     // Read delay of the L2 cache (from start of request upto first reply)
    parameter L2_DELAY_WR       = 4;                     // Write delay of the L2 cache (from sending last data to WR_COMPLETE acknowledgement)
    parameter V                 = 2;                     // Size of the victim cache will be 2^V cache lines
            
    // Calculated parameters
    localparam L2_BUS_WIDTH     = 1 << W;
    localparam L2_BURST         = 1 << (B - W);
        
    // Constants
    reg                              TRUE  = 1;
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
    
    wire                             WR_TO_L2_READY;
    wire                             WR_TO_L2_VALID;
    wire [ADDR_WIDTH    - 2 - 1 : 0] WR_ADDR_TO_L2;
    wire [L2_BUS_WIDTH      - 1 : 0] DATA_TO_L2;
    wire                             WR_CONTROL_TO_L2;
    wire                             WR_COMPLETE;
      
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
        .L2_DELAY_RD(L2_DELAY_RD),
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
        .RD_ADDR_TO_L2_VALID(RD_ADDR_TO_L2_VALID),
        .RD_ADDR_TO_L2(RD_ADDR_TO_L2),
                
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
        l2_ready   = 1;
        
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
    
    ////////////////////////////////////////////////////////////
    //              Read port of L2 cache                     // 
    ////////////////////////////////////////////////////////////
    
    reg  [L2_BURST   - 1 : 0] l2_rd_input_state;
    
    reg                       rd_mem_requests  [0 : L2_DELAY_RD - 3];
    reg  [ADDR_WIDTH - 3 : 0] rd_mem_addresses [0 : L2_DELAY_RD - 3];
        
    reg  [ADDR_WIDTH - 1 : 0] rd_output_addr_reg   = 0;
    reg  [L2_BURST   - 1 : 0] rd_output_data_state = 0;
    reg                       l2_ready;
        
    assign RD_ADDR_TO_L2_READY = l2_ready & DATA_FROM_L2_READY;    
    
    always @(posedge CLK) begin
        if (DATA_FROM_L2_READY) begin
            rd_mem_requests[0]  <= RD_ADDR_TO_L2_VALID && RD_ADDR_TO_L2_READY;
            rd_mem_addresses[0] <= RD_ADDR_TO_L2;
            for (j = 1; j < L2_DELAY_RD; j = j + 1) begin
                rd_mem_requests[j]  <= rd_mem_requests[j - 1];
                rd_mem_addresses[j] <= rd_mem_addresses[j - 1];
            end
        
            if (RD_ADDR_TO_L2_VALID && RD_ADDR_TO_L2_READY) begin
                l2_ready       <= 0;
                l2_rd_input_state <= 1;           
            end else if (l2_rd_input_state != 0) begin
                l2_rd_input_state <= l2_rd_input_state << 1;
            end
            
            if(l2_rd_input_state[L2_BURST - 2]) begin
                l2_ready       <= 1;
            end
            
            if (rd_mem_requests[L2_DELAY_RD - 3]) begin
                rd_output_addr_reg    <= {rd_mem_addresses[L2_DELAY_RD - 3], 2'b00};
                rd_output_data_state  <= 1;
            end else if (rd_output_data_state != 0) begin
                rd_output_data_state  <= rd_output_data_state << 1;
            end
            
            if (rd_output_data_state != 0) begin            
                DATA_FROM_L2_VALID <= 1;
            end else begin
                DATA_FROM_L2_VALID <= 0;
            end
            
            for (k = 0; k < L2_BURST; k = k + 1) begin
                if (rd_output_data_state[k] == 1) begin
                    for (l = 0; l < (1 << W - 5); l = l + 1) begin
                        DATA_FROM_L2[l * DATA_WIDTH         +:                    2] <= 2'b00;
                        DATA_FROM_L2[l * DATA_WIDTH + 2     +:                W - 5] <= l;
                        DATA_FROM_L2[l * DATA_WIDTH + W - 3 +:                B - W] <= {rd_output_addr_reg[2 + W + T - 5 +: B - W - T], {(B - W - T){1'b0}} }+ k;
                        DATA_FROM_L2[l * DATA_WIDTH + B - 3 +: (ADDR_WIDTH + 3 - B)] <= rd_output_addr_reg[ADDR_WIDTH - 1 : B - 3];
                        //{rd_output_addr_reg[2 + W - 5 +: B - W] + k;
                    end
                end
            end
        end      
    end
    
    ////////////////////////////////////////////////////////////
    //              Write port of L2 cache                    // 
    ////////////////////////////////////////////////////////////
    
    integer writeFile;
    
    reg  [L2_DELAY_WR + L2_BURST  - 1 : 0] l2_wr_input_state = 1;
    
    assign WR_TO_L2_READY = |(l2_wr_input_state[L2_BURST - 1 : 0]); 
    assign WR_COMPLETE    = l2_wr_input_state[L2_DELAY_WR + L2_BURST  - 1];
    
    always @(posedge CLK) begin
        if (WR_TO_L2_READY) begin
            if (WR_TO_L2_VALID) begin
                l2_wr_input_state <= l2_wr_input_state << 1;
                writeFile = $fopen("E:/University/GrandFinale/Project/Simulation_Traces/Data_Cache/Output.trac", "a");
                $fwrite("%d \t %d \t%d \n", WR_ADDR_TO_L2, DATA_TO_L2, WR_CONTROL_TO_L2);  
                $fclose(writeFile);      
            end    
        end else begin
            if (l2_wr_input_state[L2_DELAY_WR + L2_BURST  - 1]) begin
                l2_wr_input_state <= 1;
            end else begin
                l2_wr_input_state <= l2_wr_input_state << 1;
            end
        end
    end
     
    always begin
        CLK = #5 !CLK;
    end
    
endmodule