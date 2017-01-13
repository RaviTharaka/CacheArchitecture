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
        parameter V                 = 2,                     // Size of the victim cache will be 2^V cache lines
        
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
        
        localparam TAG_RAM_WIDTH    = TAG_WIDTH + BLOCK_SECTIONS + 1,       // +1 for dirty bit
        localparam TAG_RAM_DEPTH    = 1 << TAG_ADDR_WIDTH,
        
        localparam L2_BURST         = 1 << (B - W)             
    ) (
        input CLK,
        
        // Ports towards the processor
        input      [2              - 1 : 0] CONTROL_FROM_PROC,              // CONTROL_FROM_PROC = {00(idle), 01(read), 10(write), 11(flush address from cache)}
        input      [ADDR_WIDTH     - 1 : 0] ADDR_FROM_PROC,
        input      [DATA_WIDTH     - 1 : 0] DATA_FROM_PROC,
        output reg [DATA_WIDTH     - 1 : 0] DATA_TO_PROC,
        
        input                               PROC_READY,
        output                              CACHE_READY,
        
        // Ports towards the L2 cache
        input                               WR_TO_L2_READY,
        output                              WR_TO_L2_VALID,
        output     [ADDR_WIDTH - 2 - 1 : 0] WR_ADDR_TO_L2,
        output     [L2_BUS_WIDTH   - 1 : 0] DATA_TO_L2,
        output                              WR_CONTROL_TO_L2,
        input                               WR_COMPLETE,
        
        input                               RD_ADDR_TO_L2_READY,
        output                              RD_ADDR_TO_L2_VALID,
        output reg [ADDR_WIDTH - 2 - 1 : 0] RD_ADDR_TO_L2,
        
        input                               DATA_FROM_L2_VALID,
        output                              DATA_FROM_L2_READY,
        input      [L2_BUS_WIDTH   - 1 : 0] DATA_FROM_L2        
        
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Globally important wires and signals                                     //
    //////////////////////////////////////////////////////////////////////////////
        
    wire send_rd_addr_to_L2;        // Instructs the RD_ADDR_TO_L2 unit to send address to L2  
    
    wire refill_from_L2_ready;      // Instructs the DATA_FROM_L2 unit that the data it has is ready to be sampled
    wire refill_from_L2_valid;      // States the DATA_FROM_L2 unit has valid data 
      
    wire cache_pipe_enb;            // Enables the cache processes
    wire pc_pipe_enb;               // Enables the main processor pipeline
    wire input_from_proc_sel;       // input_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}, same for control and data from processor also
    
    wire cache_hit;                 // L1 cache has hit
    wire victim_hit;                // Victim cache has hit
    
    wire victim_cache_ready;        // Victim cache is ready to write
    wire victim_cache_valid;        // Victim cache write is valid
    
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Decoding the read/write address                        //
    //////////////////////////////////////////////////////////////////////////////
    
    // Register for the previous stage
    reg  [ADDR_WIDTH      - 1 : 0]   addr_from_proc;
    reg  [DATA_WIDTH      - 1 : 0]   data_from_proc;
    reg  [2               - 1 : 0]   control_from_proc;
        
    wire [BYTES_PER_WORD  - 1 : 0]   byte_address        = addr_from_proc[0                                  +: BYTES_PER_WORD   ];
    wire [WORDS_PER_SECT  - 1 : 0]   word_address        = addr_from_proc[BYTES_PER_WORD                     +: WORDS_PER_SECT   ];
    wire [LINE_ADDR_WIDTH - 1 : 0]   line_address        = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: LINE_ADDR_WIDTH  ];
    wire [TAG_ADDR_WIDTH  - 1 : 0]   tag_address         = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_BLOCK) +: TAG_ADDR_WIDTH   ];
    wire [TAG_WIDTH       - 1 : 0]   tag                 = addr_from_proc[(ADDR_WIDTH - 1)                   -: TAG_WIDTH        ];
    wire [T               - 1 : 0]   section_address     = addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: T                ];    
    
    // Cache pipeline registers
    reg  [WORDS_PER_SECT  - 1 : 0]   word_address_del_1,    word_address_del_2;
    reg  [TAG_ADDR_WIDTH  - 1 : 0]   tag_address_del_1,     tag_address_del_2;
    reg  [TAG_WIDTH       - 1 : 0]   tag_del_1,             tag_del_2;
    reg  [T               - 1 : 0]   section_address_del_1, section_address_del_2;
    
    reg  [2               - 1 : 0]   control_del_1,         control_del_2;
    reg  [DATA_WIDTH      - 1 : 0]   data_del_1,            data_del_2;
    
    // Main pipeline registers
    reg  [ADDR_WIDTH      - 1 : 0]   addr_from_proc_del_1,    addr_from_proc_del_2;
    reg  [DATA_WIDTH      - 1 : 0]   data_from_proc_del_1,    data_from_proc_del_2;
    reg  [2               - 1 : 0]   control_from_proc_del_1, control_from_proc_del_2;
        
    
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
            
            control_del_1 <= control_from_proc;
            control_del_2 <= control_del_1;
            
            data_del_1 <= data_from_proc;
            data_del_2 <= data_del_1; 
        end    
        
        // Pipeline for the main processor
        if (pc_pipe_enb) begin
            if (addr_from_proc_sel) begin
                addr_from_proc <= ADDR_FROM_PROC;
                data_from_proc <= DATA_FROM_PROC;
                control_from_proc <= CONTROL_FROM_PROC;
            end else begin
                addr_from_proc <= addr_from_proc_del_2;
                data_from_proc <= data_from_proc_del_2;
                control_from_proc <= control_from_proc_del_2;
            end
        
            addr_from_proc_del_1 <= addr_from_proc;
            data_from_proc_del_1 <= data_from_proc;
            control_from_proc_del_1 <= control_from_proc;
            
            addr_from_proc_del_2 <= addr_from_proc_del_1;
            data_from_proc_del_2 <= data_from_proc_del_1;
            control_from_proc_del_2 <= control_from_proc_del_1;
        end            
    end
    
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Memories and muxes                                     //
    //////////////////////////////////////////////////////////////////////////////
    
    // Wires for the tag memories
    wire [TAG_ADDR_WIDTH  - 1 : 0] tag_mem_wr_addr; 
    
    wire [TAG_WIDTH       - 1 : 0] tag_to_ram;
    wire [BLOCK_SECTIONS  - 1 : 0] tag_valid_to_ram;
    wire                           dirty_to_ram;
     
    wire [ASSOCIATIVITY   - 1 : 0] tag_mem_wr_enb;     
    wire                           tag_mem_rd_enb = cache_pipe_enb;
    
    wire [TAG_WIDTH       - 1 : 0] tag_from_ram             [0 : ASSOCIATIVITY - 1];
    wire [BLOCK_SECTIONS  - 1 : 0] tag_valid_from_ram       [0 : ASSOCIATIVITY - 1];
    wire                           dirty_from_ram           [0 : ASSOCIATIVITY - 1];
    
    
    // Wires for the line memories
    wire [LINE_ADDR_WIDTH - 1 : 0] lin_mem_wr_addr;   
     
    wire [LINE_RAM_WIDTH  - 1 : 0] lin_mem_data_in;    
                    
    wire [ASSOCIATIVITY   - 1 : 0] lin_mem_wr_enb;     
    wire                           lin_mem_rd_enb = cache_pipe_enb;
    
    wire [LINE_RAM_WIDTH  - 1 : 0] lin_data_out             [0 : ASSOCIATIVITY - 1];
                    
    // Tag comparison and validness checking
    wire [ASSOCIATIVITY   - 1 : 0] tag_valid_wire;                     // Whether the tag is valid for the given section of the cache block
    reg  [ASSOCIATIVITY   - 1 : 0] tag_match;                          // Tag matches in a one-hot encoding
    reg  [ASSOCIATIVITY   - 1 : 0] tag_valid;                          // Whether the tag is valid for the given section of the cache block
        
    // Set multiplexer wires    
    wire [a                              - 1 : 0] set_select;          // Tag matches in a binary encoding  
    
    wire [ASSOCIATIVITY * LINE_RAM_WIDTH - 1 : 0] lin_ram_out_dearray; 
    reg  [ASSOCIATIVITY * TAG_WIDTH      - 1 : 0] tag_ram_out_dearray; 
    reg  [ASSOCIATIVITY * 1              - 1 : 0] dirty_ram_out_dearray; 
    
    wire [LINE_RAM_WIDTH                 - 1 : 0] data_set_mux_out;    // Data after selecting the proper set
    wire [TAG_WIDTH                      - 1 : 0] tag_set_mux_out;     // Tag after selecting the proper set
    wire                                          dirty_set_mux_out;   // Dirty after selecting the proper set
    
    // Cache line multiplexer wires
    wire [DATA_WIDTH      - 1 : 0] data_to_proc;                       // Data going back to the processor   
                            
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
                .OUT_ENB(tag_mem_rd_enb)                                                    // Output register enable                
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
                    
                    tag_ram_out_dearray[TAG_WIDTH * i +: TAG_WIDTH] <= tag_from_ram[i];
                    dirty_ram_out_dearray[i] <= dirty_from_ram[i];
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
                .OUT_ENB(lin_mem_rd_enb)           // Output register enable
            );
            
            // De-array the lin_data_out wire
            assign lin_ram_out_dearray   [LINE_RAM_WIDTH * i +: LINE_RAM_WIDTH] = lin_data_out  [i];
            
        end
    endgenerate
    
    // Convert the tag match values from one hot format (from equal blocks) to binary format  
    OneHot_to_Bin #(
        .ORDER(a)
    ) set_decoder (
        .ONE_HOT(tag_match),
        .BIN(set_select)
    );
    
    // L1 data set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(LINE_RAM_WIDTH)
    ) data_set_mux (
        .SELECT(set_select),
        .IN(lin_ram_out_dearray),
        .OUT(data_set_mux_out)
    );
    
    // L1 tag set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(TAG_WIDTH)
    ) tag_set_mux (
        .SELECT(set_select),
        .IN(tag_ram_out_dearray),
        .OUT(tag_set_mux_out)
    );
    
    // Dirty set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(1)
    ) dirty_set_mux (
        .SELECT(set_select),
        .IN(dirty_ram_out_dearray),
        .OUT(dirty_set_mux_out)
    );
    
    // Word selection multiplexer
    Multiplexer #(
        .ORDER(WORDS_PER_SECT),
        .WIDTH(DATA_WIDTH)
    ) word_mux (
        .SELECT(word_address_del_2),
        .IN(data_set_mux_out),
        .OUT(data_to_proc)
    );
    
    // If cache is hitting and instruction is to read, send the data back
    always @(posedge CLK) begin
        if (CACHE_READY & (control_from_proc_del_2 == 2'b01)) begin
            DATA_TO_PROC <= data_to_proc;
        end
    end
    
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Address to L2 section                                      //
    //////////////////////////////////////////////////////////////////////////////
       
    // Queue for storing bursts of L2 requests 
    wire [ADDR_WIDTH - 2 - 1 : 0] fetch_queue_out;
    wire                          fetch_queue_empty;
    
    // Ready signal from the RD_ADDR_TO_L2 output register
    wire                          rd_addr_to_L2_ready;     
        
    // A 3-deep low-latency FWFT FIFO for storing high priority fetch requests
    Fetch_Queue #(
        .WIDTH(ADDR_WIDTH - 2)
    ) fetch_queue (
        .CLK(CLK),
        .TOP_VALID(send_rd_addr_to_L2),
        .BOT_READY(rd_addr_to_L2_ready),
        .DATA_IN({tag_del_2, tag_address_del_2, section_address_del_2, word_address_del_2}),
        .DATA_OUT(fetch_queue_out),
        .EMPTY(fetch_queue_empty)
    );
    
    // A final multiplexer to send requests immediately, or after queueing
    wire [ADDR_WIDTH - 2 - 1 : 0] rd_addr_to_L2;    
    
    Multiplexer #(
        .ORDER(1),
        .WIDTH(ADDR_WIDTH - 2)
    ) rd_addr_to_L2_mux (
        .SELECT(fetch_queue_empty),
        .IN({{tag_del_2, tag_address_del_2, section_address_del_2, word_address_del_2}, fetch_queue_out}),
        .OUT(rd_addr_to_L2)
    );
    
    // Output register holding the current RD_ADDR_TO_L2
    wire                        rd_addr_to_L2_valid;
    reg                         rd_addr_to_L2_full; 
           
    assign rd_addr_to_L2_valid = (send_rd_addr_to_L2 | !fetch_queue_empty);
        
    always @(posedge CLK) begin
        // Output address register for the L2 cache
        if ((rd_addr_to_L2_valid & RD_ADDR_TO_L2_READY) | (!rd_addr_to_L2_full & rd_addr_to_L2_valid)) begin
            RD_ADDR_TO_L2 <= rd_addr_to_L2;
        end
        
        // Valid signal for the L2 cache address stream
        if (rd_addr_to_L2_valid) begin
            rd_addr_to_L2_full <= 1;
        end else if (RD_ADDR_TO_L2_READY) begin 
            rd_addr_to_L2_full <= 0;
        end
    end    
    
    assign RD_ADDR_TO_L2_VALID = rd_addr_to_L2_full;
    assign rd_addr_to_L2_ready = !rd_addr_to_L2_full | RD_ADDR_TO_L2_READY;
     
     
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Data from L2 section                                       //
    //////////////////////////////////////////////////////////////////////////////
    
    wire [LINE_RAM_WIDTH / L2_BUS_WIDTH - 1 : 0] data_from_L2_buffer_enb;
    reg  [LINE_RAM_WIDTH                - 1 : 0] data_from_L2_buffer;
    
    // Buffer for storing data from L2, until they are read into the Stream Buffers or Line RAMs
    integer j;
    always @(posedge CLK) begin
        for (j = 0; j < LINE_RAM_WIDTH / L2_BUS_WIDTH; j = j + 1) begin
            if (data_from_L2_buffer_enb[j]) begin
                data_from_L2_buffer[j * L2_BUS_WIDTH +: L2_BUS_WIDTH] <= DATA_FROM_L2;  
            end
        end
    end    
    
    // Control unit for Data_From_L2 buffer
    Data_From_L2_Buffer_Control #(
        .L2_BUS_WIDTH(L2_BUS_WIDTH),
        .BUFFER_WIDTH(LINE_RAM_WIDTH)
    ) data_from_L2_buffer_control (
        .CLK(CLK),
        .DATA_FROM_L2_READY(DATA_FROM_L2_READY),
        .DATA_FROM_L2_VALID(DATA_FROM_L2_VALID),
        .DATA_FROM_L2_BUFFER_READY(refill_from_L2_ready),
        .DATA_FROM_L2_BUFFER_VALID(refill_from_L2_valid),
        .DATA_FROM_L2_BUFFER_ENB(data_from_L2_buffer_enb)
    );       
    
    //////////////////////////////////////////////////////////////////////////////
    // Victim cache and its controls                                            //
    //////////////////////////////////////////////////////////////////////////////

    wire [LINE_RAM_WIDTH - 1 : 0] victim_cache_refill;
    wire                          victim_cache_control;
    
    // Set the flush bit
    assign victim_cache_control = (control_del_2 == 2'b11);
    
    Victim_Cache #(
        .S(S),
        .B(B),
        .a(a),
        .T(T),
        .V(V),
        .W(W)
    ) victim_cache (
        .CLK(CLK),
        // Write port from L1 cache
        .DATA_FROM_L1(data_set_mux_out),
        .ADDR_FROM_L1({tag_set_mux_out, tag_address_del_2, section_address_del_2}),
        .DIRTY_FROM_L1(dirty_set_mux_out),
        .CONTROL_FROM_L1(victim_cache_control),
        .WR_FROM_L1_VALID(victim_cache_valid),
        .WR_FROM_L1_READY(victim_cache_ready),
        // Search port from L1 cache
        .SEARCH_ADDR({tag, tag_address, section_address}),
        // Ports back to L1 cache
        .VICTIM_HIT(victim_hit),
        .DATA_TO_L1(victim_cache_refill),
        // Write port to L2
        .WR_TO_L2_READY(WR_TO_L2_READY),
        .WR_TO_L2_VALID(WR_TO_L2_VALID),
        .WR_ADDR_TO_L2(WR_ADDR_TO_L2),
        .DATA_TO_L2(DATA_TO_L2),
        .WR_CONTROL_TO_L2(WR_CONTROL_TO_L2),
        .WR_COMPLETE(WR_COMPLETE)      
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Cache write units                                          //
    //////////////////////////////////////////////////////////////////////////////
    
    wire [LINE_RAM_WIDTH - 1 : 0] wr_data_refill;
    
    wire [2              - 1 : 0] refill_sel;      // refill_sel = {0 or 1(for a L1 data write), 2(victim cache refill), 3 (for L2 refill)}
    
    // Line RAM data in multiplexer
    genvar z;
    generate 
        for (z = 0; z < (1 << WORDS_PER_SECT); z = z + 1) begin : REFILL_LOOP
            wire [1 : 0] lin_mem_data_in_sel;
            
            assign lin_mem_data_in_sel[1] = refill_sel[1];
            assign lin_mem_data_in_sel[0] = (refill_sel[1])? refill_sel[0] : (z != word_address_del_2);
                        
            Multiplexer #(
                .ORDER(2),
                .WIDTH(DATA_WIDTH)
            ) lin_mem_data_in_mux (
                .SELECT(lin_mem_data_in_sel),
                .IN({data_from_L2_buffer[DATA_WIDTH * z +: DATA_WIDTH], 
                     victim_cache_refill[DATA_WIDTH * z +: DATA_WIDTH],
                     data_set_mux_out   [DATA_WIDTH * z +: DATA_WIDTH], 
                     data_del_2}),
                .OUT(lin_mem_data_in    [DATA_WIDTH * z +: DATA_WIDTH])
            );
        end
    endgenerate
        
    
    //////////////////////////////////////////////////////////////////////////////
    // Primary control systems                                                  //
    //////////////////////////////////////////////////////////////////////////////
        
    Refill_Control_D #(
    
    ) refill_control (
        // Outputs to the main processor pipeline		
        .CACHE_READY(CACHE_READY),                         // Signal from cache to processor that its pipeline is currently ready to work  
        // Related to controlling the pipeline
        .PC_PIPE_ENB(pc_pipe_enb),                         // Enable for main pipeline registers
        .ADDR_FROM_PROC_SEL(addr_from_proc_sel),           // addr_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}    
        // Related to Address to L2 buffers
        .SEND_RD_ADDR_TO_L2(send_rd_addr_to_L2)            // Valid signal for the input of Addr_to_L2 section   
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Initial values                                                           //
    //////////////////////////////////////////////////////////////////////////////
     
    initial begin
        addr_from_proc            = 13235634;   
        addr_from_proc_del_1      = 42235213;
        addr_from_proc_del_2      = 124537765;
           
        word_address_del_1        = addr_from_proc_del_1[BYTES_PER_WORD                     +: WORDS_PER_SECT];
        tag_address_del_1         = addr_from_proc_del_1[(BYTES_PER_WORD + WORDS_PER_BLOCK) +: TAG_ADDR_WIDTH];
        tag_del_1                 = addr_from_proc_del_1[(ADDR_WIDTH - 1)                   -: TAG_WIDTH     ];
        section_address_del_1     = addr_from_proc_del_1[(BYTES_PER_WORD + WORDS_PER_SECT)  +: T             ];
        
        word_address_del_2        = addr_from_proc_del_2[BYTES_PER_WORD                     +: WORDS_PER_SECT];
        tag_address_del_2         = addr_from_proc_del_2[(BYTES_PER_WORD + WORDS_PER_BLOCK) +: TAG_ADDR_WIDTH];
        tag_del_2                 = addr_from_proc_del_2[(ADDR_WIDTH - 1)                   -: TAG_WIDTH     ];
        section_address_del_2     = addr_from_proc_del_2[(BYTES_PER_WORD + WORDS_PER_SECT)  +: T             ];
        
        control_del_1              = 0;
        control_del_2              = 0;
          
    end
        
    // Log value calculation
    function integer logb2;
        input integer depth;
        for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
            depth = depth >> 1;
    endfunction
        
endmodule
