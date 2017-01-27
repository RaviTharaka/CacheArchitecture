`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12/29/2016 01:18:53 PM
// Design Name: 
// Module Name: Refill_Control_D
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


module Refill_Control_D #(
        // Fixed parameters
        localparam ADDR_WIDTH       = 32,
        
        // Primary parameters
        parameter S                 = 17, 
        parameter B                 = 9, 
        parameter a                 = 1,
        parameter N                 = 3,
        parameter T                 = 1,
        
        // Derived parameters
        localparam TAG_WIDTH        = ADDR_WIDTH + 3 + a - S,
        localparam TAG_ADDR_WIDTH   = S - a - B,
        localparam STREAM_SEL_BITS  = logb2(N + 1),
        localparam BLOCK_SECTIONS   = 1 << T,
        localparam ASSOCIATIVITY    = 1 << a,
        localparam LINE_ADDR_WIDTH  = S - a - B + T    
    ) (
        input                                CLK,
        
        // Current request at IF3
        input                                CACHE_HIT,                      // Whether the L1 cache hits or misses 
        input                                VICTIM_HIT,                     // Whether the victim cache has hit
        input      [2               - 1 : 0] CONTROL,                        // Control portion of request at DM2 
        
        input      [TAG_WIDTH       - 1 : 0] REFILL_REQ_TAG,                 // Tag portion of the ADDR at DM3
        input      [TAG_ADDR_WIDTH  - 1 : 0] REFILL_REQ_LINE,                // Line portion of the ADDR at DM3
        input      [T               - 1 : 0] REFILL_REQ_SECT,                // Section portion of the ADDR at DM3
        input      [TAG_WIDTH       - 1 : 0] REFILL_REQ_VTAG,                // Tag coming out of tag memory delayed to DM3
        input      [a               - 1 : 0] REFILL_REQ_DST_SET,             // Destination set for the refill
        input                                REFILL_REQ_DIRTY,               // Dirty bit coming out of tag memory delayed to DM3
        input                                REFILL_REQ_VALID,               // Valid bit coming out of tag memory delayed to DM3
        input      [2               - 1 : 0] REFILL_REQ_CTRL,                // Instruction at DM3 
         
         // From the Victim cache
        input                                VICTIM_CACHE_READY,            // From victim cache that it is ready to receive
        output reg                           VICTIM_CACHE_WRITE,            // To victim cache that it has to write the data from DM3
        
        // To the cache pipeline
        output reg                           L1_RD_PORT_SELECT,             // Selects the inputs to the Read ports of L1 {0(from processor), 1(from refill control)}         
        output reg [TAG_WIDTH       - 1 : 0] EVICT_TAG,                     // Tag for read address at DM1 
        output reg [TAG_ADDR_WIDTH  - 1 : 0] EVICT_TAG_ADDR,                // Cache line for read address at DM1 
        output reg [T               - 1 : 0] EVICT_SECT,                    // Section for read address at DM1  
                                       
        // Outputs to the main processor pipeline		
        output CACHE_READY,                         // Signal from cache to processor that its pipeline is currently ready to work  
                
        // Related to Address to L2 buffers
        output SEND_RD_ADDR_TO_L2,                  // Valid signal for the input of Addr_to_L2 section   
                
        // Related to controlling the pipeline
        output MAIN_PIPE_ENB,                       // Enable for main pipeline registers
        output CACHE_PIPE_ENB,                      // Enable for cache pipeline
        output ADDR_FROM_PROC_SEL                   // addr_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}   
        
                 
    );
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Refill request queue management                                                              //
    //////////////////////////////////////////////////////////////////////////////////////////////////
                    
    // PCs of the currently being fetched requests are stored. Max number of requests is 4.
    // Three is for DM1, DM2 and DM3 and last is for early restart
    reg [TAG_WIDTH      - 1 : 0] cur_tag,  fir_tag,  sec_tag,  thr_tag;         // Tag for the L1 write
    reg [TAG_WIDTH      - 1 : 0] cur_vtag, fir_vtag, sec_vtag, thr_vtag;        // Tag for the victim cache
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line, fir_line, sec_line, thr_line;        // Cache block to write to (for L1 and victim)
    reg [T              - 1 : 0] cur_sect, fir_sect, sec_sect, thr_sect;        // Section within block to write first (for L1 and victim)
    
    reg [1              - 1 : 0] cur_src,  fir_src,  sec_src,  thr_src;         // Source = whether to refill from L2 (0) or from victim cache (1) 
    reg [a              - 1 : 0] cur_set,  fir_set,  sec_set,  thr_set;         // Set = destination set of the request (in binary format)
    reg [1              - 1 : 0] cur_dirt, fir_dirt, sec_dirt, thr_dirt;        // Whether filling the victim cache is necessary
    reg [2              - 1 : 0] cur_ctrl, fir_ctrl, sec_ctrl, thr_ctrl;        // Control signals of the request
    
    reg [1              - 1 : 0] cur_evic, fir_evic, sec_evic, thr_evic;        // Indicates that the eviction line has to be saved
            
        
    reg [TAG_WIDTH      - 1 : 0] cur_tag_wire,  fir_tag_wire,  sec_tag_wire,  thr_tag_wire;
    reg [TAG_WIDTH      - 1 : 0] cur_vtag_wire, fir_vtag_wire, sec_vtag_wire, thr_vtag_wire;
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line_wire, fir_line_wire, sec_line_wire, thr_line_wire;
    reg [T              - 1 : 0] cur_sect_wire, fir_sect_wire, sec_sect_wire, thr_sect_wire;
    reg [1              - 1 : 0] cur_src_wire,  fir_src_wire,  sec_src_wire,  thr_src_wire;
    reg [ASSOCIATIVITY  - 1 : 0] cur_set_wire,  fir_set_wire,  sec_set_wire,  thr_set_wire;
    reg [1              - 1 : 0] cur_dirt_wire, fir_dirt_wire, sec_dirt_wire, thr_dirt_wire;        
    reg [1              - 1 : 0] cur_ctrl_wire, fir_ctrl_wire, sec_ctrl_wire, thr_ctrl_wire;     
    reg [1              - 1 : 0] cur_evic_wire, fir_evic_wire, sec_evic_wire, thr_evic_wire;
                 
    // To get admitted to the refill queue, several tests must be passed, and also it mustn't readmit a completed refill
    // (L2 misses, PC pipe disables, DM pipe saturated with PC value, L2 completes and removes from queue, but still DM pipe
    // saturated, this causes a miss, and readmit)
        
    // Solution - Admission only if the DM3 request came from a valid PC on the PC pipeline
    reg main_pipe_enb_del_1, main_pipe_enb_del_2;
    reg real_request;                               // Write request is valid and is not an idle
    reg missable_request;                           // Write request is valid and is a write or read
    reg flush_request;                              // Write request is valid and is a flush
        
    always @(posedge CLK) begin
        main_pipe_enb_del_1 <= MAIN_PIPE_ENB;
        main_pipe_enb_del_2 <= main_pipe_enb_del_1;
        
        real_request        <= main_pipe_enb_del_1 & !(CONTROL == 2'b00);
        missable_request    <= main_pipe_enb_del_1 &  (CONTROL == 2'b01 | CONTROL == 2'b10);
        flush_request       <= main_pipe_enb_del_1 &  (CONTROL == 2'b11);
    end    
     
    wire admit, remove;         // Whether to admit to or remove from the refill queue
    wire evict;                 // Indicates that the first eviction in the queue is complete
       
    reg test_pass;
    assign admit = test_pass & real_request;
        
    // Number of elements in the queue
    reg [3 : 0] no_of_elements, no_of_elements_wire;
        
    always @(posedge CLK) begin
        no_of_elements <= no_of_elements_wire;
    end
        
    always @(*) begin
        case ({admit, remove})
            2'b00 : no_of_elements_wire = no_of_elements;
            2'b01 : no_of_elements_wire = no_of_elements >> 1;
            2'b10 : no_of_elements_wire = (no_of_elements << 1) | 4'b0001;
            2'b11 : no_of_elements_wire = no_of_elements;
        endcase
    end
        
    // A queue storing missed requests (also each element is accessible to the outside, to run the tests)
    always @(*) begin
        case ({admit, remove})
            2'b10 : begin
                cur_tag_wire   = (no_of_elements == 4'b0000)? REFILL_REQ_TAG     : cur_tag;
                cur_vtag_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_VTAG    : cur_vtag;
                cur_line_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_LINE    : cur_line;
                cur_sect_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_SECT    : cur_sect;
                cur_src_wire   = (no_of_elements == 4'b0000)? VICTIM_HIT         : cur_src;
                cur_set_wire   = (no_of_elements == 4'b0000)? REFILL_REQ_DST_SET : cur_set;
                cur_dirt_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_DIRTY   : cur_dirt;
                cur_ctrl_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_CTRL    : cur_ctrl;
                
                fir_tag_wire   = (no_of_elements == 4'b0001)? REFILL_REQ_TAG     : fir_tag;
                fir_vtag_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_VTAG    : fir_vtag;
                fir_line_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_LINE    : fir_line;
                fir_sect_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_SECT    : fir_sect;
                fir_src_wire   = (no_of_elements == 4'b0001)? VICTIM_HIT         : fir_src;
                fir_set_wire   = (no_of_elements == 4'b0001)? REFILL_REQ_DST_SET : fir_set;
                fir_dirt_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_DIRTY   : fir_dirt;
                fir_ctrl_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_CTRL    : fir_ctrl;
                
                sec_tag_wire   = (no_of_elements == 4'b0011)? REFILL_REQ_TAG     : sec_tag;
                sec_vtag_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_VTAG    : sec_vtag;
                sec_line_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_LINE    : sec_line;
                sec_sect_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_SECT    : sec_sect;
                sec_src_wire   = (no_of_elements == 4'b0011)? VICTIM_HIT         : sec_src;
                sec_set_wire   = (no_of_elements == 4'b0011)? REFILL_REQ_DST_SET : sec_set;
                sec_dirt_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_DIRTY   : sec_dirt;
                sec_ctrl_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_CTRL    : sec_ctrl;
                
                thr_tag_wire   = (no_of_elements == 4'b0111)? REFILL_REQ_TAG     : thr_tag;
                thr_vtag_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_VTAG    : thr_vtag;
                thr_line_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_LINE    : thr_line;
                thr_sect_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_SECT    : thr_sect;
                thr_src_wire   = (no_of_elements == 4'b0111)? VICTIM_HIT         : thr_src;
                thr_set_wire   = (no_of_elements == 4'b0111)? REFILL_REQ_DST_SET : thr_set;
                thr_dirt_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_DIRTY   : thr_dirt;
                thr_ctrl_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_CTRL    : thr_ctrl;
            end
            2'b01 : begin
                cur_tag_wire  = fir_tag;
                cur_vtag_wire = fir_vtag;
                cur_line_wire = fir_line;
                cur_sect_wire = fir_sect;
                cur_src_wire  = fir_src;
                cur_set_wire  = fir_set;
                cur_dirt_wire = fir_dirt;
                cur_ctrl_wire = fir_ctrl;
                
                fir_tag_wire  = sec_tag;
                fir_vtag_wire = sec_vtag;
                fir_line_wire = sec_line;
                fir_sect_wire = sec_sect;
                fir_src_wire  = sec_src;
                fir_set_wire  = sec_set;
                fir_dirt_wire = sec_dirt;
                fir_ctrl_wire = sec_ctrl;
                                
                sec_tag_wire  = thr_tag;
                sec_vtag_wire = thr_vtag;
                sec_line_wire = thr_line;
                sec_sect_wire = thr_sect;
                sec_src_wire  = thr_src;
                sec_set_wire  = thr_set;
                sec_dirt_wire = thr_dirt;
                sec_ctrl_wire = thr_ctrl;
                                
                thr_tag_wire  = 0;
                thr_vtag_wire = 0;
                thr_line_wire = 0;
                thr_sect_wire = 0;
                thr_src_wire  = 0;
                thr_set_wire  = 0;
                thr_dirt_wire = 0;
                thr_ctrl_wire = 0;                                
            end
            2'b11 : begin
                cur_tag_wire   = (no_of_elements == 4'b0001)? REFILL_REQ_TAG     : fir_tag;
                cur_vtag_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_VTAG    : fir_vtag;
                cur_line_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_LINE    : fir_line;
                cur_sect_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_SECT    : fir_sect;
                cur_src_wire   = (no_of_elements == 4'b0001)? VICTIM_HIT         : fir_src;
                cur_set_wire   = (no_of_elements == 4'b0001)? REFILL_REQ_DST_SET : fir_set;
                cur_dirt_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_DIRTY   : fir_dirt;
                cur_ctrl_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_CTRL    : fir_ctrl;
                
                fir_tag_wire   = (no_of_elements == 4'b0011)? REFILL_REQ_TAG     : sec_tag;
                fir_vtag_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_VTAG    : sec_vtag;
                fir_line_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_LINE    : sec_line;
                fir_sect_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_SECT    : sec_sect;
                fir_src_wire   = (no_of_elements == 4'b0011)? VICTIM_HIT         : sec_src;
                fir_set_wire   = (no_of_elements == 4'b0011)? REFILL_REQ_DST_SET : sec_set;
                fir_dirt_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_DIRTY   : sec_dirt;
                fir_ctrl_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_CTRL    : sec_ctrl;
                                
                sec_tag_wire   = (no_of_elements == 4'b0111)? REFILL_REQ_TAG     : thr_tag;
                sec_vtag_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_VTAG    : thr_vtag;
                sec_line_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_LINE    : thr_line;
                sec_sect_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_SECT    : thr_sect;
                sec_src_wire   = (no_of_elements == 4'b0111)? VICTIM_HIT         : thr_src;
                sec_set_wire   = (no_of_elements == 4'b0111)? REFILL_REQ_DST_SET : thr_set;
                sec_dirt_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_DIRTY   : thr_dirt;
                sec_ctrl_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_CTRL    : thr_ctrl;
                
                thr_tag_wire   = (no_of_elements == 4'b1111)? REFILL_REQ_TAG     : 0;
                thr_vtag_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_VTAG    : 0;
                thr_line_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_LINE    : 0;
                thr_sect_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_SECT    : 0;
                thr_src_wire   = (no_of_elements == 4'b1111)? VICTIM_HIT         : 0;
                thr_set_wire   = (no_of_elements == 4'b1111)? REFILL_REQ_DST_SET : 0;
                thr_dirt_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_DIRTY   : 0;
                thr_ctrl_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_CTRL    : 0;
                                
            end
            2'b00 : begin
                cur_tag_wire  = cur_tag;
                cur_vtag_wire = cur_vtag;
                cur_line_wire = cur_line;
                cur_sect_wire = cur_sect;
                cur_src_wire  = cur_src;
                cur_set_wire  = cur_set;
                cur_dirt_wire = cur_dirt;
                cur_ctrl_wire = cur_ctrl;
                
                fir_tag_wire  = fir_tag;
                fir_vtag_wire = fir_vtag;
                fir_line_wire = fir_line;
                fir_sect_wire = fir_sect;
                fir_src_wire  = fir_src;
                fir_set_wire  = fir_set;
                fir_dirt_wire = fir_dirt;
                fir_ctrl_wire = fir_ctrl;
                                
                sec_tag_wire  = sec_tag;
                sec_vtag_wire = sec_vtag;
                sec_line_wire = sec_line;
                sec_sect_wire = sec_sect;
                sec_src_wire  = sec_src;
                sec_set_wire  = sec_set;
                sec_dirt_wire = sec_dirt;
                sec_ctrl_wire = sec_ctrl;
                
                thr_tag_wire  = thr_tag;
                thr_vtag_wire = thr_vtag;
                thr_line_wire = thr_line;
                thr_sect_wire = thr_sect;
                thr_src_wire  = thr_src;
                thr_set_wire  = thr_set;
                thr_dirt_wire = thr_dirt;
                thr_ctrl_wire = thr_ctrl;
            end
        endcase
    end
    
    // Registering the queue values at the clock
    always @(posedge CLK) begin
        cur_tag  <= cur_tag_wire;
        cur_vtag <= cur_vtag_wire;
        cur_line <= cur_line_wire;
        cur_sect <= cur_sect_wire;
        cur_src  <= cur_src_wire;
        cur_set  <= cur_set_wire;
        cur_dirt <= cur_dirt_wire;
        cur_ctrl <= cur_ctrl_wire;
        
        fir_tag  <= fir_tag_wire;
        fir_vtag <= fir_vtag_wire;
        fir_line <= fir_line_wire;
        fir_sect <= fir_sect_wire;
        fir_src  <= fir_src_wire;
        fir_set  <= fir_set_wire;
        fir_dirt <= fir_dirt_wire;
        fir_ctrl <= fir_ctrl_wire;
        
        sec_tag  <= sec_tag_wire;
        sec_vtag <= sec_vtag_wire;
        sec_line <= sec_line_wire;
        sec_sect <= sec_sect_wire;
        sec_src  <= sec_src_wire;
        sec_set  <= sec_set_wire;
        sec_dirt <= sec_dirt_wire;
        sec_ctrl <= sec_ctrl_wire;
        
        thr_tag  <= thr_tag_wire;
        thr_vtag <= thr_vtag_wire;
        thr_line <= thr_line_wire;
        thr_sect <= thr_sect_wire;
        thr_src  <= thr_src_wire;
        thr_set  <= thr_set_wire;
        thr_dirt <= thr_dirt_wire;
        thr_ctrl <= thr_ctrl_wire;        
    end
    
    // Stores which 'still unevicted request' is at the head of the queue
    reg [3 : 0] compl_evic;    
    always @(*) begin
        case ({thr_evic, sec_evic, fir_evic, cur_evic})
            4'b0000 : compl_evic = 4'b0000;
            4'b0001 : compl_evic = 4'b0001;
            4'b0010 : compl_evic = 4'b0010;
            4'b0011 : compl_evic = 4'b0001;
            
            4'b0100 : compl_evic = 4'b0100;
            4'b0101 : compl_evic = 4'b0001;
            4'b0110 : compl_evic = 4'b0010;
            4'b0111 : compl_evic = 4'b0001;
            
            4'b1000 : compl_evic = 4'b1000;
            4'b1001 : compl_evic = 4'b0001;
            4'b1010 : compl_evic = 4'b0010;
            4'b1011 : compl_evic = 4'b0001;
            
            4'b1100 : compl_evic = 4'b0100;
            4'b1101 : compl_evic = 4'b0001;
            4'b1110 : compl_evic = 4'b0010;
            4'b1111 : compl_evic = 4'b0001;
        endcase
    end
    
    // Part of the request queue for storing whether eviction is complete
    always @(*) begin
        case ({admit, remove, evict}) 
            3'b100 : begin
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : cur_evic;
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : fir_evic;
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : sec_evic;
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : thr_evic;
            end
            3'b010 : begin
                cur_evic_wire = fir_evic;
                fir_evic_wire = sec_evic;
                sec_evic_wire = thr_evic;
                thr_evic_wire = 0;
            end
            3'b110 : begin
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : fir_tag;
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : sec_tag;
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : thr_tag;
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : 0;
            end
            3'b000 : begin
                cur_evic_wire = cur_evic;
                fir_evic_wire = fir_evic;
                sec_evic_wire = sec_evic;
                thr_evic_wire = thr_evic;
            end
            3'b101 : begin
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : cur_evic & !compl_evic[0];
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : fir_evic & !compl_evic[1];
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : sec_evic & !compl_evic[2];
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : thr_evic & !compl_evic[3];
            end
            3'b011 : begin
                cur_evic_wire = fir_evic & !compl_evic[1];
                fir_evic_wire = sec_evic & !compl_evic[2];
                sec_evic_wire = thr_evic & !compl_evic[3];
                thr_evic_wire = 0;
            end
            3'b111 : begin
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : fir_tag & !compl_evic[1];
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : sec_tag & !compl_evic[2];
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : thr_tag & !compl_evic[3];
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : 0;
            end
            3'b001 : begin
                cur_evic_wire = cur_evic & !compl_evic[0];
                fir_evic_wire = fir_evic & !compl_evic[1];
                sec_evic_wire = sec_evic & !compl_evic[2];
                thr_evic_wire = thr_evic & !compl_evic[3];
            end
        endcase
    end
    
    // Registering the eviction information at end of clock cycle
    always @(posedge CLK) begin
        cur_evic <= cur_evic_wire;
        fir_evic <= fir_evic_wire;
        sec_evic <= sec_evic_wire;
        thr_evic <= thr_evic_wire;
    end
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Tests to decide whether to include the IF3 request in to the queue                           //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    wire clash_n0 = ((REFILL_REQ_LINE == cur_line) & (REFILL_REQ_DST_SET == cur_set) & no_of_elements[0]) & (!CACHE_HIT | (REFILL_REQ_DST_SET == cur_set)); 
    wire clash_n1 = ((REFILL_REQ_LINE == fir_line) & (REFILL_REQ_DST_SET == fir_set) & no_of_elements[1]) & (!CACHE_HIT | (REFILL_REQ_DST_SET == fir_set)); 
    wire clash_n2 = ((REFILL_REQ_LINE == sec_line) & (REFILL_REQ_DST_SET == sec_set) & no_of_elements[2]) & (!CACHE_HIT | (REFILL_REQ_DST_SET == sec_set)); 
    
    wire equal_n0 = (REFILL_REQ_LINE == cur_line) & (REFILL_REQ_TAG == cur_tag) & no_of_elements[0];	
    wire equal_n1 = (REFILL_REQ_LINE == fir_line) & (REFILL_REQ_TAG == fir_tag) & no_of_elements[1];	
    wire equal_n2 = (REFILL_REQ_LINE == sec_line) & (REFILL_REQ_TAG == sec_tag) & no_of_elements[2];	
    
    // Whether to pass or fail the tests
    always @(*) begin
        if (equal_n2) begin
            test_pass = 0;
        end else if (clash_n2) begin
            test_pass = 1;
        end else if (equal_n1) begin
            test_pass = 0;    
        end else if (clash_n1) begin
            test_pass = 1;    
        end else if (equal_n0) begin
            test_pass = 0;    
        end else if (clash_n0) begin
            test_pass = 1;    
        end else begin
            test_pass = !CACHE_HIT;
        end    
    end    
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // FSM for saving eviction victims                                                              //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    wire evic_empty_wire = !(|{cur_evic_wire, fir_evic_wire, sec_evic_wire, thr_evic_wire});
    
    localparam E_HITTING = 1;
    localparam E_IDLE1   = 2;
    localparam E_IDLE2   = 4;
    
    reg [3 + BLOCK_SECTIONS - 1 : 0] evic_state;
    
    always @(posedge CLK) begin
        if (VICTIM_CACHE_READY) begin
            case (evic_state)
                E_HITTING : 
                    evic_state <= (evic_empty_wire)? evic_state : E_IDLE1;
                E_IDLE1   : 
                    evic_state <= E_IDLE2;
                E_IDLE2   : 
                    evic_state <= evic_state << 2;
                {1'b1, {(2 + BLOCK_SECTIONS){1'b0}}} : 
                    evic_state <= (evic_empty_wire)?  E_HITTING : E_IDLE2 << 1;
                default   : 
                    evic_state <= evic_state << 1;
            endcase
        end
    end
    
    always @(*) begin
        case (evic_state) 
            E_HITTING : VICTIM_CACHE_WRITE = !evic_empty_wire;
            E_IDLE1   : VICTIM_CACHE_WRITE = 0;  
            E_IDLE2   : VICTIM_CACHE_WRITE = 0;  
            default   : VICTIM_CACHE_WRITE = !evic_empty_wire;   
        endcase
    end
    
    always @(*) begin
        case (evic_state)
            E_HITTING : L1_RD_PORT_SELECT = 0;
            E_IDLE1   : L1_RD_PORT_SELECT = 0;  
            E_IDLE2   : L1_RD_PORT_SELECT = 0;  
            default   : L1_RD_PORT_SELECT = 1;   
        endcase
    end
           
    always @(*) begin
        case (compl_evic)
            4'b0001  : begin
                EVICT_TAG      = cur_vtag;
                EVICT_TAG_ADDR = cur_line;
                EVICT_SECT     = cur_sect;
            end
            4'b0010  : begin
                EVICT_TAG      = fir_vtag;
                EVICT_TAG_ADDR = fir_line;
                EVICT_SECT     = fir_sect;
            end
            4'b0100  : begin
                EVICT_TAG      = sec_vtag;
                EVICT_TAG_ADDR = sec_line;
                EVICT_SECT     = sec_sect;
            end
            4'b1000  : begin
                EVICT_TAG      = thr_vtag;
                EVICT_TAG_ADDR = thr_line;
                EVICT_SECT     = thr_sect;
            end
            default  : begin
                EVICT_TAG      = cur_vtag;
                EVICT_TAG_ADDR = cur_line;
                EVICT_SECT     = cur_sect;
            end
        endcase
    end       
          
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for Address to L2 modules                                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    // Address sent to L2 only if its admitted to queue and its not a stream hit
    assign SEND_RD_ADDR_TO_L2 = admit & !VICTIM_HIT;
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // FSM for refill control                                                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
                
    localparam IDLE        = 0;
    localparam TRANSITION  = 1;
    localparam WRITING_VIC = 2;
    localparam WRITING_L2  = 3;
    localparam FLUSHING    = 4;
    
    reg [3              - 1 : 0] refill_state,      refill_state_wire;
    reg [T              - 1 : 0] no_completed,      no_completed_wire;
    reg [BLOCK_SECTIONS - 1 : 0] commited_sections, commited_sections_wire;
    
    integer i;
        
//    always @(*) begin
//        case (refill_state)
//            IDLE : begin
//                case ({CACHE_HIT, VICTIM_HIT})
//                    2'b00 :  begin
//                        refill_state_wire = (missable_request)? WRITING_L2 : IDLE;
//                        no_completed_wire = 0;
//                        commited_sections_wire = 0;
//                    end
//                    2'b01 :  begin
//                        refill_state_wire = (missable_request)? WRITING_VIC : IDLE;
//                        no_completed_wire = 1;
//                        for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                            commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
//                        end
//                    end
//                    default :  begin
//                        if (flush_request) begin
//                            refill_state_wire = FLUSHING;
//                            no_completed_wire = 1;
//                            for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                                commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
//                            end
//                        end else begin
//                            refill_state_wire = IDLE;
//                            no_completed_wire = 0;
//                            commited_sections_wire = 0;
//                        end
//                    end 
//                endcase              
//            end
                
//            TRANSITION : begin
//                if (cur_src != 0) begin
//                    refill_state_wire = WRITING_VIC;
//                    no_completed_wire = 1;
//                    for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                        commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
//                    end
//                end else begin
// //                   if (DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & DATA_FROM_L2_SRC == 0) begin
//                        refill_state_wire = WRITING_L2;
//                        no_completed_wire = 1;
//                        for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                            commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
//                        end
//                    end else begin
//                        refill_state_wire = WRITING_L2;
//                        no_completed_wire = 0;
//                        commited_sections_wire = 0;
//                    end
//                end
//            end
            
//            WRITING_VIC : begin
//                // Wait for the eviction to be complete before starting to write
                
            
//                // When whole block is finished, go to idle state or transition state
//                if (no_completed == {T{1'b1}}) begin
//                    if (no_of_elements == 4'b0001 & !admit) begin
//                        refill_state_wire = IDLE;
//                    end else begin
//                        refill_state_wire = TRANSITION;
//                    end 
//                end else begin
//                    refill_state_wire = refill_state;                    
//                end
                
//                for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                    if (i[T - 1 : 0] == cur_sect + no_completed) begin
//                        commited_sections_wire[i] = 1; 
//                    end else begin
//                        commited_sections_wire[i] = commited_sections[i];
//                    end                       
//                end
                
//                no_completed_wire = no_completed + 1;
//            end
            
//            WRITING_L2 : begin
// //               if (DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & (DATA_FROM_L2_SRC == 0)) begin
//                    // When whole block is fetched, go to idle state or transition
//                    if (no_completed == {T{1'b1}}) begin
//                        if (no_of_elements == 4'b0001 & !admit) begin
//                            refill_state_wire = IDLE;
//                        end else begin
//                            refill_state_wire = TRANSITION;
//                        end  
//                    end else begin
//                        refill_state_wire = refill_state;
//                    end
                    
//                    for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
//                        if (i[T - 1 : 0] == cur_sect + no_completed) begin
//                            commited_sections_wire[i] = 1; 
//                        end else begin
//                            commited_sections_wire[i] = commited_sections[i];
//                        end                       
//                    end
                                            
//                    no_completed_wire = no_completed + 1;                                        
////                end else begin
//                    no_completed_wire = no_completed;
//                    refill_state_wire = refill_state;
//                    commited_sections_wire = commited_sections;
////                end        
//            end
            
//            // Case of flushing
//            default : begin
            
//            end
//        endcase
//    end
    
    always @(posedge CLK) begin
        no_completed      <= no_completed_wire;
        refill_state      <= refill_state_wire;
        commited_sections <= commited_sections_wire;
    end
    
//    assign remove = ((refill_state == WRITING_L2) & DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & (DATA_FROM_L2_SRC == 0) & (no_completed == {T{1'b1}}))
//                            | ((refill_state == WRITING_SB) & (no_completed == {T{1'b1}}));
        
        

    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Initial values                                                                               //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    initial begin
        no_of_elements = 0;
       
        main_pipe_enb_del_2 = 1;
        main_pipe_enb_del_1 = 1;
        real_request        = 0;
        missable_request    = 0;
        
        evic_state     = E_HITTING;
        
        cur_evic = 0;
        fir_evic = 0;
        sec_evic = 0;
        thr_evic = 0;
        
        refill_state = 0;   
               
    end
         
    // Temporary stuff
    assign CACHE_READY    = 1;
    assign CACHE_PIPE_ENB = VICTIM_CACHE_READY;
    assign MAIN_PIPE_ENB  = 1;
    assign evict          = 0;
    assign ADDR_FROM_PROC_SEL = 1;
        
    // Log value calculation
    function integer logb2;
       input integer depth;
       for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
           depth = depth >> 1;
    endfunction

    
endmodule
