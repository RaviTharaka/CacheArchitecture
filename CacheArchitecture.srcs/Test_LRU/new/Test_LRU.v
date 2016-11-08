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
    parameter N = 4;                         // Number of units
    
    reg CLK;
    reg [N - 1 : 0] USE;
       
    wire [N - 1 : 0] LRU;
    
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
        
        USE = 4'b0001;
        #10;
        USE = 4'b0001;
        #10;
        USE = 4'b0010;
        #10;
        USE = 4'b0100;
        #10;
        USE = 4'b0001;
        #10;
        USE = 4'b1000;
        #10;
        USE = 4'b0100;
        #10;
        USE = 4'b1000;
        #10;
        USE = 4'b1000;
        #10;
    end
    
    
    always begin
        CLK = #5 !CLK;
    end
        
        
endmodule