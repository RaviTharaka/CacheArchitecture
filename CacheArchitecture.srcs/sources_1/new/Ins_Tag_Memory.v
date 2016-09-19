`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 07/13/2016 07:59:56 PM
// Design Name: 
// Module Name: Ins_Tag_Memory
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


module Ins_Tag_Memory(CLK, ENB, WRENB, ADDRA, DINA, ADDRB, DOUTB);
    input CLK, ENB, WRENB;
    input [15 : 0] DINA, ADDRB, ADDRA;
    
    output reg [15 : 0] DOUTB;
    
    wire [15 : 0] doutb;
    
    always @(posedge CLK) begin
        if (ENB) begin
            DOUTB <= doutb;
        end
    end
    
    blk_mem_gen_0 your_instance_name (
        .clka(CLK),         // input wire clka
        .ena(ENB),          // input wire ena
        .wea(WRENB),        // input wire [0 : 0] wea
        .addra(ADDA),       // input wire [3 : 0] addra
        .dina(DINA),        // input wire [15 : 0] dina
        .clkb(CLK),         // input wire clkb
        .enb(ENB),          // input wire enb
        .addrb(ADDRB),      // input wire [3 : 0] addrb
        .doutb(doutb)       // output wire [15 : 0] doutb
    );    
endmodule
