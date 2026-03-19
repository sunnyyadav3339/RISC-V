
//  RISC-V TESTBENCH 

`timescale 1ns/1ps

module riscv_ultimate_tb;

    reg clk;
    reg reset;
    
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wmask;
    wire [31:0] mem_rdata_wire;
    wire        mem_rstrb;
    reg         mem_rbusy;
    reg         mem_wbusy;
    reg  [31:0] mem_rdata_reg;
    
    assign mem_rdata_wire = mem_rdata_reg;

    reg [31:0] memory [0:2047]; // 8KB Memory

    //==========================================================================
    // Instantiate Processor
    //==========================================================================
    riscv_processor #(
        .RESET_ADDR(32'h00000000),
        .ADDR_WIDTH(32)
    ) uut (
        .clk(clk),
        .mem_addr(mem_addr),
        .mem_wdata(mem_wdata),
        .mem_wmask(mem_wmask),
        .mem_rdata(mem_rdata_wire),
        .mem_rstrb(mem_rstrb),
        .mem_rbusy(mem_rbusy),
        .mem_wbusy(mem_wbusy),
        .reset(reset)
    );
    
    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end
    
    //==========================================================================
    // STRICT MEMORY LATENCY MODEL (Checks for Bus Violations)
    //==========================================================================
    reg [2:0] mem_state = 0;
    reg [31:0] latched_addr;
    reg is_read = 0, is_write = 0;
    
    always @(posedge clk) begin
        if (reset) begin
            case (mem_state)
                0: begin 
                    if (mem_rstrb && !mem_rbusy) begin
                        latched_addr <= mem_addr;
                        mem_rbusy <= 1;
                        is_read <= 1;
                        mem_state <= 1;
                    end else if (mem_wmask != 4'b0000 && !mem_wbusy) begin
                        latched_addr <= mem_addr;
                        mem_wbusy <= 1;
                        is_write <= 1;
                        mem_state <= 1;
                    end
                end
                1: begin 
                    mem_state <= 2; // 2-Cycle Latency
                    
                    // PROTOCOL CHECKERS
                    if (mem_addr !== latched_addr) 
                        $display("[FATAL BUS ERROR] mem_addr changed during wait state!");
                    if (is_read && !mem_rstrb) 
                        $display("[FATAL BUS ERROR] mem_rstrb dropped before memory was ready!");
                    if (is_write && mem_wmask == 4'b0000) 
                        $display("[FATAL BUS ERROR] mem_wmask dropped before memory was ready!");
                end
                2: begin 
                    if (is_read) begin
                        mem_rdata_reg <= memory[latched_addr[31:2]];
                        mem_rbusy <= 0;
                        is_read <= 0;
                    end
                    if (is_write) begin
                        if (mem_wmask[0]) memory[latched_addr[31:2]][7:0]   <= mem_wdata[7:0];
                        if (mem_wmask[1]) memory[latched_addr[31:2]][15:8]  <= mem_wdata[15:8];
                        if (mem_wmask[2]) memory[latched_addr[31:2]][23:16] <= mem_wdata[23:16];
                        if (mem_wmask[3]) memory[latched_addr[31:2]][31:24] <= mem_wdata[31:24];
                        mem_wbusy <= 0;
                        is_write <= 0;
                    end
                    mem_state <= 0;
                end
            endcase
        end
    end

    //==========================================================================
    // ASSERTION CHECKER TASK
    //==========================================================================
    integer passed = 0;
    integer failed = 0;
    
    // FIXED: Properly dimensioned string input and string formatting
    task assert_eq;
        input [31:0] addr;
        input [31:0] expected;
        input [8*50:1] test_name; // 50-character string max
        begin
            if (memory[addr[31:2]] === expected) begin
                $display("[PASS] %0s", test_name); // %0s trims the padding
                passed = passed + 1;
            end else begin
                $display("[FAIL] %0s | Expected: %08h, Got: %08h", test_name, expected, memory[addr[31:2]]);
                failed = failed + 1;
            end
        end
    endtask

    //==========================================================================
    // TEST EXECUTION & MACHINE CODE
    //==========================================================================
    integer i;
    initial begin
        $display("==================================================");
        $display(" INITIATING ULTIMATE RISC-V EDGE-CASE SUITE ");
        $display("==================================================");
        
        // Zero out memory
        for (i=0; i<2048; i=i+1) memory[i] = 32'b0;

        // ---------------------------------------------------------------------
        // INSTRUCTION MEMORY LOAD (Pre-compiled Machine Code)
        // ---------------------------------------------------------------------
        // ALU & x0 Mutability Test
        memory[0]  = 32'hfff00093; // 00: ADDI x1, x0, -1   (x1 = 0xFFFFFFFF)
        memory[1]  = 32'h00200113; // 04: ADDI x2, x0, 2    (x2 = 2)
        memory[2]  = 32'h002081b3; // 08: ADD  x3, x1, x2   (x3 = 1)
        memory[3]  = 32'h40110233; // 0C: SUB  x4, x2, x1   (x4 = 3)
        memory[4]  = 32'h0020c2b3; // 10: XOR  x5, x1, x2   (x5 = 0xFFFFFFFD)
        memory[5]  = 32'h00f0f313; // 14: ANDI x6, x1, 15   (x6 = 15)
        memory[6]  = 32'h00a10013; // 18: ADDI x0, x2, 10   (x0 MUST REMAIN 0)
        
        memory[7]  = 32'h0c302423; // 1C: SW x3, 200(x0)
        memory[8]  = 32'h0c402623; // 20: SW x4, 204(x0)
        memory[9]  = 32'h0c502823; // 24: SW x5, 208(x0)
        memory[10] = 32'h0c602a23; // 28: SW x6, 212(x0)
        memory[11] = 32'h0c002c23; // 2C: SW x0, 216(x0)
        
        // Shifts & Comparisons
        memory[12] = 32'h00311393; // 30: SLLI x7, x2, 3    (x7 = 16)
        memory[13] = 32'h4010d413; // 34: SRAI x8, x1, 1    (x8 = 0xFFFFFFFF) [Sign Extend]
        memory[14] = 32'h0010d493; // 38: SRLI x9, x1, 1    (x9 = 0x7FFFFFFF) [Zero Extend]
        memory[15] = 32'h0020a533; // 3C: SLT  x10, x1, x2  (x10 = 1) [-1 < 2]
        memory[16] = 32'h0020b5b3; // 40: SLTU x11, x1, x2  (x11 = 0) [0xFFFFFFFF > 2]
        
        memory[17] = 32'h0c702e23; // 44: SW x7,  220(x0)
        memory[18] = 32'h0e802023; // 48: SW x8,  224(x0)
        memory[19] = 32'h0e902223; // 4C: SW x9,  228(x0)
        memory[20] = 32'h0ea02423; // 50: SW x10, 232(x0)
        memory[21] = 32'h0eb02623; // 54: SW x11, 236(x0)
        
        // Memory Alignment & Extension (Targeting memory address 0x1000)
        memory[1024] = 32'hDEADBEEF; // Address 0x1000 holds DEADBEEF (Little Endian: EF BE AD DE)
        memory[22] = 32'h00001637; // 58: LUI x12, 0x00001  (x12 = 0x1000)
        memory[23] = 32'h00060683; // 5C: LB  x13, 0(x12)   (x13 = 0xFFFFFFEF)
        memory[24] = 32'h00164703; // 60: LBU x14, 1(x12)   (x14 = 0x000000BE)
        memory[25] = 32'h00261783; // 64: LH  x15, 2(x12)   (x15 = 0xFFFFDEAD)
        
        memory[26] = 32'h0ed02823; // 68: SW x13, 240(x0)
        memory[27] = 32'h0ee02a23; // 6C: SW x14, 244(x0)
        memory[28] = 32'h0ef02c23; // 70: SW x15, 248(x0)

        // Branches, Jumps, and AUIPC
        memory[29] = 32'h00000463; // 74: BEQ x0, x0, 8     (Jumps to 7C)
        memory[30] = 32'h06300513; // 78: ADDI x10, x0, 99  (SKIPPED)
        memory[31] = 32'h0080086f; // 7C: JAL x16, 8        (Jumps to 84, x16 = 80 = 0x50)
        memory[32] = 32'h06300513; // 80: ADDI x10, x0, 99  (SKIPPED)
        memory[33] = 32'h00000897; // 84: AUIPC x17, 0      (x17 = PC + 0 = 0x84)

        memory[34] = 32'h0ea02e23; // 88: SW x10, 252(x0)   (Should still be 1 from earlier!)
        memory[35] = 32'h11002023; // 8C: SW x16, 256(x0)
        memory[36] = 32'h11102223; // 90: SW x17, 260(x0)

        // Halt
        memory[37] = 32'h0000006f; // 94: JAL x0, 0 (Infinite Loop to halt)

        // ---------------------------------------------------------------------
        // RUN SIMULATION
        // ---------------------------------------------------------------------
        mem_rbusy = 0; mem_wbusy = 0;
        reset = 0;
        #20 reset = 1;

        // Wait until the processor hits the Halt instruction (PC = 0x94)
        wait(uut.pc == 32'h00000094);
        #50; // Give it a few extra cycles to settle the final write
        
        $display("\n==================================================");
        $display(" EVALUATING ASSERTIONS ");
        $display("==================================================");
        
        assert_eq(200, 32'h00000001, "ADD  (Negative + Positive)");
        assert_eq(204, 32'h00000003, "SUB  (Positive - Negative)");
        assert_eq(208, 32'hFFFFFFFD, "XOR  (Negative ^ Positive)");
        assert_eq(212, 32'h0000000F, "ANDI (Masking operation)");
        assert_eq(216, 32'h00000000, "x0 Immutability (Tried to write 12)");
        
        assert_eq(220, 32'h00000010, "SLLI (Logical Shift Left)");
        assert_eq(224, 32'hFFFFFFFF, "SRAI (Arithmetic Shift Right Sign Ext)");
        assert_eq(228, 32'h7FFFFFFF, "SRLI (Logical Shift Right Zero Ext)");
        assert_eq(232, 32'h00000001, "SLT  (Signed: -1 < 2)");
        assert_eq(236, 32'h00000000, "SLTU (Unsigned: 0xFFFFFFFF > 2)");
        
        assert_eq(240, 32'hFFFFFFEF, "LB   (Load Byte Signed Extension)");
        assert_eq(244, 32'h000000BE, "LBU  (Load Byte Unaligned Zero Ext)");
        assert_eq(248, 32'hFFFFDEAD, "LH   (Load Halfword Unaligned Sign Ext)");
        
        assert_eq(252, 32'h00000001, "BEQ  (Branch Taken, bypassed instruction)");
        
        // FIXED: Expected address is 0x80 (128 decimal), not 0x50.
        assert_eq(256, 32'h00000080, "JAL  (Return address correctly saved)");
        
        assert_eq(260, 32'h00000084, "AUIPC (PC relative addressing absolute)");

        $display("\n==================================================");
        $display(" FINAL SCORE: %0d / %0d PASSED", passed, passed+failed);
        if (failed == 0) $display(" VERDICT: FLAWLESS EXECUTION (100%) ");
        else $display(" VERDICT: NEEDS DEBUGGING ");
        $display("==================================================\n");
        $finish;
    end
endmodule