`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/27/2016 12:24:16 PM
// Design Name: 
// Module Name: Refill_Control
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


module Refill_Control #(
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
        input                           CLK,
        
        // Current request at IF3
        input                           CACHE_HIT,                      // Whether the L1 cache hits or misses 
        input                           STREAM_HIT,                     // Whether any of the stream buffers hit
        input [STREAM_SEL_BITS - 1 : 0] STREAM_SRC,                     // Which stream buffer is hitting, garbage if it doesn't
        input [TAG_WIDTH       - 1 : 0] REFILL_REQ_TAG,                 // Tag portion of the PC at IF3
        input [TAG_ADDR_WIDTH  - 1 : 0] REFILL_REQ_LINE,                // Line portion of the PC at IF3
        input [T               - 1 : 0] REFILL_REQ_SECT,                // Section portion of the PC at IF3
        input [ASSOCIATIVITY   - 1 : 0] REFILL_REQ_DST,                 // Destination set for the request at IF3, if cache misses
        
        // Signals coming from outside the cache
        input                           BRANCH,                         // Branch command from EXE stage
                
        // Command fetch queue to send current IF3 address to L2
        output                          SEND_ADDR_TO_L2,
        
        // Data coming back from L2
        input [STREAM_SEL_BITS - 1 : 0] DATA_FROM_L2_SRC,
        input                           DATA_FROM_L2_BUFFER_VALID,
        output                          DATA_FROM_L2_BUFFER_READY,
        output                          ONGOING_QUEUE_RD_ENB,
        
        // Prefetch controller
        output                          SECTION_COMMIT,
        
        // Tag memories and line memories
        output [ASSOCIATIVITY   - 1 : 0] TAG_MEM_WR_ENB,                // Individual write enables for the tag memories
        output [TAG_ADDR_WIDTH  - 1 : 0] TAG_MEM_WR_ADDR,               // Common write address for the the tag memories 
        output [TAG_WIDTH       - 1 : 0] TAG_MEM_TAG_IN,                // Common data in for the tag memories    
        output [BLOCK_SECTIONS  - 1 : 0] TAG_MEM_TAG_VALID_IN,          // Common data in for the tag memories   
        output [ASSOCIATIVITY   - 1 : 0] LIN_MEM_WR_ENB,                // Individual write enables for the line memories
        output [LINE_ADDR_WIDTH - 1 : 0] LIN_MEM_WR_ADDR,               // Common write address for the line memories                  
        output [STREAM_SEL_BITS - 1 : 0] LIN_MEM_DATA_IN_SEL,           // 0 for L2 requests, buffer number for others
         
        // Enable and PC select for the PC (main processor) pipeline
        output                           PC_PIPE_ENB,                   // Enable for the main pipeline 
        output [1                   : 0] PC_SEL                         // Mux select for PC [pc_sel = {0(PC + 4), 1(Branch path), 2 or 3(PC delay 2)}]  
    );
    
    // If the stream buffers doesn't hit, it means a priority address request to L2 (src == 00)
    wire [STREAM_SEL_BITS - 1 : 0] refill_req_src = (STREAM_HIT)? STREAM_SRC : 0;
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Refill request queue management                                                              //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    // PCs of the currently being fetched requests are stored. Max number of requests is 4.
    // Three is for IF1, IF2, IF3 and last is for early restart
    reg [TAG_WIDTH      - 1 : 0] cur_tag,  fir_tag,  sec_tag,  thr_tag;
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line, fir_line, sec_line, thr_line;
    reg [T              - 1 : 0] cur_sect, fir_sect, sec_sect, thr_sect;
    
    // Set = destination set of the request, Source = which stream buffer (or L2) the request is coming from
    reg [N              - 1 : 0] cur_src,  fir_src,  sec_src,  thr_src;
    reg [ASSOCIATIVITY  - 1 : 0] cur_set,  fir_set,  sec_set,  thr_set;
    
    // To get admitted to the refill queue, several tests must be passed, and also it mustn't readmit a completed refill
    // (L2 misses, PC pipe disables, IF pipe saturated with PC value, L2 completes and removes from queue, but still IF pipe
    // saturated, this causes a miss, and readmit)
    
    // Solution - Admission only if the IF3 request came from a valid PC on the PC pipeline
    reg pc_pipe_enb_del_1, pc_pipe_enb_del_2;
    always @(posedge CLK) begin
        pc_pipe_enb_del_1 <= PC_PIPE_ENB;
        pc_pipe_enb_del_2 <= pc_pipe_enb_del_1;
    end    
    
    wire admit, remove;
    reg test_pass;
    assign admit = test_pass & !CACHE_HIT & pc_pipe_enb_del_2;
    
    // Number of elements in the queue
    reg [3 : 0] no_of_elements;
    always @(posedge CLK) begin
        case ({admit, remove})
            2'b00 : no_of_elements <= no_of_elements;
            2'b01 : no_of_elements <= no_of_elements >> 1;
            2'b10 : no_of_elements <= (no_of_elements << 1) | 4'b0001;
            2'b11 : no_of_elements <= no_of_elements;
        endcase
    end
    
    // Basically a queue, but each element is accessible to the outside, to run the tests
    always @(posedge CLK) begin
        if (admit & !remove) begin
            case (no_of_elements)
                4'b0000 : begin
                         cur_tag  <= REFILL_REQ_TAG;
                         cur_line <= REFILL_REQ_LINE;
                         cur_sect <= REFILL_REQ_SECT;
                         cur_src  <= refill_req_src;
                         cur_set  <= REFILL_REQ_DST;       
                       end
                4'b0001 : begin
                         fir_tag  <= REFILL_REQ_TAG;
                         fir_line <= REFILL_REQ_LINE;
                         fir_sect <= REFILL_REQ_SECT;
                         fir_src  <= refill_req_src;
                         fir_set  <= REFILL_REQ_DST;       
                       end
                4'b0011 : begin
                         sec_tag  <= REFILL_REQ_TAG;
                         sec_line <= REFILL_REQ_LINE;
                         sec_sect <= REFILL_REQ_SECT;
                         sec_src  <= refill_req_src;
                         sec_set  <= REFILL_REQ_DST;       
                       end
                4'b0111 : begin
                         thr_tag  <= REFILL_REQ_TAG;
                         thr_line <= REFILL_REQ_LINE;
                         thr_sect <= REFILL_REQ_SECT;
                         thr_src  <= refill_req_src;
                         thr_set  <= REFILL_REQ_DST;       
                       end
            endcase
        end else if (!admit & remove) begin
            cur_tag  <= fir_tag;
            cur_line <= fir_line;
            cur_sect <= fir_sect;
            cur_src  <= fir_src;
            cur_set  <= fir_set;  
              
            fir_tag  <= sec_tag;
            fir_line <= sec_line;
            fir_sect <= sec_sect;
            fir_src  <= sec_src;
            fir_set  <= sec_set;
                
            sec_tag  <= thr_tag;
            sec_line <= thr_line;
            sec_sect <= thr_sect;
            sec_src  <= thr_src;
            sec_set  <= thr_set; 
               
            thr_tag  <= 0;
            thr_line <= 0;
            thr_sect <= 0;
            thr_src  <= 0;
            thr_set  <= 0;    
        end else if (admit & remove) begin
            if (no_of_elements == 4'b0001) begin
                cur_tag  <= REFILL_REQ_TAG;
                cur_line <= REFILL_REQ_LINE;
                cur_sect <= REFILL_REQ_SECT;
                cur_src  <= refill_req_src;
                cur_set  <= REFILL_REQ_DST;       
            end else begin
                cur_tag  <= fir_tag;
                cur_line <= fir_line;
                cur_sect <= fir_sect;
                cur_src  <= fir_src;
                cur_set  <= fir_set;  
            end
            
            if (no_of_elements == 4'b0011) begin
                fir_tag  <= REFILL_REQ_TAG;
                fir_line <= REFILL_REQ_LINE;
                fir_sect <= REFILL_REQ_SECT;
                fir_src  <= refill_req_src;
                fir_set  <= REFILL_REQ_DST;        
            end else begin
                fir_tag  <= sec_tag;
                fir_line <= sec_line;
                fir_sect <= sec_sect;
                fir_src  <= sec_src;
                fir_set  <= sec_set;
            end
            
            if (no_of_elements == 4'b0111) begin
                sec_tag  <= REFILL_REQ_TAG;
                sec_line <= REFILL_REQ_LINE;
                sec_sect <= REFILL_REQ_SECT;
                sec_src  <= refill_req_src;
                sec_set  <= REFILL_REQ_DST;        
            end else begin
                sec_tag  <= thr_tag;
                sec_line <= thr_line;
                sec_sect <= thr_sect;
                sec_src  <= thr_src;
                sec_set  <= thr_set; 
            end
            
            if (no_of_elements == 4'b1111) begin
                thr_tag  <= REFILL_REQ_TAG;
                thr_line <= REFILL_REQ_LINE;
                thr_sect <= REFILL_REQ_SECT;
                thr_src  <= refill_req_src;
                thr_set  <= REFILL_REQ_DST;   
            end else begin
                thr_tag  <= 0;
                thr_line <= 0;
                thr_sect <= 0;
                thr_src  <= 0;
                thr_set  <= 0;    
            end
        end
    end
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Tests to decide whether to include the IF3 request in to the queue                           //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    // Tests - Clash with nth request
    wire clash_n0 = (REFILL_REQ_LINE == cur_line) & (REFILL_REQ_DST == cur_set) & no_of_elements[0];
    wire clash_n1 = (REFILL_REQ_LINE == fir_line) & (REFILL_REQ_DST == fir_set) & no_of_elements[1];
    wire clash_n2 = (REFILL_REQ_LINE == sec_line) & (REFILL_REQ_DST == sec_set) & no_of_elements[2];
    
    // Tests - Equal with nth request
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
            test_pass = 1;
        end    
    end
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // FSM for refill control                                                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
    
    localparam IDLE       = 0;
    localparam TRANSITION = 1;
    localparam WRITING_SB = 2;
    localparam WRITING_L2 = 3;
    
    reg [1 : 0] refill_state, refill_state_wire;
    reg [T - 1 : 0] no_completed, no_completed_wire;
    reg [BLOCK_SECTIONS - 1 : 0] commited_sections, commited_sections_wire;
    
    integer i;
    
    always @(*) begin
        case (refill_state)
            IDLE : begin
                case ({CACHE_HIT, STREAM_HIT})
                    2'b00 :  begin
                        refill_state_wire = WRITING_L2;
                        no_completed_wire = 0;
                        commited_sections_wire = 0;
                    end
                    2'b01 :  begin
                        refill_state_wire = WRITING_SB;
                        no_completed_wire = 1;
                        for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
                            commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
                        end
                    end
                    2'b10 :  begin
                        refill_state_wire = IDLE;
                        no_completed_wire = 0;
                        commited_sections_wire = 0;
                    end 
                    2'b11 :  begin
                        refill_state_wire = IDLE;
                        no_completed_wire = 0;
                        commited_sections_wire = 0;
                    end
                endcase              
            end
            
            TRANSITION : begin
                if (cur_src != 0) begin
                    refill_state_wire = WRITING_SB;
                    no_completed_wire = 1;
                    for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
                        commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
                    end
                end else begin
                    if (DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & DATA_FROM_L2_SRC == 0) begin
                        refill_state_wire = WRITING_L2;
                        no_completed_wire = 1;
                        for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
                            commited_sections_wire[i] = (i[T - 1 : 0] == REFILL_REQ_SECT);
                        end
                    end else begin
                        refill_state_wire = WRITING_L2;
                        no_completed_wire = 0;
                        commited_sections_wire = 0;
                    end
                end
            end
            
            WRITING_SB : begin
                // When whole block is finished, go to idle state or transition state
                if (no_completed == {T{1'b1}}) begin
                    if (no_of_elements == 4'b0001 & !admit) begin
                        refill_state_wire = IDLE;
                    end else begin
                        refill_state_wire = TRANSITION;
                    end 
                end else begin
                    refill_state_wire = refill_state;                    
                end
                
                for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
                    if (i[T - 1 : 0] == cur_sect + no_completed) begin
                        commited_sections_wire[i] = 1; 
                    end else begin
                        commited_sections_wire[i] = commited_sections[i];
                    end                       
                end
                
                no_completed_wire = no_completed + 1;
            end
            
            WRITING_L2 : begin
                if (DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & (DATA_FROM_L2_SRC == 0)) begin
                    // When whole block is fetched, go to idle state or transition
                    if (no_completed == {T{1'b1}}) begin
                        if (no_of_elements == 4'b0001 & !admit) begin
                            refill_state_wire = IDLE;
                        end else begin
                            refill_state_wire = TRANSITION;
                        end  
                    end else begin
                        refill_state_wire = refill_state;
                    end
                    
                    for (i = 0; i < BLOCK_SECTIONS; i = i + 1) begin
                        if (i[T - 1 : 0] == cur_sect + no_completed) begin
                            commited_sections_wire[i] = 1; 
                        end else begin
                            commited_sections_wire[i] = commited_sections[i];
                        end                       
                    end
                                            
                    no_completed_wire = no_completed + 1;                                        
                end else begin
                    no_completed_wire = no_completed;
                    refill_state_wire = refill_state;
                    commited_sections_wire = commited_sections;
                end        
            end
        endcase
    end
    
    always @(posedge CLK) begin
        no_completed <= no_completed_wire;
        refill_state <= refill_state_wire;
        commited_sections <= commited_sections_wire;
    end
    
    assign remove = ((refill_state == WRITING_L2) & DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & (DATA_FROM_L2_SRC == 0) & (no_completed == {T{1'b1}}))
                            | ((refill_state == WRITING_SB) & (no_completed == {T{1'b1}}));
        
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for writing to tag memory and line memory                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
         
    // Addresses        
    assign TAG_MEM_WR_ADDR      = (no_of_elements == 0)? REFILL_REQ_LINE : cur_line;
    assign LIN_MEM_WR_ADDR      = (no_of_elements == 0)? ({REFILL_REQ_LINE, REFILL_REQ_SECT}) : ({cur_line, (cur_sect + no_completed)});
    
    // Data
    assign TAG_MEM_TAG_IN       = (no_of_elements == 0)? REFILL_REQ_TAG : cur_tag;
    assign TAG_MEM_TAG_VALID_IN = commited_sections_wire;
    assign LIN_MEM_DATA_IN_SEL  = (no_of_elements == 0)? refill_req_src : cur_src;
    
    // Write enables
    reg write_test;
    always @(*) begin
        case (refill_state) 
            IDLE        :   write_test = !CACHE_HIT & STREAM_HIT;
            TRANSITION  :   write_test = (cur_src != 0);
            WRITING_SB  :   write_test = 1'b1;
            WRITING_L2  :   write_test = DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & (DATA_FROM_L2_SRC == 0);
        endcase
    end
    
    assign TAG_MEM_WR_ENB       = ((no_of_elements == 0)? REFILL_REQ_DST : cur_set) & {ASSOCIATIVITY{write_test}};
    assign LIN_MEM_WR_ENB       = ((no_of_elements == 0)? REFILL_REQ_DST : cur_set) & {ASSOCIATIVITY{write_test}};
       
       
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for Data from L2 and prefetch control unit                                      //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    assign SECTION_COMMIT = (refill_state == WRITING_SB) | (refill_state == IDLE & !CACHE_HIT & STREAM_HIT) | (refill_state == TRANSITION & (cur_src != 0));
    
    assign DATA_FROM_L2_BUFFER_READY = (refill_state == WRITING_L2) | (refill_state == TRANSITION & cur_src == 0);
    assign ONGOING_QUEUE_RD_ENB = ((refill_state == WRITING_L2) & DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY 
                                        & (DATA_FROM_L2_SRC == 0) & (no_completed == {T{1'b1}}));   
            
        
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for Address to L2 modules                                                       //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    // Address sent to L2 only if its admitted to queue and its not a stream hit
    assign SEND_ADDR_TO_L2 = admit & !STREAM_HIT;
        
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Instructions for main pipeline and PC select                                                 //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    // Enabling the PC pipeline 
    reg pc_pipe_enb_reg;
    reg [1 : 0] no_of_pc_sent;
    assign PC_PIPE_ENB = pc_pipe_enb_reg;
    
    always @(posedge CLK) begin
        case (refill_state)
            IDLE       : pc_pipe_enb_reg <= CACHE_HIT | STREAM_HIT;
            WRITING_SB : pc_pipe_enb_reg <= CACHE_HIT; 
        endcase
    
    
        if (!CACHE_HIT & !STREAM_HIT) begin
            pc_pipe_enb_reg <= 1'b0;    
        end else if (DATA_FROM_L2_BUFFER_VALID & DATA_FROM_L2_BUFFER_READY & DATA_FROM_L2_SRC == 0) begin
            pc_pipe_enb_reg <= 1'b1;
        end
    end
    
    always @(posedge CLK) begin
        if (!CACHE_HIT & !STREAM_HIT) begin
            no_of_pc_sent <= 0;
        end else begin
            if (pc_pipe_enb_reg) begin
                no_of_pc_sent <= no_of_pc_sent + 1;
            end
        end
    end
    
    assign PC_SEL = {(no_of_pc_sent < 3) , BRANCH};
    
    
    //////////////////////////////////////////////////////////////////////////////////////////////////
    // Initial conditions - for simulation                                                          //
    //////////////////////////////////////////////////////////////////////////////////////////////////
        
    initial begin
        no_of_elements = 0;
        refill_state = 0;   
        pc_pipe_enb_reg = 1; 
        pc_pipe_enb_del_1 = 1;
        pc_pipe_enb_del_2 = 1;
    end
    
    
    
   // Log value calculation
   function integer logb2;
       input integer depth;
       for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
           depth = depth >> 1;
   endfunction
  
endmodule
