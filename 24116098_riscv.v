module riscv_processor #(
    parameter RESET_ADDR = 32'h00000000,
    parameter ADDR_WIDTH = 32
)(
    input clk,
    output [31:0] mem_addr,
    output [31:0] mem_wdata,
    output [3:0]  mem_wmask,
    input  [31:0] mem_rdata,
    output        mem_rstrb,
    input         mem_rbusy,
    input         mem_wbusy,
    input         reset
);

    // Core Registers
    reg [31:0] pc;
    reg [31:0] ir;
    reg [31:0] regs [1:31]; 
    
    // Finite State Machine 
    localparam S_FETCH      = 0;
    localparam S_FETCH_WAIT = 1;
    localparam S_EXEC       = 2;
    localparam S_LOAD_WAIT  = 3;
    localparam S_STORE_WAIT = 4;
    reg [2:0] state;

    // Instruction Decoding
    wire [6:0] opcode = ir[6:0];
    wire [4:0] rd     = ir[11:7];
    wire [2:0] funct3 = ir[14:12];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];
    wire [6:0] funct7 = ir[31:25];

    // Immediate Generation
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{20{ir[31]}}, ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{12{ir[31]}}, ir[19:12], ir[20], ir[30:21], 1'b0};

    // Register File Read (x0 is hardwired to 0)
    wire [31:0] val_rs1 = (rs1 == 0) ? 32'b0 : regs[rs1];
    wire [31:0] val_rs2 = (rs2 == 0) ? 32'b0 : regs[rs2];

    // ALU Logic
    reg [31:0] alu_out;
    always @(*) begin
        alu_out = 32'b0;
        case (opcode)
            7'b0110011: begin // R-type
                if (funct3 == 3'b000) alu_out = (funct7 == 7'b0100000) ? val_rs1 - val_rs2 : val_rs1 + val_rs2;
                else if (funct3 == 3'b100) alu_out = val_rs1 ^ val_rs2;
                else if (funct3 == 3'b110) alu_out = val_rs1 | val_rs2;
                else if (funct3 == 3'b111) alu_out = val_rs1 & val_rs2;
                else if (funct3 == 3'b001) alu_out = val_rs1 << val_rs2[4:0];
                else if (funct3 == 3'b101) begin
                    if (funct7 == 7'b0100000) alu_out = $signed(val_rs1) >>> val_rs2[4:0];
                    else alu_out = val_rs1 >> val_rs2[4:0];
                end
                else if (funct3 == 3'b010) alu_out = ($signed(val_rs1) < $signed(val_rs2)) ? 1 : 0;
                else if (funct3 == 3'b011) alu_out = (val_rs1 < val_rs2) ? 1 : 0;
            end
            7'b0010011: begin // I-type arithmetic
                if (funct3 == 3'b000) alu_out = val_rs1 + imm_i;
                else if (funct3 == 3'b100) alu_out = val_rs1 ^ imm_i;
                else if (funct3 == 3'b110) alu_out = val_rs1 | imm_i;
                else if (funct3 == 3'b111) alu_out = val_rs1 & imm_i;
                else if (funct3 == 3'b001) alu_out = val_rs1 << imm_i[4:0];
                else if (funct3 == 3'b101) begin
                    if (funct7[5]) alu_out = $signed(val_rs1) >>> imm_i[4:0];
                    else alu_out = val_rs1 >> imm_i[4:0];
                end
                else if (funct3 == 3'b010) alu_out = ($signed(val_rs1) < $signed(imm_i)) ? 1 : 0;
                else if (funct3 == 3'b011) alu_out = (val_rs1 < imm_i) ? 1 : 0;
            end
            7'b0000011: alu_out = val_rs1 + imm_i; // Load
            7'b0100011: alu_out = val_rs1 + imm_s; // Store
            7'b1101111: alu_out = pc + 4;          // JAL
            7'b1100111: alu_out = pc + 4;          // JALR
            7'b0110111: alu_out = imm_u;           // LUI
            7'b0010111: alu_out = pc + imm_u;      // AUIPC
            default: alu_out = 32'b0;
        endcase
    end

    // Branch Logic
    reg take_branch;
    always @(*) begin
        case (funct3)
            3'b000: take_branch = (val_rs1 == val_rs2);                  // BEQ
            3'b001: take_branch = (val_rs1 != val_rs2);                  // BNE
            3'b100: take_branch = ($signed(val_rs1) < $signed(val_rs2)); // BLT
            3'b101: take_branch = ($signed(val_rs1) >= $signed(val_rs2));// BGE
            3'b110: take_branch = (val_rs1 < val_rs2);                   // BLTU
            3'b111: take_branch = (val_rs1 >= val_rs2);                  // BGEU
            default: take_branch = 0;
        endcase
    end

    // PC Update Logic
    reg [31:0] next_pc;
    always @(*) begin
        next_pc = pc + 4; 
        if (opcode == 7'b1100011 && take_branch) next_pc = pc + imm_b;
        else if (opcode == 7'b1101111) next_pc = pc + imm_j; 
        else if (opcode == 7'b1100111) next_pc = (val_rs1 + imm_i) & ~32'b1;
    end

    // Memory Store Alignment
    wire [1:0] align = alu_out[1:0];
    reg [31:0] wdata_combo;
    reg [3:0]  wmask_combo;
    always @(*) begin
        wdata_combo = val_rs2;
        wmask_combo = 4'b0000;
        if (funct3 == 3'b000) begin // SB
            wdata_combo = val_rs2 << (align * 8);
            wmask_combo = 4'b0001 << align;
        end else if (funct3 == 3'b001) begin // SH
            wdata_combo = val_rs2 << (align * 8);
            wmask_combo = 4'b0011 << align;
        end else if (funct3 == 3'b010) begin // SW
            wdata_combo = val_rs2;
            wmask_combo = 4'b1111;
        end
    end

    // Memory Load Alignment
    wire [31:0] raw_read = mem_rdata >> (align * 8);
    reg [31:0] load_data;
    always @(*) begin
        case (funct3)
            3'b000: load_data = {{24{raw_read[7]}}, raw_read[7:0]};   // LB
            3'b001: load_data = {{16{raw_read[15]}}, raw_read[15:0]}; // LH
            3'b010: load_data = raw_read;                             // LW
            3'b100: load_data = {24'b0, raw_read[7:0]};               // LBU
            3'b101: load_data = {16'b0, raw_read[15:0]};              // LHU
            default: load_data = raw_read;
        endcase
    end

    // Register Write Enable
    reg write_reg;
    reg [31:0] reg_wdata;
    always @(*) begin
        write_reg = 0;
        reg_wdata = alu_out;
        case (opcode)
            7'b0110011, 7'b0010011, 7'b0110111, 
            7'b0010111, 7'b1101111, 7'b1100111: write_reg = 1;
            7'b0000011: write_reg = 1; 
        endcase
    end

    // Memory Interface Routing 
    
    // Hold address stable during ALL wait states
    assign mem_addr  = (state == S_FETCH || state == S_FETCH_WAIT) ? pc : alu_out;
    
    // Strobe drops the instant mem_rbusy drops
    assign mem_rstrb = (state == S_FETCH) || 
                       (state == S_FETCH_WAIT && mem_rbusy) || 
                       (opcode == 7'b0000011 && state == S_EXEC) || 
                       (state == S_LOAD_WAIT && mem_rbusy);
                       
    assign mem_wdata = wdata_combo;
    
    // Mask drops the instant mem_wbusy drops
    assign mem_wmask = (opcode == 7'b0100011 && state == S_EXEC) ? wmask_combo : 
                       (state == S_STORE_WAIT && mem_wbusy) ? wmask_combo : 4'b0000;

    // FSM State Transitions
    
    integer i;
    always @(posedge clk) begin
        if (!reset) begin 
            pc <= RESET_ADDR;
            state <= S_FETCH;
            for (i=1; i<32; i=i+1) regs[i] <= 32'b0;
        end else begin
            case (state)
                S_FETCH: begin
                    if (!mem_rbusy && !mem_wbusy) state <= S_FETCH_WAIT;
                end
                
                S_FETCH_WAIT: begin
                    if (!mem_rbusy) begin
                        ir <= mem_rdata;
                        state <= S_EXEC;
                    end
                end
                
                S_EXEC: begin
                    if (opcode == 7'b0000011) begin
                        state <= S_LOAD_WAIT; 
                    end else if (opcode == 7'b0100011) begin
                        state <= S_STORE_WAIT; 
                    end else begin
                        if (write_reg && rd != 0) regs[rd] <= reg_wdata;
                        pc <= next_pc;
                        state <= S_FETCH;
                    end
                end
                
                S_LOAD_WAIT: begin
                    if (!mem_rbusy) begin
                        if (write_reg && rd != 0) regs[rd] <= load_data;
                        pc <= next_pc;
                        state <= S_FETCH;
                    end
                end
                
                S_STORE_WAIT: begin
                    if (!mem_wbusy) begin
                        pc <= next_pc;
                        state <= S_FETCH;
                    end
                end
            endcase
        end
    end
endmodule