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
        localparam STREAM_SEL_BITS  = logb2(N + 1)
    ) (
        input CLK,
        
        // Current request at IF3
        input CACHE_HIT,
        input STREAM_HIT,
        input [TAG_WIDTH       - 1 : 0] REFILL_REQ_TAG,
        input [TAG_ADDR_WIDTH  - 1 : 0] REFILL_REQ_LINE,
        input [T               - 1 : 0] REFILL_REQ_SECT,
        input [STREAM_SEL_BITS - 1 : 0] REFILL_REQ_SRC,
        input [a               - 1 : 0] REFILL_REQ_SET,
        
        // Command fetch queue to send current IF3 address to L2
        output SEND_ADDR_TO_L2
    );
    
    // If the stream buffers doesn't hit, it means a priority address request to L2 (src == 00)
    wire [STREAM_SEL_BITS - 1 : 0] refill_req_src = (STREAM_HIT)? REFILL_REQ_SRC : 0;
    
    // PCs of the currently being fetched requests are stored. 
    // Three is for IF1, IF2, IF3 and last is for early restart
    reg [TAG_WIDTH      - 1 : 0] cur_tag,  fir_tag,  sec_tag,  thr_tag;
    reg [TAG_ADDR_WIDTH - 1 : 0] cur_line, fir_line, sec_line, thr_line;
    reg [T              - 1 : 0] cur_sect, fir_sect, sec_sect, thr_sect;
    
    // Set = which set the request hit on, Source = which stream buffer (or L2) the request is coming from
    reg [N              - 1 : 0] cur_src,  fir_src,  sec_src,  thr_src;
    reg [a              - 1 : 0] cur_set,  fir_set,  sec_set,  thr_set;
    
    // To get admitted to the refill queue, several tests must be passed
    wire admit, remove;
    reg test_pass;
    assign admit = test_pass & !CACHE_HIT;
    assign remove = 0;                                                      // temporary
    
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
                         cur_set  <= REFILL_REQ_SET;       
                       end
                4'b0001 : begin
                         fir_tag  <= REFILL_REQ_TAG;
                         fir_line <= REFILL_REQ_LINE;
                         fir_sect <= REFILL_REQ_SECT;
                         fir_src  <= refill_req_src;
                         fir_set  <= REFILL_REQ_SET;       
                       end
                4'b0011 : begin
                         sec_tag  <= REFILL_REQ_TAG;
                         sec_line <= REFILL_REQ_LINE;
                         sec_sect <= REFILL_REQ_SECT;
                         sec_src  <= refill_req_src;
                         sec_set  <= REFILL_REQ_SET;       
                       end
                4'b0111 : begin
                         thr_tag  <= REFILL_REQ_TAG;
                         thr_line <= REFILL_REQ_LINE;
                         thr_sect <= REFILL_REQ_SECT;
                         thr_src  <= refill_req_src;
                         thr_set  <= REFILL_REQ_SET;       
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
                cur_set  <= REFILL_REQ_SET;       
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
                fir_set  <= REFILL_REQ_SET;        
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
                sec_set  <= REFILL_REQ_SET;        
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
                thr_set  <= REFILL_REQ_SET;   
            end else begin
                thr_tag  <= 0;
                thr_line <= 0;
                thr_sect <= 0;
                thr_src  <= 0;
                thr_set  <= 0;    
            end
        end
    end
    
    // Tests - Clash with nth request
    wire clash_n0 = (REFILL_REQ_LINE == cur_line) & (REFILL_REQ_SET == cur_set) & no_of_elements[0];
    wire clash_n1 = (REFILL_REQ_LINE == fir_line) & (REFILL_REQ_SET == fir_set) & no_of_elements[1];
    wire clash_n2 = (REFILL_REQ_LINE == sec_line) & (REFILL_REQ_SET == sec_set) & no_of_elements[2];
    
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
    
    // Address sent to L2 only if its admitted to queue and its not a stream hit
    assign SEND_ADDR_TO_L2 = admit & !STREAM_HIT;
    
    initial begin
        no_of_elements = 0;    
    end
    
   // Log value calculation
   function integer logb2;
       input integer depth;
       for (logb2 = 0; depth > 1; logb2 = logb2 + 1)
           depth = depth >> 1;
   endfunction
  
endmodule
