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
        parameter L2_DELAY_RD       = 7,                     // Read delay of the second level of cache
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
            
    wire                      send_rd_addr_to_L2;        // Instructs the RD_ADDR_TO_L2 unit to send address to L2  
    
    wire                      refill_from_L2_ready;      // Instructs the DATA_FROM_L2 unit that the data it has is ready to be sampled
    wire                      refill_from_L2_valid;      // States the DATA_FROM_L2 unit has valid data 
      
    wire                      cache_pipe_enb;            // Enables the cache processes
    wire                      main_pipe_enb;             // Enables the main processor pipeline
    wire                      input_from_proc_sel;       // input_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}, same for control and data from processor also
    
    wire                      cache_hit;                 // L1 cache has hit
    wire                      victim_hit;                // Victim cache has hit
    
    wire                      victim_cache_ready;        // Victim cache is ready to write
    wire                      victim_cache_valid;        // Victim cache write is valid
    
    wire [DATA_WIDTH - 1 : 0] data_to_proc;        // Data going back to the processor   
        
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Decoding the read/write address                        //
    //////////////////////////////////////////////////////////////////////////////
    
    // Selecting whether the processor or cache itself (to evict data to victim cache) has access to the read port of L1
    wire                             rd_port_select;                     // Selects the inputs to the Read ports of L1 {0(from processor), 1(from refill control)} 
    wire [TAG_WIDTH       - 1 : 0]   evict_tag;
    wire [TAG_ADDR_WIDTH  - 1 : 0]   evict_tag_addr;
    wire [T               - 1 : 0]   evict_sect; 
    wire [LINE_ADDR_WIDTH - 1 : 0]   evict_line = {evict_tag_addr, evict_sect};  

    // Register for the previous stage
    reg  [ADDR_WIDTH      - 1 : 0]   addr_from_proc;
    reg  [DATA_WIDTH      - 1 : 0]   data_from_proc;
    reg  [2               - 1 : 0]   control_from_proc;
        
    wire [BYTES_PER_WORD  - 1 : 0]   byte_address        = (rd_port_select)? 0              : addr_from_proc[0                                  +: BYTES_PER_WORD   ];
    wire [WORDS_PER_SECT  - 1 : 0]   word_address        = (rd_port_select)? 0              : addr_from_proc[BYTES_PER_WORD                     +: WORDS_PER_SECT   ];
    wire [LINE_ADDR_WIDTH - 1 : 0]   line_address        = (rd_port_select)? evict_line     : addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: LINE_ADDR_WIDTH  ];
    wire [TAG_ADDR_WIDTH  - 1 : 0]   tag_address         = (rd_port_select)? evict_tag_addr : addr_from_proc[(BYTES_PER_WORD + WORDS_PER_BLOCK) +: TAG_ADDR_WIDTH   ];
    wire [TAG_WIDTH       - 1 : 0]   tag                 = (rd_port_select)? evict_tag      : addr_from_proc[(ADDR_WIDTH - 1)                   -: TAG_WIDTH        ];
    wire [T               - 1 : 0]   section_address     = (rd_port_select)? evict_sect     : addr_from_proc[(BYTES_PER_WORD + WORDS_PER_SECT)  +: T                ];    
    
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
            tag_del_1             <= tag;
            section_address_del_1 <= section_address;
            word_address_del_1    <= word_address;
            tag_address_del_1     <= tag_address;
            
            control_del_1         <= control_from_proc;
            data_del_1            <= data_from_proc;
                                    
            tag_del_2             <= tag_del_1;
            section_address_del_2 <= section_address_del_1;
            word_address_del_2    <= word_address_del_1;
            tag_address_del_2     <= tag_address_del_1;
            
            control_del_2         <= control_del_1;
            data_del_2            <= data_del_1; 
        end    
        
        // Pipeline for the main processor
        if (main_pipe_enb) begin
            if (addr_from_proc_sel) begin
                addr_from_proc    <= ADDR_FROM_PROC;
                data_from_proc    <= DATA_FROM_PROC;
                control_from_proc <= CONTROL_FROM_PROC;
            end else begin
                addr_from_proc    <= addr_from_proc_del_2;
                data_from_proc    <= data_from_proc_del_2;
                control_from_proc <= control_from_proc_del_2;
            end
        
            addr_from_proc_del_1    <= addr_from_proc;
            data_from_proc_del_1    <= data_from_proc;
            control_from_proc_del_1 <= control_from_proc;
            
            addr_from_proc_del_2    <= addr_from_proc_del_1;
            data_from_proc_del_2    <= data_from_proc_del_1;
            control_from_proc_del_2 <= control_from_proc_del_1;
        end            
    end
    
    //////////////////////////////////////////////////////////////////////////////
    // Cache data path - Memories and muxes                                     //
    //////////////////////////////////////////////////////////////////////////////
    
    // Wires for the tag memories
    wire [ASSOCIATIVITY   - 1 : 0] tag_mem_wr_enb;     
    wire [ASSOCIATIVITY   - 1 : 0] dirty_mem_wr_enb;     
    wire [TAG_ADDR_WIDTH  - 1 : 0] tag_mem_wr_addr; 
    wire [TAG_WIDTH       - 1 : 0] tag_to_ram;
    wire [BLOCK_SECTIONS  - 1 : 0] tag_valid_to_ram;
    wire                           dirty_to_ram;
         
    wire                           tag_mem_rd_enb;
    wire [TAG_WIDTH       - 1 : 0] tag_from_ram             [0 : ASSOCIATIVITY - 1];
    wire [BLOCK_SECTIONS  - 1 : 0] tag_valid_from_ram       [0 : ASSOCIATIVITY - 1];
    wire                           dirty_from_ram           [0 : ASSOCIATIVITY - 1];
    
    assign tag_mem_rd_enb = cache_pipe_enb;
    
    // Wires for the line memories
    wire [ASSOCIATIVITY   - 1 : 0] lin_mem_wr_enb;     
    wire [LINE_ADDR_WIDTH - 1 : 0] lin_mem_wr_addr;   
    wire [LINE_RAM_WIDTH  - 1 : 0] lin_mem_data_in;    
                    
    wire                           lin_mem_rd_enb;
    wire [LINE_RAM_WIDTH  - 1 : 0] lin_data_out             [0 : ASSOCIATIVITY - 1];
    
    assign lin_mem_rd_enb = cache_pipe_enb;
                  
    // Tag comparison and validness checking 
    wire [ASSOCIATIVITY   - 1 : 0] tag_valid_wire;                     // Whether the tag is valid for the given section of the cache block (DM2)
    reg  [ASSOCIATIVITY   - 1 : 0] tag_match;                          // Tag matches in a one-hot encoding (DM3)
    reg  [ASSOCIATIVITY   - 1 : 0] tag_valid;                          // Whether the tag is valid for the given section of the cache block (DM3)
    wire [ASSOCIATIVITY   - 1 : 0] hit_set_wire;                       // Whether tag matches and is valid
    
    assign hit_set_wire  = (tag_valid & tag_match);
    assign cache_hit     = |hit_set_wire;    
               
    // Set multiplexer wires    
    wire [a                              - 1 : 0] set_select;          // Tag matches in a binary encoding  
    
    wire [ASSOCIATIVITY * LINE_RAM_WIDTH - 1 : 0] lin_ram_out_dearray; 
    reg  [ASSOCIATIVITY * TAG_WIDTH      - 1 : 0] tag_ram_out_dearray; 
    reg  [ASSOCIATIVITY * 1              - 1 : 0] dirty_ram_out_dearray; 
    reg  [ASSOCIATIVITY * 1              - 1 : 0] valid_ram_out_dearray; 
    
    wire [LINE_RAM_WIDTH                 - 1 : 0] data_set_mux_out;    // Data after selecting the proper set
    wire [TAG_WIDTH                      - 1 : 0] tag_set_mux_out;     // Tag after selecting the proper set
    wire                                          dirty_set_mux_out;   // Dirty after selecting the proper set
    wire                                          valid_set_mux_out;   // Valid after selecting the proper set
                           
    genvar i;
    generate
        for (i = 0; i < ASSOCIATIVITY; i = i + 1) begin : ASSOC_LOOP
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(TAG_RAM_WIDTH - 1),              // Specify RAM data width
                .RAM_DEPTH(TAG_RAM_DEPTH),                  // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("LOW_LATENCY"),            // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                              // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) tag_memory (
                .CLK(CLK),                                                                  // Clock
                .WR_ENB(tag_mem_wr_enb[i]),                                                 // Write enable
                .ADDR_W(tag_mem_wr_addr),                                                   // Write address bus, width determined from RAM_DEPTH
                .DATA_IN({tag_valid_to_ram, tag_to_ram}),                                   // RAM input data, width determined from RAM_WIDTH
                .ADDR_R(tag_address),                                                       // Read address bus, width determined from RAM_DEPTH
                .RD_ENB(tag_mem_rd_enb),                                                    // Read Enable, for additional power savings, disable when not in use
                .DATA_OUT({tag_valid_from_ram[i], tag_from_ram[i]}),     // RAM output data, width determined from RAM_WIDTH
                .OUT_RST(1'b0),                                                             // Output reset (does not affect memory contents)
                .OUT_ENB(tag_mem_rd_enb)                                                    // Output register enable                
            );
            
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(1),                              // Specify RAM data width
                .RAM_DEPTH(TAG_RAM_DEPTH),                  // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("LOW_LATENCY"),            // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                              // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) dirty_memory (
                .CLK(CLK),                                                                  // Clock
                .WR_ENB(dirty_mem_wr_enb[i]),                                               // Write enable
                .ADDR_W(tag_mem_wr_addr),                                                   // Write address bus, width determined from RAM_DEPTH
                .DATA_IN(dirty_to_ram),                                                     // RAM input data, width determined from RAM_WIDTH
                .ADDR_R(tag_address),                                                       // Read address bus, width determined from RAM_DEPTH
                .RD_ENB(tag_mem_rd_enb),                                                    // Read Enable, for additional power savings, disable when not in use
                .DATA_OUT(dirty_from_ram[i]),                                               // RAM output data, width determined from RAM_WIDTH
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
                    valid_ram_out_dearray[i] <= tag_valid_wire[i];
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
            assign lin_ram_out_dearray [LINE_RAM_WIDTH * i +: LINE_RAM_WIDTH] = lin_data_out  [i];
            
        end
    endgenerate
    
    // Replacement policy unit
    Replacement_Unit #(
        .S(S),
        .B(B),
        .a(a)
    ) replacement_unit (
        .BLOCK(tag_address_del_1),
        .REPLACE(replace)
    );
        
    // Convert the tag match values from one hot format (from equal units) to binary format  
    OneHot_to_Bin #(
        .ORDER(a)
    ) set_decoder (
        .ONE_HOT(hit_set_wire),
        .DEFAULT(replace),
        .BIN(set_select)
    );
    
    // L1 data, set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(LINE_RAM_WIDTH)
    ) data_set_mux (
        .SELECT(set_select),
        .IN(lin_ram_out_dearray),
        .OUT(data_set_mux_out)
    );
    
    // L1 tag, set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(TAG_WIDTH)
    ) tag_set_mux (
        .SELECT(set_select),
        .IN(tag_ram_out_dearray),
        .OUT(tag_set_mux_out)
    );
    
    // Dirty, set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(1)
    ) dirty_set_mux (
        .SELECT(set_select),
        .IN(dirty_ram_out_dearray),
        .OUT(dirty_set_mux_out)
    );
    
    // Valid, set selection multiplexer 
    Multiplexer #(
        .ORDER(a),
        .WIDTH(1)
    ) valid_set_mux (
        .SELECT(set_select),
        .IN(valid_ram_out_dearray),
        .OUT(valid_set_mux_out)
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
    
    wire [1 : 0] refill_sel;                // refill_sel = {0 or 1(for a L1 data write), 2(victim cache refill), 3 (for L2 refill)}
           
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
    
    // From refill control unit
    wire [TAG_WIDTH       - 1 : 0] refill_tag;              // Current refill's tag
    wire [TAG_ADDR_WIDTH  - 1 : 0] refill_tag_addr;         // Current refill cache line
    wire [T               - 1 : 0] refill_sect;             // Current refill section
    wire [ASSOCIATIVITY   - 1 : 0] refill_dst;              // Refill destination set
    wire [BLOCK_SECTIONS  - 1 : 0] refill_tag_valid;        // Tag valid values to be written
    
    // Line memory write port controls
    assign lin_mem_wr_addr = (refill_sel[1]) ? {refill_tag_addr, refill_sect} : {tag_address_del_2, section_address_del_2};
    assign lin_mem_wr_enb  = (refill_sel[1]) ? refill_dst                     : (hit_set_wire & {ASSOCIATIVITY {control_del_2 == 2'b10}});
    
    // Tag memory write port controls
    assign tag_mem_wr_addr  = (refill_sel[1]) ? refill_tag_addr                : 0;
    assign tag_mem_wr_enb   = (refill_sel[1]) ? refill_dst                     : 0;
    assign dirty_mem_wr_enb = (refill_sel[1]) ? refill_dst                     : (hit_set_wire & {ASSOCIATIVITY {control_del_2 == 2'b10}});
    
    // Tag RAM data in multiplexer
    assign tag_valid_to_ram = refill_tag_valid;
    assign tag_to_ram       = refill_tag;
    assign dirty_to_ram     = (refill_sel[1]) ? 1'b0                           : 1'b1;
    
    
    //////////////////////////////////////////////////////////////////////////////
    // Primary control systems                                                  //
    //////////////////////////////////////////////////////////////////////////////
    
     Refill_Control_D #(
        .S(S),
        .B(B),
        .a(a),
        .T(T)
    ) refill_control (
        .CLK(CLK),
        // Inputs from DM2 pipeline stage
        .CONTROL(control_del_1),
        // Inputs from DM3 pipeline stage
        .CACHE_HIT(cache_hit),                              // Whether the L1 cache hits or misses 
        .VICTIM_HIT(victim_hit),                            // Whether the victim cache has hit
        .REFILL_REQ_TAG(tag_del_2),                         // Tag portion of the PC at DM3
        .REFILL_REQ_LINE(tag_address_del_2),                // Line portion of the PC at DM3
        .REFILL_REQ_SECT(section_address_del_2),            // Section portion of the PC at DM3
        .REFILL_REQ_VTAG(tag_set_mux_out),                  // Tag coming out of tag memory delayed to DM3
        .REFILL_REQ_DST_SET(set_select),                    // Destination set for the refill. In binary format. 
        .REFILL_REQ_DIRTY(dirty_set_mux_out),               // Dirty bit coming out of tag memory delayed to DM3
        .REFILL_REQ_CTRL(control_del_2),                    // Instruction at DM3
        .REFILL_REQ_VALID(valid_set_mux_out),               // Valid bit coming out of tag memory delayed to DM3
        // From the Victim cache
        .VICTIM_CACHE_READY(victim_cache_ready),            // From victim cache that it is ready to receive
        .VICTIM_CACHE_WRITE(victim_cache_valid),            // To victim cache that it has to write the data from DM3
        // To the L1 read ports
        .L1_RD_PORT_SELECT(rd_port_select),                // Selects the inputs to the Read ports of L1 {0(from processor), 1(from refill control)}         
        .EVICT_TAG(evict_tag),                             // Tag for read address at DM1 
        .EVICT_TAG_ADDR(evict_tag_addr),                   // Cache line for read address at DM1 
        .EVICT_SECT(evict_sect),                           // Section for read address at DM1 
        // To the L1 write ports
        .L1_WR_PORT_SELECT(refill_sel),                    // Selects the inputs to the Write ports of L1 {0 or 1(for a L1 data write), 2(victim cache refill), 3 (for L2 refill)}
        .REFILL_DST(refill_dst),                           // Individual write enables for the line memories
        .REFILL_TAG(refill_tag),                           // Tag for the refill write
        .REFILL_TAG_VALID(refill_tag_valid),               // Which sections are valid currently, will be written to tag memory
        .REFILL_TAG_ADDR(refill_tag_addr),                 // Tag address for the refill write
        .REFILL_SECT(refill_sect),                         // Section address for the refill write
        // Outputs to the main processor pipeline		
        .CACHE_READY(CACHE_READY),                         // Signal from cache to processor that its pipeline is currently ready to work  
        // Related to controlling the pipeline
        .MAIN_PIPE_ENB(main_pipe_enb),                     // Enable for main pipeline registers
        .CACHE_PIPE_ENB(cache_pipe_enb),                   // Enable for cache pipeline
        .ADDR_FROM_PROC_SEL(addr_from_proc_sel),           // addr_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}    
        // Related to Address to L2 buffers
        .SEND_RD_ADDR_TO_L2(send_rd_addr_to_L2),           // Valid signal for the input of Addr_to_L2 section
        .DATA_FROM_L2_BUFFER_READY(refill_from_L2_ready),  // Ready signal for refill from L2
        .DATA_FROM_L2_BUFFER_VALID(refill_from_L2_valid)   // Valid signal for refill from L2
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
        
        control_from_proc          = 0;
        control_del_1              = 0;
        control_del_2              = 0;
        
        tag_valid                  = 0;
        tag_match                  = 0;  
        rd_addr_to_L2_full         = 0;
        RD_ADDR_TO_L2              = 0;  
    end
        
    // Log value calculation
    function integer logb2;
        input integer depth;
        for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
            depth = depth >> 1;
    endfunction
        
endmodule
