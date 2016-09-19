`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/30/2016 03:22:03 PM
// Design Name: 
// Module Name: Multiplexer_One_Hot
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


module Multiplexer_One_Hot #(
        // Primary parameters
        parameter ORDER = 5,                            // 2^ORDER to 1 multiplexer will be created
        parameter WIDTH = 2,                            // Width of the multplexer
        
        // Calculated parameters
        localparam NO_OF_INPUT_BUSES = 1 << ORDER            
    ) (
        // Inputs
        input CLK,
        input [WIDTH * NO_OF_INPUT_BUSES - 1 : 0] IN,
        input [NO_OF_INPUT_BUSES - 1 : 0] SELECT,
        
        // Outputs
        output [WIDTH - 1 : 0] OUT
    );
     
    // Temporary wires
    wire [NO_OF_INPUT_BUSES - 1 : 0] in_group [0 : WIDTH - 1];
    
    // Generation and coding variables
    genvar i, j;
       
    generate 
        for (i = 0; i < NO_OF_INPUT_BUSES; i = i + 1) begin
            for (j = 0; j < WIDTH; j = j + 1) begin
                assign in_group[j][i] = IN[i * WIDTH + j];
            end
        end
        
        for (i = 0; i < WIDTH; i = i + 1) begin
            Bit_Multiplexer_One_Hot #(
                .ORDER(ORDER)
            ) bit_mux (
                .CLK(CLK),
                .IN(in_group[i]),
                .SELECT(SELECT),
                .OUT(OUT[i])            
            );
        end
    endgenerate
endmodule

module Bit_Multiplexer_One_Hot #(
        // Primary parameters
        parameter ORDER = 1,                 // 2^ORDER to 1 multiplexer will be created
        
        // Calculated parameters
        localparam NO_OF_INPUTS = 1 << ORDER            
    ) (
        // Inputs
        input CLK,
        input [NO_OF_INPUTS - 1 : 0] IN,
        input [NO_OF_INPUTS - 1 : 0] SELECT,
        
        // Outputs
        output OUT
    );
    
    always @(*) begin
        
    end   
    
endmodule

/*
Multiplexer_One_Hot #(
    .ORDER(),
    .WIDTH()
) your_instance_name (
    .CLK(),
    .SELECT(),
    .IN(),
    .OUT()
);
*/