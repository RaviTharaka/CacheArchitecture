`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: University of Moratuwa
// Engineer: Ravi Tharaka
// 
// Create Date: 12/28/2016 12:30:04 PM
// Design Name: 
// Module Name: Data_Cache
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


module Data_Cache #(
        // Fixed parameters
        localparam ADDR_WIDTH       = 32,
        localparam DATA_WIDTH       = 32,
        
        // Primary parameters
        parameter S                 = 17,                    // Size of the cache will be 2^S bits
        parameter B                 = 9,                     // Size of a block will be 2^B bits
        parameter a                 = 1,                     // Associativity of the cache would be 2^a
        parameter T                 = 1,                     // Width to depth translation amount
        parameter W                 = 7,                     // Width of the L2-L1 bus would be 2^W
        parameter L2_DELAY          = 7,                     // Delay of the second level of cache
        
        // Calculated parameters
        localparam BYTES_PER_WORD   = logb2(DATA_WIDTH/8),
        localparam WORDS_PER_BLOCK  = B - 5,
        localparam WORDS_PER_SECT   = B - T - 5,     
                
        localparam CACHE_SIZE       = 1 << S,
        localparam BLOCK_SIZE       = 1 << B,
        localparam ASSOCIATIVITY    = 1 << a,       
        
        localparam TAG_WIDTH        = ADDR_WIDTH + 3 + a - S,
        localparam LINE_ADDR_WIDTH  = S - a - B + T,
        localparam TAG_ADDR_WIDTH   = S - a - B, 
        
        localparam L2_BUS_WIDTH     = 1 << W,
        localparam BLOCK_SECTIONS   = 1 << T, 
        
        localparam SET_SIZE         = CACHE_SIZE / ASSOCIATIVITY,
        localparam LINE_RAM_WIDTH   = 1 << (B - T),
        localparam LINE_RAM_DEPTH   = 1 << LINE_ADDR_WIDTH,
        
        localparam TAG_RAM_WIDTH    = TAG_WIDTH + BLOCK_SECTIONS + 1,
        localparam TAG_RAM_DEPTH    = 1 << TAG_ADDR_WIDTH,
        
        localparam L2_BURST = 1 << (B - W)             
    ) (
        input CLK,
        
        // Ports towards the processor
        input [ADDR_WIDTH - 1 : 0] ADDR_FROM_PROC,
        input [DATA_WIDTH - 1 : 0] DATA_FROM_PROC,
        input WR_ENB_FROM_PROC,
        output [DATA_WIDTH - 1 : 0] DATA_TO_PROC,
        
        input PROC_READY,
        output CACHE_READY,
        
        // Ports towards the L2 cache
        input RD_ADDR_TO_L2_READY,
        output RD_ADDR_TO_L2_VALID,
        output [ADDR_WIDTH - 2 - 1 : 0] RD_ADDR_TO_L2,
        
        input WR_ADDR_TO_L2_READY,
        output WR_ADDR_TO_L2_VALID,
        output [ADDR_WIDTH - 2 - 1 : 0] WR_ADDR_TO_L2,
        
        input DATA_FROM_L2_VALID,
        output DATA_FROM_L2_READY,
        input [L2_BUS_WIDTH - 1 : 0] DATA_FROM_L2, 
        
        input DATA_TO_L2_READY,
        output DATA_TO_L2_VALID,
        output [L2_BUS_WIDTH - 1 : 0] DATA_TO_L2
    );
    
    wire cache_pipe_enb;
    
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Decoding the read/write address                        //
    //////////////////////////////////////////////////////////////////////////////
    
    // Register for the previous stage
    reg  [ADDR_WIDTH      - 1 : 0]   addr_from_proc;
        
    wire [BYTES_PER_WORD  - 1 : 0]   byte_address        = addr_from_proc[0                                  +: BYTES_PER_WORD   ];
    wire [WORDS_PER_SECT  - 1 : 0]   word_address        = addr_from_proc[BYTES_PER_WORD                     +: WORDS_PER_SECT   ];
    wire [LINE_ADDR_WIDTH - 1 : 0]   line_address        = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: LINE_ADDR_WIDTH  ];
    wire [TAG_ADDR_WIDTH  - 1 : 0]   tag_address         = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_BLOCK) +: TAG_ADDR_WIDTH   ];
    wire [TAG_WIDTH       - 1 : 0]   tag                 = addr_from_proc[(ADDR_WIDTH - 1)                   -: TAG_WIDTH        ];
    wire [T               - 1 : 0]   section_address     = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: T                ];    
    
    // Cache pipeline registers
    reg  [WORDS_PER_SECT  - 1 : 0] word_address_del_1, word_address_del_2;
    reg  [TAG_ADDR_WIDTH  - 1 : 0] tag_address_del_1, tag_address_del_2;
    reg  [TAG_WIDTH       - 1 : 0] tag_del_1, tag_del_2;
    reg  [T               - 1 : 0] section_address_del_1, section_address_del_2;
    
    always @(posedge CLK) begin
        // Pipeline for internal address requests (cache level addresses)
        if (cache_pipe_enb) begin
            tag_del_1 <= tag;
            tag_del_2 <= tag_del_1;
            section_address_del_1 <= section_address;
            section_address_del_2 <= section_address_del_1;
            word_address_del_1 <= word_address;
            word_address_del_2 <= word_address_del_1;
            tag_address_del_1 <= tag_address;
            tag_address_del_2 <= tag_address_del_1;
        end        
    end
    
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Memories and muxes                                     //
    //////////////////////////////////////////////////////////////////////////////
    
    // Wires for the tag memories
    wire [TAG_ADDR_WIDTH - 1 : 0] tag_mem_wr_addr; 
    
    wire [TAG_WIDTH      - 1 : 0] tag_to_ram;
    wire [BLOCK_SECTIONS - 1 : 0] tag_valid_to_ram;
    wire                          dirty_to_ram;
     
    wire [ASSOCIATIVITY  - 1 : 0] tag_mem_wr_enb;     
    wire                          tag_mem_rd_enb;
    
    wire [TAG_WIDTH      - 1 : 0] tag_from_ram       [0 : ASSOCIATIVITY - 1];
    wire [BLOCK_SECTIONS - 1 : 0] tag_valid_from_ram [0 : ASSOCIATIVITY - 1];
    wire                          dirty_from_ram     [0 : ASSOCIATIVITY - 1];
    
    
    // Wires for the line memories
    wire [LINE_ADDR_WIDTH - 1 : 0] lin_mem_wr_addr;   
     
    wire [LINE_RAM_WIDTH - 1 : 0] lin_mem_data_in;    
                    
    wire [ASSOCIATIVITY  - 1 : 0] lin_mem_wr_enb;     
    wire                          lin_mem_rd_enb;
    
    wire [LINE_RAM_WIDTH - 1 : 0] lin_data_out       [0 : ASSOCIATIVITY - 1];
                    
    // Tag comparison and validness checking
    wire [ASSOCIATIVITY  - 1 : 0] tag_valid_wire;                   // Whether the tag is valid for the given section of the cache block
    reg  [ASSOCIATIVITY  - 1 : 0] tag_match;                         // Tag matches in a one-hot encoding
    reg  [ASSOCIATIVITY  - 1 : 0] tag_valid;                         // Whether the tag is valid for the given section of the cache block
    
    // Cache line multiplexer wires
    wire [DATA_WIDTH     - 1 : 0] lin_mux_out        [0 : ASSOCIATIVITY - 1];
    wire [DATA_WIDTH * ASSOCIATIVITY - 1 : 0] lin_mux_out_dearray;
        
                         
    genvar i;
        
    generate
        for (i = 0; i < ASSOCIATIVITY; i = i + 1) begin : ASSOC_LOOP
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(TAG_RAM_WIDTH),              // Specify RAM data width
                .RAM_DEPTH(TAG_RAM_DEPTH),              // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("LOW_LATENCY"),        // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                          // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) tag_memory (
                .CLK(CLK),                                                                  // Clock
                .WR_ENB(tag_mem_wr_enb[i]),                                                 // Write enable
                .ADDR_W(tag_mem_wr_addr),                                                   // Write address bus, width determined from RAM_DEPTH
                .DATA_IN({tag_valid_to_ram, tag_to_ram, dirty_to_ram}),                     // RAM input data, width determined from RAM_WIDTH
                .ADDR_R(tag_address),                                                       // Read address bus, width determined from RAM_DEPTH
                .RD_ENB(tag_mem_rd_enb),                                                    // Read Enable, for additional power savings, disable when not in use
                .DATA_OUT({tag_valid_from_ram[i], tag_from_ram[i], dirty_from_ram[i]}),     // RAM output data, width determined from RAM_WIDTH
                .OUT_RST(1'b0),                                                             // Output reset (does not affect memory contents)
                .OUT_ENB(1'b1)                                                              // Output register enable                
            );
            
            // Tag comparison and validness checking
            Multiplexer #(
                .ORDER(T),
                .WIDTH(1)
            ) tag_valid_mux (
                .SELECT(section_address_del_1),
                .IN(tag_valid_from_ram[i]),
                .OUT(tag_valid_wire[i])
            );
            
            always @(posedge CLK) begin
                if (cache_pipe_enb) begin
                    tag_match[i] <= (tag_del_1 == tag_from_ram[i]);
                    tag_valid[i] <= tag_valid_wire[i];
                end
            end
            
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(LINE_RAM_WIDTH),             // Specify RAM data width
                .RAM_DEPTH(LINE_RAM_DEPTH),             // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("HIGH_PERFORMANCE"),   // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                          // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) line_memory (
                .CLK(CLK),                         // Clock
                .WR_ENB(lin_mem_wr_enb[i]),        // Write enable
                .ADDR_W(lin_mem_wr_addr),          // Write address bus, width determined from RAM_DEPTH
                .DATA_IN(lin_mem_data_in),         // RAM input data, width determined from RAM_WIDTH
                .RD_ENB(lin_mem_rd_enb),           // Read Enable, for additional power savings, disable when not in use
                .ADDR_R(line_address),             // Read address bus, width determined from RAM_DEPTH
                .DATA_OUT(lin_data_out[i]),        // RAM output data, width determined from RAM_WIDTH
                .OUT_RST(1'b0),                    // Output reset (does not affect memory contents)
                .OUT_ENB(1'b1)                     // Output register enable
            );
            
            Multiplexer #(
                .ORDER(WORDS_PER_SECT),
                .WIDTH(DATA_WIDTH)
            ) line_mux (
                .SELECT(word_address_del_2),
                .IN(lin_data_out[i]),
                .OUT(lin_mux_out[i])
            );
            
            // De-array the lin_mux_out wire
            assign lin_mux_out_dearray[DATA_WIDTH * i +: DATA_WIDTH] = lin_mux_out[i];
        end
    endgenerate
    
    // Convert the tag match values from one hot format (from equal blocks) to binary format  
    OneHot_to_Bin #(
        .ORDER(a)
    ) set_decoder (
        .ONE_HOT(tag_match),
        .BIN(set_select)
    );
    
    // Set selection multiplexer    
    Multiplexer #(
        .ORDER(a),
        .WIDTH(DATA_WIDTH)
    ) set_mux (
        .SELECT(set_select),
        .IN(lin_mux_out_dearray),
        .OUT(data_to_proc)
    );
    
    // Log value calculation
    function integer logb2;
        input integer depth;
        for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
            depth = depth >> 1;
    endfunction
        
endmodule
