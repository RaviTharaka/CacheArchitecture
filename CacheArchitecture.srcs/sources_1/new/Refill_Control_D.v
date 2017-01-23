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
        input CLK,
        
        // Current request at IF3
        input                           CACHE_HIT,                      // Whether the L1 cache hits or misses 
        input                           VICTIM_HIT,                     // Whether the victim cache has hit
        input [TAG_WIDTH       - 1 : 0] REFILL_REQ_TAG,                 // Tag portion of the PC at DM3
        input [TAG_ADDR_WIDTH  - 1 : 0] REFILL_REQ_LINE,                // Line portion of the PC at DM3
        input [T               - 1 : 0] REFILL_REQ_SECT,                // Section portion of the PC at DM3
        input [TAG_WIDTH       - 1 : 0] REFILL_REQ_VTAG,                // Tag coming out of tag memory delayed to DM3
        input [a               - 1 : 0] REFILL_REQ_DST_SET,             // Destination set for the refill
        input                           REFILL_REQ_DIRTY,               // Dirty bit coming out of tag memory delayed to DM3
        input                           REFILL_REQ_VALID,               // Valid bit coming out of tag memory delayed to DM3
        input [2               - 1 : 0] REFILL_REQ_CTRL,                // Instruction at DM3 
                                
        // Outputs to the main processor pipeline		
        output CACHE_READY,                         // Signal from cache to processor that its pipeline is currently ready to work  
                
        // Related to Address to L2 buffers
        output SEND_RD_ADDR_TO_L2,                  // Valid signal for the input of Addr_to_L2 section   
                
        // Related to controlling the pipeline
        output PC_PIPE_ENB,                         // Enable for main pipeline registers
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
    reg pc_pipe_enb_del_1, pc_pipe_enb_del_2;
        
    always @(posedge CLK) begin
        pc_pipe_enb_del_1 <= PC_PIPE_ENB;
        pc_pipe_enb_del_2 <= pc_pipe_enb_del_1;
    end    
     
    wire admit, remove;         // Whether to admit to or remove from the refill queue
    wire evict;                 // Indicates that the first eviction in the queue is complete
       
    reg test_pass;
    assign admit = test_pass & pc_pipe_enb_del_2;
        
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
        
    // Basically a queue, but each element is accessible to the outside, to run the tests
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
    
    reg [3 : 0] first_evic;
    
    always @(*) begin
        case ({thr_evic, sec_evic, fir_evic, cur_evic})
            4'b0000 : first_evic = 4'b0000;
            4'b0001 : first_evic = 4'b0001;
            4'b0010 : first_evic = 4'b0010;
            4'b0011 : first_evic = 4'b0001;
            
            4'b0100 : first_evic = 4'b0100;
            4'b0101 : first_evic = 4'b0001;
            4'b0110 : first_evic = 4'b0010;
            4'b0111 : first_evic = 4'b0001;
            
            4'b1000 : first_evic = 4'b1000;
            4'b1001 : first_evic = 4'b0001;
            4'b1010 : first_evic = 4'b0010;
            4'b1011 : first_evic = 4'b0001;
            
            4'b1100 : first_evic = 4'b0100;
            4'b1101 : first_evic = 4'b0001;
            4'b1110 : first_evic = 4'b0010;
            4'b1111 : first_evic = 4'b0001;
        endcase
    end
    
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
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : cur_evic & first_evic[0];
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : fir_evic & first_evic[1];
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : sec_evic & first_evic[2];
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : thr_evic & first_evic[3];
            end
            3'b011 : begin
                cur_evic_wire = fir_evic & first_evic[1];
                fir_evic_wire = sec_evic & first_evic[2];
                sec_evic_wire = thr_evic & first_evic[3];
                thr_evic_wire = 0;
            end
            3'b111 : begin
                cur_evic_wire = (no_of_elements == 4'b0001)? REFILL_REQ_VALID : fir_tag & first_evic[1];
                fir_evic_wire = (no_of_elements == 4'b0011)? REFILL_REQ_VALID : sec_tag & first_evic[2];
                sec_evic_wire = (no_of_elements == 4'b0111)? REFILL_REQ_VALID : thr_tag & first_evic[3];
                thr_evic_wire = (no_of_elements == 4'b1111)? REFILL_REQ_VALID : 0;
            end
            3'b001 : begin
                cur_evic_wire = cur_evic & first_evic[0];
                fir_evic_wire = fir_evic & first_evic[1];
                sec_evic_wire = sec_evic & first_evic[2];
                thr_evic_wire = thr_evic & first_evic[3];
            end
        endcase
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
    
    localparam E_HITTING = 0;
    localparam E_IDLE1   = 1;
    localparam E_IDLE2   = 2;
    
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for Address to L2 modules                                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    // Address sent to L2 only if its admitted to queue and its not a stream hit
    assign SEND_RD_ADDR_TO_L2 = admit & !VICTIM_HIT;
            
        
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Initial values                                                                               //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    initial begin
        no_of_elements = 0;
        
        pc_pipe_enb_del_2 = 1;
        pc_pipe_enb_del_1 = 1;
    end
         
    // Temporary stuff
    assign CACHE_READY    = 1;
    assign CACHE_PIPE_ENB = 1;
    assign PC_PIPE_ENB    = 1;
    assign remove         = 0;
        
    // Log value calculation
    function integer logb2;
       input integer depth;
       for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
           depth = depth >> 1;
    endfunction

    
endmodule
