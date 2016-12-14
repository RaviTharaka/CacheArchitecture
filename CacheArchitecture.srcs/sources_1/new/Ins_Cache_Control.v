`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 08/21/2016 02:50:52 PM
// Design Name: 
// Module Name: Ins_Cache_Control
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


module Ins_Cache_Control #(
        // Fixed parameters
        localparam ADDR_WIDTH = 32,
        localparam DATA_WIDTH = 32,
        
        // Primary parameters
        parameter S         = 17,                    // Size of the cache will be 2^S bits
        parameter B         = 9,                     // Size of a block will be 2^B bits
        parameter a         = 1,                     // Associativity of the cache would be 2^a
        parameter T         = 3,                     // Width to depth translation amount
        parameter N         = 3,                     // Number of stream buffers
        parameter W         = 7,                     // Width of the L2-L1 bus would be 2^W
        parameter L2_DELAY  = 5,                     // Delay of the second level of cache
                
        // Calculated parameters        
        localparam ASSOCIATIVITY = 1 << a,
        localparam TAG_WIDTH = ADDR_WIDTH + 3 + a - S,
        
        localparam TAG_RAM_WIDTH = TAG_WIDTH + 1,
        localparam LINE_RAM_WIDTH   = 1 << (B - T),
        localparam L2_BUS_WIDTH     = 1 << W
    ) (
        input CLK,
        input RSTN,
        
        // Cache hit status
        input CACHE_HIT,
        input BRANCH,
        
        // Processor cache communications
        output CACHE_READY,                                         // Signal from cache to processor that its pipeline is currently ready to work
        input PROC_READY,                                           // Signal from processor to cache that its pipeline is currently ready to work
        
        // Pipeline enable signals
        output CACHE_PIPE_ENB,                                       // Enable for cache's pipeline registers
        output DATA_TO_PROC_ENB,                                     // Enable signal for the IR register
        
        // Tag memory control signals
        output TAG_MEM_RD_ENB,                                       // Common read enable for the tag memories
        
        // Line memory control signals
        output LIN_MEM_RD_ENB,                                       // Common read enables for the line memories
        output LIN_MEM_OUT_ENB                                       // Common output register enable for the line memories
       
    );
    
    assign DATA_TO_PROC_ENB = CACHE_HIT;
    assign CACHE_PIPE_ENB = 1;
    assign LIN_MEM_RD_ENB = 1;
    assign LIN_MEM_OUT_ENB = 1;
    assign TAG_MEM_RD_ENB = 1;
   
    
endmodule
