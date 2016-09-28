`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: University of Moratuwa
// Engineer: Ravi Tharaka
// 
// Create Date: 07/29/2016 12:45:35 PM
// Design Name: 
// Module Name: Ins_Cache
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


module Ins_Cache #(
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
        parameter N                 = 3,                     // Number of stream buffers
        parameter n                 = 3,                     // Depth of stream buffers would be 2^n
        
        // Calculated parameters
        localparam BYTES_PER_WORD   = clogb2(DATA_WIDTH/8 - 1),
        
        localparam CACHE_SIZE       = 1 << S,
        localparam BLOCK_SIZE       = 1 << B,
        localparam ASSOCIATIVITY    = 1 << a,
        localparam TAG_WIDTH        = ADDR_WIDTH + 3 + a - S,
        localparam L2_BUS_WIDTH     = 1 << W,
        localparam BLOCK_SECTIONS   = 1 << T,
        
        localparam SET_SIZE         = CACHE_SIZE / ASSOCIATIVITY,
        localparam LINE_RAM_WIDTH   = 1 << (B - T),
        localparam LINE_RAM_DEPTH   = 1 << (S - a - B + T),
        localparam TAG_RAM_WIDTH    = TAG_WIDTH + BLOCK_SECTIONS,
        localparam TAG_RAM_DEPTH    = 1 << (S - a - B),
        
        localparam STREAM_BUF_DEPTH = 1 << n,
        localparam STREAM_SEL_BITS  = clogb2(N + 1),
        
        localparam L2_BURST = 1 << (B - W)
    ) (
        // Standard inputs
        input CLK,
        input RSTN,
        
        // Input address bus from the processor
        input [ADDR_WIDTH - 1 : 0] BRANCH_ADDR_IN,
        input BRANCH,
        
        // Status signals between processor and cache
        input PROC_READY,
        output CACHE_READY,
                
        // Output data bus to the processor
        output reg [DATA_WIDTH - 1 : 0] DATA_TO_PROC,
        
        // Input data bus from L2 cache        
        input [L2_BUS_WIDTH - 1 : 0] DATA_FROM_L2,
        input DATA_FROM_L2_VALID,
        output reg DATA_FROM_L2_READY,
        
        // Output address bus to L2 cache
        output reg [ADDR_WIDTH - 2 - 1 : 0] ADDR_TO_L2,
        input ADDR_TO_L2_READY,
        output ADDR_TO_L2_VALID        
    );
        
    // Tag memory wires
    wire [ASSOCIATIVITY - 1 : 0] tag_mem_wr_enb;
    wire [TAG_WIDTH - 1 : 0] tag_from_ram [0 : ASSOCIATIVITY - 1];
    wire [BLOCK_SECTIONS - 1 : 0] tag_valid_from_ram [0 : ASSOCIATIVITY - 1];
    
    wire tag_mem_rd_enb;
    wire [S - a - B     - 1 : 0] tag_mem_wr_addr;   
    wire [TAG_RAM_WIDTH - 1 : 0] tag_mem_data_in; 
      
    // Line memory wires
    wire [ASSOCIATIVITY - 1 : 0] lin_mem_wr_enb;
    wire [LINE_RAM_WIDTH - 1 : 0] lin_data_out  [0 : ASSOCIATIVITY - 1];
    
    wire lin_mem_rd_enb, lin_mem_out_enb;
    wire [S - a - B + T  - 1 : 0] lin_mem_wr_addr;   
    wire [LINE_RAM_WIDTH - 1 : 0] lin_mem_data_in; 
    
    // Cache line multiplexer wires
    wire [DATA_WIDTH     - 1 : 0] lin_mux_out   [0 : ASSOCIATIVITY - 1];
    wire [DATA_WIDTH * ASSOCIATIVITY - 1 : 0] lin_mux_out_dearray;
    
    // Tag comparison values
    reg [ASSOCIATIVITY  - 1 : 0] tag_match;                         // Tag matches in a one-hot encoding
    wire [ASSOCIATIVITY  - 1 : 0] tag_valid_wire;                   // Whether the tag is valid for the given section of the cache block
    reg [ASSOCIATIVITY  - 1 : 0] tag_valid;                         // Whether the tag is valid for the given section of the cache block
    wire [a - 1 : 0] set_select;                                    // Tag matches in a binary encoding
    wire cache_hit = |(tag_match & tag_valid);                      // Immediate cache hit identifier 
    
    // Set-multiplexer output values and final register stage
    wire [DATA_WIDTH - 1 : 0] data_to_proc;
    wire data_to_proc_enb;
    
    // Cache pipeline registers and their control signals
    wire cache_pipe_enb;
    reg [TAG_WIDTH - 1 : 0]   tag_del_1;
    reg [T - 1 : 0] section_address_del_1;
    reg [B - T - 5 - 1 : 0]   word_addr_del_1, word_addr_del_2;
    
    // PC register and its delays
    wire [1 : 0] pc_sel;                                            // pc_sel = {0(PC + 4), 1 (Delayed PC), 2or3 (Branch path)}
    wire pc_pipe_enb;                                               // Enable the PC pipeline
    reg [ADDR_WIDTH - 1 : 0] pc, pc_del_1, pc_del_2;
    
    // Sections of address bus
    wire [BYTES_PER_WORD - 1 : 0]   byte_address        = pc[0                             +: BYTES_PER_WORD   ];
    wire [B - T - 5      - 1 : 0]   word_address        = pc[BYTES_PER_WORD                +: (B - T - 5)      ];
    wire [S - a - B + T  - 1 : 0]   line_address        = pc[(BYTES_PER_WORD + B - T - 5)  +: (S - a - B + T)  ];
    wire [S - a - B      - 1 : 0]   tag_address         = pc[(BYTES_PER_WORD + B - 5)      +: (S - a - B)      ];
    wire [TAG_WIDTH      - 1 : 0]   tag                 = pc[(ADDR_WIDTH - 1)              -: TAG_WIDTH        ];
    wire [T              - 1 : 0]   section_address     = pc[(BYTES_PER_WORD + B - T - 5)  +: T                ];
    
    // Address to L2 related wires
    wire [ADDR_WIDTH - 2 - 1 : 0] addr_to_L2, prefetch_queue_addr_out, prefetch_queue_addr_in, addr_of_data;
    wire [STREAM_SEL_BITS - 1 : 0] prefetch_queue_src_in, prefetch_queue_src_out;
    reg [STREAM_SEL_BITS - 1 : 0] addr_to_L2_src;
    wire prefetch_queue_wr_enb, prefetch_queue_rd_enb, prefetch_queue_full, prefetch_queue_empty;
    wire ongoing_queue_wr_enb, ongoing_queue_rd_enb, ongoing_queue_full, ongoing_queue_empty;
        
    // Line RAM refill path wires and registers
    wire [LINE_RAM_WIDTH / L2_BUS_WIDTH - 1 : 0] data_from_L2_enb;
    reg [LINE_RAM_WIDTH - 1 : 0] data_from_L2;
    wire [LINE_RAM_WIDTH * N - 1 : 0] stream_buf_out;   
    wire [clogb2(N + 1) - 1 : 0] lin_mem_data_in_sel; 
    wire [N - 1 : 0] stream_buf_rd_enb, stream_buf_wr_enb, stream_buf_empty, stream_buf_full;    
        
    integer j;
    
    initial begin
        // Processor always starts with the zeroth instruction
        pc = 4;   
        pc_del_1 = 72;
        pc_del_2 = 132;
        tag_valid = 0;
        tag_match = 0;  
        tag_del_1 = 0;
        section_address_del_1 = 0;
        addr_to_L2_full = 0;
        ADDR_TO_L2 = 0;
        DATA_FROM_L2_READY = 1;
    end
        
    always @(posedge CLK) begin
        // Output regsiter for the cache architecture
        if (data_to_proc_enb) begin
            DATA_TO_PROC <= data_to_proc;
        end         
        
        // Pipeline for previous address requests (processor level PC)
        if (pc_pipe_enb) begin
            case (pc_sel) 
                2'b00 : pc <= pc + 4;
                2'b01 : pc <= pc_del_2;
                default : pc <= BRANCH_ADDR_IN;
            endcase
        
            pc_del_1 <= pc;
            pc_del_2 <= pc_del_1;
        end   
        
        // Pipeline for internal address requests (cache level PC)
        if (cache_pipe_enb) begin
            tag_del_1 <= tag;
            section_address_del_1 <= section_address;
            word_addr_del_1 <= word_address;
            word_addr_del_2 <= word_addr_del_1;
        end
        
    end
    
    // Generation and coding variables   
    genvar i;
                
    generate
        for (i = 0; i < ASSOCIATIVITY; i = i + 1) begin : ASSOC_LOOP
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(TAG_RAM_WIDTH),              // Specify RAM data width
                .RAM_DEPTH(TAG_RAM_DEPTH),              // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("LOW_LATENCY"),        // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                          // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) tag_memory (
                .ADDR_W(tag_mem_wr_addr),                                   // Write address bus, width determined from RAM_DEPTH
                .ADDR_R(tag_address),                                       // Read address bus, width determined from RAM_DEPTH
                .DATA_IN(tag_mem_data_in),                                  // RAM input data, width determined from RAM_WIDTH
                .CLK(CLK),                                                  // Clock
                .WR_ENB(tag_mem_wr_enb[i]),                                 // Write enable
                .RD_ENB(tag_mem_rd_enb),                                    // Read Enable, for additional power savings, disable when not in use
                .OUT_RST(1'b0),                                             // Output reset (does not affect memory contents)
                .OUT_ENB(1'b1),                                             // Output register enable
                .DATA_OUT({tag_valid_from_ram[i], tag_from_ram[i]})         // RAM output data, width determined from RAM_WIDTH
            );
            
            // Tag comparison and validness checking
            always @(posedge CLK) begin
                if (cache_pipe_enb) begin
                    tag_match[i] <= (tag_del_1 == tag_from_ram[i]);
                    tag_valid[i] <= tag_valid_wire[i];
                end
            end
            
            Multiplexer #(
                .ORDER(T),
                .WIDTH(1)
            ) tag_valid_mux (
                .SELECT(section_address_del_1),
                .IN(tag_valid_from_ram[i]),
                .OUT(tag_valid_wire[i])
            );
            
            Mem_Simple_Dual_Port #(
                .RAM_WIDTH(LINE_RAM_WIDTH),             // Specify RAM data width
                .RAM_DEPTH(LINE_RAM_DEPTH),             // Specify RAM depth (number of entries)
                .RAM_PERFORMANCE("HIGH_PERFORMANCE"),   // Select "HIGH_PERFORMANCE" or "LOW_LATENCY" 
                .INIT_FILE("")                          // Specify name/location of RAM initialization file if using one (leave blank if not)
            ) line_memory (
                .ADDR_W(lin_mem_wr_addr),          // Write address bus, width determined from RAM_DEPTH
                .ADDR_R(line_address),             // Read address bus, width determined from RAM_DEPTH
                .DATA_IN(lin_mem_data_in),         // RAM input data, width determined from RAM_WIDTH
                .CLK(CLK),                         // Clock
                .WR_ENB(lin_mem_wr_enb[i]),        // Write enable
                .RD_ENB(lin_mem_rd_enb),           // Read Enable, for additional power savings, disable when not in use
                .OUT_RST(1'b0),                    // Output reset (does not affect memory contents)
                .OUT_ENB(lin_mem_out_enb),         // Output register enable
                .DATA_OUT(lin_data_out[i])         // RAM output data, width determined from RAM_WIDTH
            );
            
            Multiplexer #(
                .ORDER(B - T - 5),
                .WIDTH(DATA_WIDTH)
            ) line_mux (
                .SELECT(word_addr_del_2),
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
        
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Deciding whether to refill                                 //
    //////////////////////////////////////////////////////////////////////////////    
    wire pc_del_1_equals_2 = (pc_del_2[ADDR_WIDTH - 1 : (BYTES_PER_WORD + B - 5)] == pc_del_1[ADDR_WIDTH - 1 : (BYTES_PER_WORD + B - 5)]);
    wire pc_del_0_equals_2 = (pc_del_2[ADDR_WIDTH - 1 : (BYTES_PER_WORD + B - 5)] == pc[ADDR_WIDTH - 1 : (BYTES_PER_WORD + B - 5)]);
        
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Address to L2 section                                      //
    //////////////////////////////////////////////////////////////////////////////
    // The activation signal for the Address to L2 Section (from the main control unit)
    wire send_addr_to_L2;                                                                  
    
    // High priority queue for storing immediate L2 requests 
    wire [ADDR_WIDTH - 2 - 1 : 0] fetch_queue_out;
    wire fetch_queue_empty;
    
    // Ready signal from the ADDR_TO_L2 register
    wire addr_to_L2_ready; 
    
    // A 3-deep low-latency FWFT FIFO for storing high priority fetch requests
    Fetch_Queue #(
        .WIDTH(ADDR_WIDTH - 2)
    ) fetch_queue (
        .CLK(CLK),
        .TOP_VALID(send_addr_to_L2),
        .BOT_READY(addr_to_L2_ready),
        .DATA_IN(pc_del_2[ADDR_WIDTH - 1 : 2]),
        .DATA_OUT(fetch_queue_out),
        .EMPTY(fetch_queue_empty)
    );
     
    // Low priority queue for storing prefetch requests
    FIFO #(
        .DEPTH(16),                                                                                       // Undecided as of yet
        .WIDTH(ADDR_WIDTH - 2 + STREAM_SEL_BITS)
    ) prefetch_queue (
        .CLK(CLK),
        .RSTN(RSTN),
        .WR_ENB(prefetch_queue_wr_enb),
        .RD_ENB(!prefetch_queue_empty & addr_to_L2_ready),
        .FULL(prefetch_queue_full),
        .EMPTY(prefetch_queue_empty),
        .DATA_IN({prefetch_queue_src_in, prefetch_queue_addr_in}),
        .DATA_OUT({prefetch_queue_src_out, prefetch_queue_addr_out})
    );
    
    wire [1 : 0] addr_to_L2_sel = {fetch_queue_empty, send_addr_to_L2};
        
    // Address to L2 final multiplexer
    Multiplexer #(
        .ORDER(2),
        .WIDTH(ADDR_WIDTH - 2)
    ) addr_to_L2_mux (
        .SELECT(addr_to_L2_sel),
        .IN({pc_del_2[ADDR_WIDTH - 1 : 2], prefetch_queue_addr_out,  fetch_queue_out, fetch_queue_out}),
        .OUT(addr_to_L2)
    );
    
    wire addr_to_L2_valid = (send_addr_to_L2 | !fetch_queue_empty | !prefetch_queue_empty);
    reg addr_to_L2_full;        
            
    always @(posedge CLK) begin
        // Output address register for the L2 cache
        if ((addr_to_L2_valid & ADDR_TO_L2_READY) | (!addr_to_L2_full & addr_to_L2_valid)) begin
            ADDR_TO_L2 <= addr_to_L2;
            addr_to_L2_src <= (addr_to_L2_sel == 2)? prefetch_queue_src_out : 0;
        end
        
        // Valid signal for the L2 cache address stream
        if (addr_to_L2_valid) begin
            addr_to_L2_full <= 1;
        end else if (ADDR_TO_L2_READY) begin 
            addr_to_L2_full <= 0;
        end
    end
    
    assign ADDR_TO_L2_VALID = addr_to_L2_full;
    assign addr_to_L2_ready = !addr_to_L2_full | ADDR_TO_L2_READY;
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - L2 delay path                                              //
    //////////////////////////////////////////////////////////////////////////////
             
    // Queue for requests currently being serviced by the L2 cache
    FIFO #(
        .DEPTH(L2_DELAY / L2_BURST + 2),                                                                                       
        .WIDTH(ADDR_WIDTH - 2 + STREAM_SEL_BITS)
    ) ongoing_L2_queue (
        .CLK(CLK),
        .RSTN(RSTN),
        .WR_ENB(ongoing_queue_wr_enb),
        .RD_ENB(ongoing_queue_rd_enb),
        .FULL(ongoing_queue_full),
        .EMPTY(ongoing_queue_empty),
        .DATA_IN({addr_to_L2_src, ADDR_TO_L2}),
        .DATA_OUT({data_from_L2_src, addr_of_data})
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Data from L2 section                                       //
    //////////////////////////////////////////////////////////////////////////////
        
    always @(posedge CLK) begin
        // Input data register from the L2 cache
        for (j = 0; j < LINE_RAM_WIDTH / L2_BUS_WIDTH; j = j + 1) begin
            if (data_from_L2_enb[j]) begin
                data_from_L2[j * L2_BUS_WIDTH +: L2_BUS_WIDTH] <= DATA_FROM_L2;  
            end
        end
    end
    
    // Set of stream buffers
    generate 
        for (i = 0; i < N; i = i + 1) begin : STREAM_BUF_LOOP
            FIFO #(
                .DEPTH(STREAM_BUF_DEPTH),
                .WIDTH(LINE_RAM_WIDTH)
            ) stream_buffer (
                .CLK(CLK),
                .RSTN(RSTN),
                .WR_ENB(stream_buf_wr_enb[i]),
                .RD_ENB(stream_buf_rd_enb[i]),
                .FULL(stream_buf_full[i]),
                .EMPTY(stream_buf_empty[i]),
                .DATA_IN(data_from_L2),
                .DATA_OUT(stream_buf_out[i * LINE_RAM_WIDTH +: LINE_RAM_WIDTH])
            );
        end
    endgenerate
    
    // Line RAM data in multiplexer
    Multiplexer #(
        .ORDER(clogb2(N + 1)),
        .WIDTH(LINE_RAM_WIDTH)
    ) lin_mem_data_in_mux (
        .SELECT(lin_mem_data_in_sel),
        .IN({stream_buf_out, data_from_L2}),
        .OUT(lin_mem_data_in)
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Primary control system                                                    //
    //////////////////////////////////////////////////////////////////////////////
        
    Ins_Cache_Control #(
        .S(S),
        .B(B),
        .a(a),
        .T(T),
        .N(N),
        .W(W),
        .L2_DELAY(L2_DELAY)
    ) control (
        .CLK(CLK),
        .RSTN(RSTN),
        // Status signals
        .BRANCH(BRANCH),
        .CACHE_HIT(cache_hit),
        .CACHE_READY(CACHE_READY),                          // Signal from cache to processor that its pipeline is currently ready to work
        .PROC_READY(PROC_READY),                            // Signal from processor to cache that its pipeline is currently ready to work
        .SEND_ADDR_TO_L2(send_addr_to_L2),                  // Valid signal for the input of Addr_to_L2 section
        .PC_DEL_1_EQUALS_2(pc_del_1_equals_2),              // Whether PC[t-2] == PC[t-1]
        .PC_DEL_0_EQUALS_2(pc_del_0_equals_2),              // Whether PC[t-2] == PC[t]
        // Multiplexers
        .PC_SEL(pc_sel),                                    // Mux select for PC [pc_sel = {0(Branch path), 1(Delayed PC), 2 or 3(PC + 4)}]
        .LIN_MEM_DATA_IN_SEL(lin_mem_data_in_sel),          // Mux select for line RAM input [lin_mem_data_in_sel = {0(direct path), x (xth stream buffer)}]
        // Register enables
        .PC_PIPE_ENB(pc_pipe_enb),                          // Enable for PC's pipeline registers
        .CACHE_PIPE_ENB(cache_pipe_enb),                    // Enable for cache's pipeline registers
        .DATA_TO_PROC_ENB(data_to_proc_enb),                // Enable for the IR register
        .DATA_FROM_L2_ENB(data_from_L2_enb),                // Enable bus determining where the incoming L2 data is stored in the cache section buffer  
        // Memories
        .TAG_MEM_WR_ENB(tag_mem_wr_enb),                    // Individual write enables for the tag memories
        .TAG_MEM_RD_ENB(tag_mem_rd_enb),                    // Common read enable for the tag memories
        .TAG_MEM_WR_ADDR(tag_mem_wr_addr),                  // Common write address for the the tag memories 
        .TAG_MEM_DATA_IN(tag_mem_data_in),                  // Common data in for the tag memories
        .LIN_MEM_WR_ENB(lin_mem_wr_enb),                    // Individual write enables for the line memories
        .LIN_MEM_RD_ENB(lin_mem_rd_enb),                    // Common read enables for the line memories
        .LIN_MEM_OUT_ENB(lin_mem_out_enb),                  // Common output register enable for the line memories
        .LIN_MEM_WR_ADDR(lin_mem_wr_addr),                  // Common write address for the line memories
        // Queues
        .PREFETCH_QUEUE_WR_ENB(prefetch_queue_wr_enb),
        .PREFETCH_QUEUE_FULL(prefetch_queue_full),
        .ONGOING_QUEUE_WR_ENB(ongoing_queue_wr_enb),
        .ONGOING_QUEUE_RD_ENB(ongoing_queue_rd_enb),
        .ONGOING_QUEUE_FULL(ongoing_queue_full),
        .ONGOING_QUEUE_EMPTY(ongoing_queue_empty),
        .STREAM_BUF_WR_ENB(stream_buf_wr_enb),              // These are all N wide buses
        .STREAM_BUF_RD_ENB(stream_buf_rd_enb),
        .STREAM_BUF_FULL(stream_buf_full),
        .STREAM_BUF_EMPTY(stream_buf_empty)
    );
    
    // Log value calculation
    function integer clogb2;
        input integer depth;
        for (clogb2 = 0; depth > 0; clogb2 = clogb2 + 1)
            depth = depth >> 1;
    endfunction
    
endmodule
