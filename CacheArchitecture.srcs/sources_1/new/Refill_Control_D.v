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
    
    assign CACHE_READY = 1;
endmodule
