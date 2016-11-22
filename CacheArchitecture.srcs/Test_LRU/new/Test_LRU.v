`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 11/08/2016 10:35:43 PM
// Design Name: 
// Module Name: LRU
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

module Test_LRU ();
    parameter N = 3;                         // Number of units
    
    reg CLK;
    reg [0 : N - 1] USE;
       
    wire [0 : N - 1] LRU;
    
    LRU #(
        .N(N)
    ) uut (
        .CLK(CLK),
        .USE(USE),
        .LRU(LRU)
    );    
    
    initial begin
        CLK = 1;
        USE = 0;
        #101;
        
        USE = 3'b001;
        #10;
        USE = 3'b001;
        #10;
        USE = 3'b000;
        #10;
        USE = 3'b010;
        #10;
        USE = 3'b001;
        #10;
        USE = 3'b100;
        #10;
        USE = 3'b010;
        #10;
        USE = 3'b100;
        #10;
        USE = 3'b100;
        #10;
    end
    
    
    always begin
        CLK = #5 !CLK;
    end
        
        
endmodule