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
        
        // Outputs to the main processor pipeline		
        output CACHE_READY,                         // Signal from cache to processor that its pipeline is currently ready to work  
                
        // Related to Address to L2 buffers
        output SEND_RD_ADDR_TO_L2,                  // Valid signal for the input of Addr_to_L2 section   
                
        // Related to controlling the pipeline
        output PC_PIPE_ENB,                         // Enable for main pipeline registers
        output ADDR_FROM_PROC_SEL                   // addr_from_proc_sel = {0(addr_from_proc_del_2), 1 (ADDR_FROM_PROC)}    
    );
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Refill request queue management                                                              //
    //////////////////////////////////////////////////////////////////////////////////////////////////
            
    // PCs of the currently being fetched requests are stored. Max number of requests is 4.
    // Three is for IF1, IF2, IF3 and last is for early restart
    reg [TAG_WIDTH      - 1 : 0] cur_tag,  fir_tag,  sec_tag,  thr_tag;         // Tag for the L1 write
    reg [TAG_WIDTH      - 1 : 0] cur_vtag, fir_vtag, sec_vtag, thr_vtag;        // Tag for the victim cache
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line, fir_line, sec_line, thr_line;        // Cache block to write to (for L1 and victim)
    reg [T              - 1 : 0] cur_sect, fir_sect, sec_sect, thr_sect;        // Section within block to write first (for L1 and victim)
    
    reg [1              - 1 : 0] cur_src,  fir_src,  sec_src,  thr_src;         // Source = whether to refill from L2 (0) or from victim cache (1) 
    reg [ASSOCIATIVITY  - 1 : 0] cur_set,  fir_set,  sec_set,  thr_set;         // Set = destination set of the request (in one hot format)
    reg [1              - 1 : 0] cur_dir,  fir_dir,  sec_dir,  thr_dir;         // Whether filling the victim cache is necessary
    reg [1              - 1 : 0] cur_ctrl, fir_ctrl, sec_ctrl, thr_ctrl;        // Control signals to be sent towards L2
        
    reg [TAG_WIDTH      - 1 : 0] cur_tag_wire,  fir_tag_wire,  sec_tag_wire,  thr_tag_wire;
    reg [TAG_WIDTH      - 1 : 0] cur_vtag_wire, fir_vtag_wire, sec_vtag_wire, thr_vtag_wire;
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line_wire, fir_line_wire, sec_line_wire, thr_line_wire;
    reg [T              - 1 : 0] cur_sect_wire, fir_sect_wire, sec_sect_wire, thr_sect_wire;
    reg [1              - 1 : 0] cur_src_wire,  fir_src_wire,  sec_src_wire,  thr_src_wire;
    reg [ASSOCIATIVITY  - 1 : 0] cur_set_wire,  fir_set_wire,  sec_set_wire,  thr_set_wire;
    reg [1              - 1 : 0] cur_dir_wire,  fir_dir_wire,  sec_dir_wire,  thr_dir_wire;        
    reg [1              - 1 : 0] cur_ctrl_wire, fir_ctrl_wire, sec_ctrl_wire, thr_ctrl_wire;     
             
    // To get admitted to the refill queue, several tests must be passed, and also it mustn't readmit a completed refill
    // (L2 misses, PC pipe disables, IF pipe saturated with PC value, L2 completes and removes from queue, but still IF pipe
    // saturated, this causes a miss, and readmit)
        
        // Solution - Admission only if the IF3 request came from a valid PC on the PC pipeline
        reg pc_pipe_enb_del_1, pc_pipe_enb_del_2;
        
        always @(posedge CLK) begin
            pc_pipe_enb_del_1 <= PC_PIPE_ENB;
            pc_pipe_enb_del_2 <= pc_pipe_enb_del_1;
        end    
        
        // Whether to admit to or remove from the refill queue
        wire admit, remove;
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
                    cur_tag_wire  = (no_of_elements == 4'b0000)? REFILL_REQ_TAG  : cur_tag;
                    cur_line_wire = (no_of_elements == 4'b0000)? REFILL_REQ_LINE : cur_line;
                    cur_sect_wire = (no_of_elements == 4'b0000)? REFILL_REQ_SECT : cur_sect;
                    cur_src_wire  = (no_of_elements == 4'b0000)? refill_req_src  : cur_src;
                    cur_set_wire  = (no_of_elements == 4'b0000)? refill_req_dst_del_1  : cur_set;
                    
                    fir_tag_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_TAG  : fir_tag;
                    fir_line_wire = (no_of_elements == 4'b0001)? REFILL_REQ_LINE : fir_line;
                    fir_sect_wire = (no_of_elements == 4'b0001)? REFILL_REQ_SECT : fir_sect;
                    fir_src_wire  = (no_of_elements == 4'b0001)? refill_req_src  : fir_src;
                    fir_set_wire  = (no_of_elements == 4'b0001)? refill_req_dst_del_1  : fir_set;
                    
                    sec_tag_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_TAG  : sec_tag;
                    sec_line_wire = (no_of_elements == 4'b0011)? REFILL_REQ_LINE : sec_line;
                    sec_sect_wire = (no_of_elements == 4'b0011)? REFILL_REQ_SECT : sec_sect;
                    sec_src_wire  = (no_of_elements == 4'b0011)? refill_req_src  : sec_src;
                    sec_set_wire  = (no_of_elements == 4'b0011)? refill_req_dst_del_1  : sec_set;
                    
                    thr_tag_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_TAG  : thr_tag;
                    thr_line_wire = (no_of_elements == 4'b0111)? REFILL_REQ_LINE : thr_line;
                    thr_sect_wire = (no_of_elements == 4'b0111)? REFILL_REQ_SECT : thr_sect;
                    thr_src_wire  = (no_of_elements == 4'b0111)? refill_req_src  : thr_src;
                    thr_set_wire  = (no_of_elements == 4'b0111)? refill_req_dst_del_1  : thr_set;
                end
                2'b01 : begin
                    cur_tag_wire  = fir_tag;
                    cur_line_wire = fir_line;
                    cur_sect_wire = fir_sect;
                    cur_src_wire  = fir_src;
                    cur_set_wire  = fir_set;
                    
                    fir_tag_wire  = sec_tag;
                    fir_line_wire = sec_line;
                    fir_sect_wire = sec_sect;
                    fir_src_wire  = sec_src;
                    fir_set_wire  = sec_set;
                    
                    sec_tag_wire  = thr_tag;
                    sec_line_wire = thr_line;
                    sec_sect_wire = thr_sect;
                    sec_src_wire  = thr_src;
                    sec_set_wire  = thr_set;
                    
                    thr_tag_wire  = 0;
                    thr_line_wire = 0;
                    thr_sect_wire = 0;
                    thr_src_wire  = 0;
                    thr_set_wire  = 0;
                end
                2'b11 : begin
                    cur_tag_wire  = (no_of_elements == 4'b0001)? REFILL_REQ_TAG  : fir_tag;
                    cur_line_wire = (no_of_elements == 4'b0001)? REFILL_REQ_LINE : fir_line;
                    cur_sect_wire = (no_of_elements == 4'b0001)? REFILL_REQ_SECT : fir_sect;
                    cur_src_wire  = (no_of_elements == 4'b0001)? refill_req_src  : fir_src;
                    cur_set_wire  = (no_of_elements == 4'b0001)? refill_req_dst_del_1  : fir_set;
                    
                    fir_tag_wire  = (no_of_elements == 4'b0011)? REFILL_REQ_TAG  : sec_tag;
                    fir_line_wire = (no_of_elements == 4'b0011)? REFILL_REQ_LINE : sec_line;
                    fir_sect_wire = (no_of_elements == 4'b0011)? REFILL_REQ_SECT : sec_sect;
                    fir_src_wire  = (no_of_elements == 4'b0011)? refill_req_src  : sec_src;
                    fir_set_wire  = (no_of_elements == 4'b0011)? refill_req_dst_del_1  : sec_set;
                    
                    sec_tag_wire  = (no_of_elements == 4'b0111)? REFILL_REQ_TAG  : thr_tag;
                    sec_line_wire = (no_of_elements == 4'b0111)? REFILL_REQ_LINE : thr_line;
                    sec_sect_wire = (no_of_elements == 4'b0111)? REFILL_REQ_SECT : thr_sect;
                    sec_src_wire  = (no_of_elements == 4'b0111)? refill_req_src  : thr_src;
                    sec_set_wire  = (no_of_elements == 4'b0111)? refill_req_dst_del_1  : thr_set;
                    
                    thr_tag_wire  = (no_of_elements == 4'b1111)? REFILL_REQ_TAG  : 0;
                    thr_line_wire = (no_of_elements == 4'b1111)? REFILL_REQ_LINE : 0;
                    thr_sect_wire = (no_of_elements == 4'b1111)? REFILL_REQ_SECT : 0;
                    thr_src_wire  = (no_of_elements == 4'b1111)? refill_req_src  : 0;
                    thr_set_wire  = (no_of_elements == 4'b1111)? refill_req_dst_del_1  : 0;
                end
                2'b00 : begin
                    cur_tag_wire  = cur_tag;
                    cur_line_wire = cur_line;
                    cur_sect_wire = cur_sect;
                    cur_src_wire  = cur_src;
                    cur_set_wire  = cur_set;
                    
                    fir_tag_wire  = fir_tag;
                    fir_line_wire = fir_line;
                    fir_sect_wire = fir_sect;
                    fir_src_wire  = fir_src;
                    fir_set_wire  = fir_set;
                    
                    sec_tag_wire  = sec_tag;
                    sec_line_wire = sec_line;
                    sec_sect_wire = sec_sect;
                    sec_src_wire  = sec_src;
                    sec_set_wire  = sec_set;
                    
                    thr_tag_wire  = thr_tag;
                    thr_line_wire = thr_line;
                    thr_sect_wire = thr_sect;
                    thr_src_wire  = thr_src;
                    thr_set_wire  = thr_set;
                end
            endcase
        end
        
        always @(posedge CLK) begin
            cur_tag  <= cur_tag_wire;
            cur_line <= cur_line_wire;
            cur_sect <= cur_sect_wire;
            cur_src  <= cur_src_wire;
            cur_set  <= cur_set_wire;
            
            fir_tag  <= fir_tag_wire;
            fir_line <= fir_line_wire;
            fir_sect <= fir_sect_wire;
            fir_src  <= fir_src_wire;
            fir_set  <= fir_set_wire;
            
            sec_tag  <= sec_tag_wire;
            sec_line <= sec_line_wire;
            sec_sect <= sec_sect_wire;
            sec_src  <= sec_src_wire;
            sec_set  <= sec_set_wire;
            
            thr_tag  <= thr_tag_wire;
            thr_line <= thr_line_wire;
            thr_sect <= thr_sect_wire;
            thr_src  <= thr_src_wire;
            thr_set  <= thr_set_wire;
        end
    
endmodule
