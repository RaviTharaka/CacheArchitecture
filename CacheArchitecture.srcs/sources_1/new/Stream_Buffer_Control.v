`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/07/2016 08:43:49 PM
// Design Name: 
// Module Name: Stream_Buffer_Control
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


module Stream_Buffer_Control #(
        // Primary parameters
        parameter N = 3,
        parameter ADDR_WIDTH = 5,
        parameter p = 4,
        
        // Calculated parameters
        localparam STREAM_SEL_BITS  = clogb2(N + 1)
                
    ) (
        input CLK,
        input [ADDR_WIDTH - 1 : 0] ADDR_IN,
        
        output [N - 1 : 0] STREAM_BUFFER_HIT,
        
        input PREFETCH_QUEUE_FULL,
        output PREFETCH_QUEUE_WR_ENB,
        output [ADDR_WIDTH - 1 : 0] PREFETCH_QUEUE_ADDR_IN,
        output [STREAM_SEL_BITS - 1 : 0] PREFETCH_QUEUE_SRC_IN
    );
    
    reg [STREAM_SEL_BITS - 1 : 0] use_time;
        
    Stream_Buffer_Single_Control #(
    
    ) stream_buffer_single_control (
        
    );
      
    // Log value calculation
    function integer clogb2;
        input integer depth;
        for (clogb2 = 0; depth > 0; clogb2 = clogb2 + 1)
            depth = depth >> 1;
    endfunction
   
endmodule
