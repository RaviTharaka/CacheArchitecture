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
        parameter p                 = 4,                     // Prefetch queue's depth is 2^p
        
        // Calculated parameters
        localparam BYTES_PER_WORD   = logb2(DATA_WIDTH/8),
        
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
        localparam TAG_RAM_WIDTH    = TAG_WIDTH + BLOCK_SECTIONS,
        localparam TAG_RAM_DEPTH    = 1 << TAG_ADDR_WIDTH,
        
        localparam PREFETCH_QUEUE_DEPTH = 1 << p,
        localparam STREAM_BUF_DEPTH = 1 << n,
        localparam STREAM_SEL_BITS  = logb2(N + 1),
        
        localparam L2_BURST = 1 << (B - W)
    ) (
        // Standard inputs
        input CLK,
        input RSTN,
        
        // Input address bus from the processor
        input BRANCH,
        input [ADDR_WIDTH - 1 : 0]  BRANCH_ADDR_IN,
        
        // Status signals between processor and cache
        input PROC_READY,
        output CACHE_READY,
                
        // Output data bus to the processor
        output reg [DATA_WIDTH - 1 : 0] DATA_TO_PROC,
        
        // Input data bus from L2 cache        
        input DATA_FROM_L2_VALID,
        output DATA_FROM_L2_READY,
        input [L2_BUS_WIDTH - 1 : 0] DATA_FROM_L2,
        
        // Output address bus to L2 cache
        input ADDR_TO_L2_READY,
        output ADDR_TO_L2_VALID,      
        output reg [ADDR_WIDTH - 2 - 1 : 0] ADDR_TO_L2
          
    );
        
    // Tag memory wires
    wire [ASSOCIATIVITY - 1 : 0] tag_mem_wr_enb;
    wire [TAG_WIDTH - 1 : 0] tag_from_ram [0 : ASSOCIATIVITY - 1];
    wire [BLOCK_SECTIONS - 1 : 0] tag_valid_from_ram [0 : ASSOCIATIVITY - 1];
    
    wire tag_mem_rd_enb;
    wire [TAG_ADDR_WIDTH - 1 : 0] tag_mem_wr_addr;   
    wire [TAG_WIDTH - 1 : 0] tag_to_ram;
    wire [BLOCK_SECTIONS - 1 : 0] tag_valid_to_ram;
      
    // Line memory wires
    wire [ASSOCIATIVITY - 1 : 0] lin_mem_wr_enb;
    wire [LINE_RAM_WIDTH - 1 : 0] lin_data_out  [0 : ASSOCIATIVITY - 1];
    
    wire lin_mem_rd_enb;
    wire [LINE_ADDR_WIDTH - 1 : 0] lin_mem_wr_addr;   
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
    
    // Cache pipeline registers and their control signals
    wire cache_pipe_enb;
    reg [TAG_WIDTH       - 1 : 0] tag_del_1, tag_del_2;
    reg [TAG_ADDR_WIDTH  - 1 : 0] tag_address_del_1, tag_address_del_2;
    reg [T               - 1 : 0] section_address_del_1, section_address_del_2;
    reg [B - T - 5       - 1 : 0] word_address_del_1, word_address_del_2;
    
    // PC register and its delays
    wire [1 : 0] pc_sel;                                            // pc_sel = {0(PC + 4), 1 (Branch path), 2or3 (Delayed PC)}
    wire pc_pipe_enb;                                               // Enable the PC pipeline
    reg [ADDR_WIDTH - 1 : 0] pc, pc_del_1, pc_del_2;
    
    // Sections of address bus
    wire [BYTES_PER_WORD  - 1 : 0]   byte_address        = pc[0                             +: BYTES_PER_WORD   ];
    wire [B - T - 5       - 1 : 0]   word_address        = pc[BYTES_PER_WORD                +: (B - T - 5)      ];
    wire [LINE_ADDR_WIDTH - 1 : 0]   line_address        = pc[(BYTES_PER_WORD + B - T - 5)  +: (S - a - B + T)  ];
    wire [TAG_ADDR_WIDTH  - 1 : 0]   tag_address         = pc[(BYTES_PER_WORD + B - 5)      +: (S - a - B)      ];
    wire [TAG_WIDTH       - 1 : 0]   tag                 = pc[(ADDR_WIDTH - 1)              -: TAG_WIDTH        ];
    wire [T               - 1 : 0]   section_address     = pc[(BYTES_PER_WORD + B - T - 5)  +: T                ];
    
    // Address to L2 related wires
    wire [ADDR_WIDTH - 2             - 1 : 0] addr_to_L2;
    wire [TAG_WIDTH + TAG_ADDR_WIDTH - 1 : 0] prefetch_queue_addr_out, prefetch_queue_addr_in;
    wire [STREAM_SEL_BITS            - 1 : 0] prefetch_queue_src_in, prefetch_queue_src_out;
    reg [STREAM_SEL_BITS             - 1 : 0] addr_to_L2_src;
    wire [STREAM_SEL_BITS            - 1 : 0] data_from_L2_src;
    wire prefetch_queue_wr_enb, prefetch_queue_rd_enb, prefetch_queue_full, prefetch_queue_empty;
    wire ongoing_queue_wr_enb, ongoing_queue_rd_enb, ongoing_queue_full, ongoing_queue_empty;
    
    // Data from L2 related wires
    wire stream_buffer_ready;
    wire l1_refill_ready;
    wire data_stored_stream_buf, data_stored_lineRAM;
         
    always @(posedge CLK) begin
        // Output regsiter for the cache architecture
        if (CACHE_READY) begin
            DATA_TO_PROC <= data_to_proc;
        end         
        
        // Pipeline for previous address requests (processor level PC)
        if (pc_pipe_enb) begin
            case (pc_sel) 
                2'b00 : pc <= pc + 4;
                2'b01 : pc <= BRANCH_ADDR_IN;
                default : pc <= pc_del_2;
            endcase
        
            pc_del_1 <= pc;
            pc_del_2 <= pc_del_1;
        end   
        
        // Pipeline for internal address requests (cache level PC)
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
                .CLK(CLK),                                                  // Clock
                .WR_ENB(tag_mem_wr_enb[i]),                                 // Write enable
                .ADDR_W(tag_mem_wr_addr),                                   // Write address bus, width determined from RAM_DEPTH
                .DATA_IN({tag_valid_to_ram, tag_to_ram}),                   // RAM input data, width determined from RAM_WIDTH
                .RD_ENB(tag_mem_rd_enb),                                    // Read Enable, for additional power savings, disable when not in use
                .ADDR_R(tag_address),                                       // Read address bus, width determined from RAM_DEPTH
                .DATA_OUT({tag_valid_from_ram[i], tag_from_ram[i]}),        // RAM output data, width determined from RAM_WIDTH
                .OUT_RST(1'b0),                                             // Output reset (does not affect memory contents)
                .OUT_ENB(1'b1)                                             // Output register enable
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
                .ORDER(B - T - 5),
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
        .DATA_IN({tag_del_2, tag_address_del_2, section_address_del_2, word_address_del_2}),
        .DATA_OUT(fetch_queue_out),
        .EMPTY(fetch_queue_empty)
    );
     
    // Low priority queue for storing prefetch requests
    FIFO_FWFT #(
        .DEPTH(PREFETCH_QUEUE_DEPTH),                                                                                      
        .WIDTH(TAG_WIDTH + TAG_ADDR_WIDTH + STREAM_SEL_BITS)
    ) prefetch_queue (
        .CLK(CLK),
        .RSTN(RSTN),
        .WR_ENB(prefetch_queue_wr_enb),
        .RD_ENB(!prefetch_queue_empty & addr_to_L2_ready & fetch_queue_empty & !send_addr_to_L2),
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
        .IN({{tag_del_2, tag_address_del_2, section_address_del_2, word_address_del_2}, {prefetch_queue_addr_out, {(B - 5){1'b0}}},  fetch_queue_out, fetch_queue_out}),
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
    
    assign ongoing_queue_wr_enb = ADDR_TO_L2_VALID & ADDR_TO_L2_READY;
    assign ongoing_queue_rd_enb = (data_from_L2_src == 0)? data_stored_lineRAM : data_stored_stream_buf;
                
    // Queue for requests currently being serviced by the L2 cache
    FIFO_FWFT #(
        //.DEPTH(pwr_ceil($ceil((L2_DELAY + 0.0) / (L2_BURST + 0.0)) + 1)),             //XST doesnt seem to work with $ceil
        .DEPTH(pwr_ceil(L2_DELAY / L2_BURST + 2)),                                                                                         
        .WIDTH(STREAM_SEL_BITS)
    ) ongoing_L2_queue (
        .CLK(CLK),
        .RSTN(RSTN),
        .WR_ENB(ongoing_queue_wr_enb),
        .RD_ENB(ongoing_queue_rd_enb),
        .FULL(ongoing_queue_full),
        .EMPTY(ongoing_queue_empty),
        .DATA_IN(addr_to_L2_src),
        .DATA_OUT(data_from_L2_src)
    );
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Data from L2 section                                       //
    //////////////////////////////////////////////////////////////////////////////
    
    wire [LINE_RAM_WIDTH / L2_BUS_WIDTH - 1 : 0] data_from_L2_buffer_enb;
    reg [LINE_RAM_WIDTH - 1 : 0] data_from_L2_buffer;
    
    // Buffer for storing data from L2, until they are read into the Stream Buffers or Line RAMs
    integer j;        
    always @(posedge CLK) begin
        for (j = 0; j < LINE_RAM_WIDTH / L2_BUS_WIDTH; j = j + 1) begin
            if (data_from_L2_buffer_enb[j]) begin
                data_from_L2_buffer[j * L2_BUS_WIDTH +: L2_BUS_WIDTH] <= DATA_FROM_L2;  
            end
        end
    end
    
    wire data_from_L2_buffer_ready;
    wire data_from_L2_buffer_valid;    
    assign data_from_L2_buffer_ready = (data_from_L2_src == 0)? l1_refill_ready : stream_buffer_ready;                                        
    
    // Control unit for Data_From_L2 buffer
    Data_From_L2_Buffer_Control #(
        .L2_BUS_WIDTH(L2_BUS_WIDTH),
        .BUFFER_WIDTH(LINE_RAM_WIDTH)
    ) data_from_L2_buffer_control (
        .CLK(CLK),
        .DATA_FROM_L2_READY(DATA_FROM_L2_READY),
        .DATA_FROM_L2_VALID(DATA_FROM_L2_VALID),
        .DATA_FROM_L2_BUFFER_READY(data_from_L2_buffer_ready),
        .DATA_FROM_L2_BUFFER_VALID(data_from_L2_buffer_valid),
        .DATA_FROM_L2_BUFFER_ENB(data_from_L2_buffer_enb)
    );
    
    
    //////////////////////////////////////////////////////////////////////////////
    // Refill path - Stream buffers and cache write units                       //
    //////////////////////////////////////////////////////////////////////////////
            
    wire [LINE_RAM_WIDTH * N - 1 : 0] stream_buf_out;   
    wire [logb2(N + 1) - 1 : 0] lin_mem_data_in_sel; 
    wire [N - 1 : 0] stream_buf_rd_enb, stream_buf_wr_enb, stream_buf_empty, stream_buf_full, stream_buf_reset;   
    wire [T - 1 : 0] stream_buf_section_sel; 
    wire section_commit;
           
    // Set of stream buffers
    generate 
        for (i = 0; i < N; i = i + 1) begin : STREAM_BUF_LOOP
            Stream_Buffer #(
                .DEPTH(STREAM_BUF_DEPTH),
                .WIDTH(LINE_RAM_WIDTH),
                .T(T)
            ) stream_buffer (
                .CLK(CLK),
                .RESET(stream_buf_reset[i]),
                .SECTION_SEL(stream_buf_section_sel),
                .WR_ENB(stream_buf_wr_enb[i]),
                .RD_ENB(stream_buf_rd_enb[i]),
                .FULL(stream_buf_full[i]),
                .EMPTY(stream_buf_empty[i]),
                .DATA_IN(data_from_L2_buffer),
                .DATA_OUT(stream_buf_out[i * LINE_RAM_WIDTH +: LINE_RAM_WIDTH])
            );
            
        end
    endgenerate
    
   // Temporary
   reg x,y,z;
   always @(posedge CLK) begin
       x <= cache_hit;
       y <= x;
       z <= y;
   end   
   initial begin
       x = 1;
       y = 1;
       z = 1;
   end
   
    wire [STREAM_SEL_BITS - 1 : 0] hit_buf_no;
    wire stream_hit;
    
    Stream_Buffer_Control #(
        .N(N),
        .ADDR_WIDTH(TAG_WIDTH + TAG_ADDR_WIDTH),
        .p(p),
        .T(T)
    ) stream_buffer_control (
        .CLK(CLK),
        // Data from L2 buffer 
        .DATA_FROM_L2_SRC(data_from_L2_src),
        .DATA_FROM_L2_BUFFER_READY(stream_buffer_ready),
        .DATA_FROM_L2_BUFFER_VALID(data_from_L2_buffer_valid),
        // Controlling the stream buffers themselves
        .STREAM_BUF_RESET(stream_buf_reset),
        .STREAM_BUF_SECTION_SEL(stream_buf_section_sel),
        .STREAM_BUF_WR_ENB(stream_buf_wr_enb),              
        .STREAM_BUF_RD_ENB(stream_buf_rd_enb),
        .STREAM_BUF_FULL(stream_buf_full),
        .STREAM_BUF_EMPTY(stream_buf_empty),
        .ONGOING_QUEUE_RD_ENB(data_stored_stream_buf),
        .PREFETCH_QUEUE_WR_ENB(prefetch_queue_wr_enb),
        .PREFETCH_QUEUE_FULL(prefetch_queue_full),
        .PREFETCH_QUEUE_ADDR(prefetch_queue_addr_in),
        .PREFETCH_QUEUE_SRC(prefetch_queue_src_in),
        .PC_IN(pc[ADDR_WIDTH - 1 -: (TAG_WIDTH + LINE_ADDR_WIDTH + T)]),
        .HIT(stream_hit),
        .HIT_BUF_NO(hit_buf_no),
        .SECTION_COMMIT(section_commit),
        .ALLOCATE(!cache_hit & !(!x & !y & !z)),                                                            // Temporary
        .ALLOCATE_ADDR({tag_del_2, tag_address_del_2} + 1)                        // Temporary
    );
                                                       
    // Line RAM data in multiplexer
    Multiplexer #(
        .ORDER(logb2(N + 1)),
        .WIDTH(LINE_RAM_WIDTH)
    ) lin_mem_data_in_mux (
        .SELECT(lin_mem_data_in_sel),
        .IN({stream_buf_out, data_from_L2_buffer}),
        .OUT(lin_mem_data_in)
    );
     
    //////////////////////////////////////////////////////////////////////////////
    // Primary control system                                                    //
    //////////////////////////////////////////////////////////////////////////////
     
    Refill_Control_I #(
        .S(S),
        .B(B),
        .a(a),
        .N(N),
        .T(T)
    ) refill_control (
        .CLK(CLK),
        // Outputs to the main processor pipeline		
        .CACHE_READY(CACHE_READY),                          // Signal from cache to processor that its pipeline is currently ready to work  
        // Hit miss status 
        .CACHE_HIT(cache_hit),
        .STREAM_HIT(stream_hit),
        .CACHE_SRC(tag_match),
        .STREAM_SRC(hit_buf_no),
        // Data needed for the refill operation
        .REFILL_REQ_TAG(tag_del_2),
        .REFILL_REQ_LINE(tag_address_del_2),
        .REFILL_REQ_SECT(section_address_del_2),
        .REFILL_REQ_TAG_PREV(tag_del_1),
        .REFILL_REQ_LINE_PREV(tag_address_del_1),
        .REFILL_REQ_SECT_PREV(section_address_del_1),
        // Related to PC select and PC pipeline enable
        .BRANCH(BRANCH),
        .PC_PIPE_ENB(pc_pipe_enb),                         // Enable for main pipeline registers
        .PC_SEL(pc_sel),                                   // Mux select for PC [pc_sel = {0(PC + 4), 1(Branch path), 2 or 3(PC delay 2)}]         
        // Related to Address to L2 buffers
        .SEND_ADDR_TO_L2(send_addr_to_L2),                 // Valid signal for the input of Addr_to_L2 section   
        // Data from L2 buffer 
        .DATA_FROM_L2_SRC(data_from_L2_src),
        .DATA_FROM_L2_BUFFER_READY(l1_refill_ready),
        .DATA_FROM_L2_BUFFER_VALID(data_from_L2_buffer_valid),
        .ONGOING_QUEUE_RD_ENB(data_stored_lineRAM),
        // Stream buffers
        .SECTION_COMMIT(section_commit),
        // LineRAM and TagRAM
        .TAG_MEM_WR_ENB(tag_mem_wr_enb),                    // Individual write enables for the tag memories
        .TAG_MEM_WR_ADDR(tag_mem_wr_addr),                  // Common write address for the the tag memories 
        .TAG_MEM_TAG_IN(tag_to_ram),                        // Common data in for the tag memories   
        .TAG_MEM_TAG_VALID_IN(tag_valid_to_ram),            // Common data in for the tag memories   
        .LIN_MEM_WR_ENB(lin_mem_wr_enb),                    // Individual write enables for the line memories
        .LIN_MEM_WR_ADDR(lin_mem_wr_addr),                  // Common write address for the line memories 
        .LIN_MEM_DATA_IN_SEL(lin_mem_data_in_sel)           // 0 for L2 requests, buffer number for others
               
    );
    
        
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
        .CACHE_HIT(cache_hit),
        .PROC_READY(PROC_READY),                            // Signal from processor to cache that its pipeline is currently ready to work
        // Register enables
        .CACHE_PIPE_ENB(cache_pipe_enb),                    // Enable for cache's pipeline registers
        // Memories
        .TAG_MEM_RD_ENB(tag_mem_rd_enb),                    // Common read enable for the tag memories
        .LIN_MEM_RD_ENB(lin_mem_rd_enb)
    );
    
    initial begin
        // Processor always starts with the zeroth instruction
        pc       = 13235634;   
        pc_del_1 = 42235213;
        pc_del_2 = 124537765;
        
        word_address_del_1        = pc_del_1[BYTES_PER_WORD                +: (B - T - 5)      ];
        tag_address_del_1         = pc_del_1[(BYTES_PER_WORD + B - 5)      +: (S - a - B)      ];
        tag_del_1                 = pc_del_1[(ADDR_WIDTH - 1)              -: TAG_WIDTH        ];
        section_address_del_1     = pc_del_1[(BYTES_PER_WORD + B - T - 5)  +: T                ];
        
        word_address_del_2       = pc_del_2[BYTES_PER_WORD                +: (B - T - 5)      ];
        tag_address_del_2        = pc_del_2[(BYTES_PER_WORD + B - 5)      +: (S - a - B)      ];
        tag_del_2                = pc_del_2[(ADDR_WIDTH - 1)              -: TAG_WIDTH        ];
        section_address_del_2    = pc_del_2[(BYTES_PER_WORD + B - T - 5)  +: T                ];
            
        tag_valid = 0;
        tag_match = 0;  
        addr_to_L2_full = 0;
        ADDR_TO_L2 = 0;
    end
    
    // Log value calculation
    function integer logb2;
        input integer depth;
        for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
            depth = depth >> 1;
    endfunction
    
    function integer pwr_ceil;
        input integer a;
        
        integer k;
        for (k = 1; k < a; k = k << 1)
            pwr_ceil = k << 1;
    endfunction
    
endmodule
