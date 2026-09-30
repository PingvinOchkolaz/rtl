// -----------------------------------------------------------------------------
// crc — parameterised parallel CRC engine (Rocksoft/Williams model).
//
// * Any polynomial of WIDTH bits; INIT, REFIN, REFOUT and XOROUT as in the
//   CRC catalogue, e.g. CRC-32: POLY=04C11DB7 INIT=FFFFFFFF REFIN=REFOUT=1
//   XOROUT=FFFFFFFF.
// * DATA_W/8 bytes per cycle. Byte 0 (data_i[7:0]) is the first byte of the
//   message. The per-cycle update is fully unrolled combinational logic.
// * clear_i restarts the calculation; with valid_i in the same cycle the data
//   becomes the first word of the new message.
// * crc_o is the final (reflected/xor-ed) CRC of everything since the clear.
// -----------------------------------------------------------------------------
module crc #(
  parameter int unsigned      WIDTH  = 32,
  parameter logic [WIDTH-1:0] POLY   = 32'h04C1_1DB7,
  parameter logic [WIDTH-1:0] INIT   = '1,
  parameter bit               REFIN  = 1'b1,
  parameter bit               REFOUT = 1'b1,
  parameter logic [WIDTH-1:0] XOROUT = '1,
  parameter int unsigned      DATA_W = 8
) (
  input  logic              clk_i,
  input  logic              rst_ni,
  input  logic              clear_i,
  input  logic              valid_i,
  input  logic [DATA_W-1:0] data_i,
  output logic [WIDTH-1:0]  crc_o
);

  localparam int unsigned NBYTES = DATA_W / 8;

  logic [WIDTH-1:0] state_q;

  function automatic logic [WIDTH-1:0] crc_update(input logic [WIDTH-1:0] c,
                                                  input logic [DATA_W-1:0] d);
    logic [7:0] b;
    logic       fb;
    crc_update = c;
    for (int unsigned n = 0; n < NBYTES; n++) begin
      for (int unsigned i = 0; i < 8; i++) b[i] = REFIN ? d[8*n + 7 - i] : d[8*n + i];
      for (int i = 7; i >= 0; i--) begin
        fb         = crc_update[WIDTH-1] ^ b[i];
        crc_update = (crc_update << 1) ^ (fb ? POLY : '0);
      end
    end
  endfunction

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)       state_q <= INIT;
    else if (clear_i)  state_q <= valid_i ? crc_update(INIT, data_i) : INIT;
    else if (valid_i)  state_q <= crc_update(state_q, data_i);
  end

  always_comb begin
    for (int unsigned i = 0; i < WIDTH; i++)
      crc_o[i] = (REFOUT ? state_q[WIDTH-1-i] : state_q[i]) ^ XOROUT[i];
  end

`ifndef SYNTHESIS
  initial assert (DATA_W % 8 == 0 && DATA_W > 0 && WIDTH >= 3)
    else $fatal(1, "crc: DATA_W must be a multiple of 8, WIDTH >= 3");
`endif

endmodule
