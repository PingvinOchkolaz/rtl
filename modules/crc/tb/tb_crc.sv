// -----------------------------------------------------------------------------
// tb_crc — five CRC configurations against reference models.
//
//  * Catalogue check values ("123456789") anchor the reference models to the
//    published standards, independent of the RTL.
//  * Two differently formulated software models (MSB-first shift-left and
//    reflected shift-right) are cross-checked, then compared with the DUTs on
//    random messages with random idle gaps and both ways of clearing.
//  * A 32-bit-per-cycle CRC-32 instance must match the byte-serial one.
// -----------------------------------------------------------------------------
module tb_crc;
  import tb_pkg::*;

  typedef logic [7:0] msg_t [$];

  typedef struct {
    string       name;
    int unsigned width;
    logic [63:0] poly, init;
    bit          refin, refout;
    logic [63:0] xorout, check;
  } crc_cfg_t;

  localparam int unsigned NCFG = 4;
  crc_cfg_t CFG [NCFG] = '{
    '{"CRC-32",          32, 64'h04C11DB7, 64'hFFFFFFFF, 1, 1, 64'hFFFFFFFF, 64'hCBF43926},
    '{"CRC-16/CCITT",    16, 64'h1021,     64'hFFFF,     0, 0, 64'h0,        64'h29B1},
    '{"CRC-16/MODBUS",   16, 64'h8005,     64'hFFFF,     1, 1, 64'h0,        64'h4B37},
    '{"CRC-8/SMBUS",      8, 64'h07,       64'h00,       0, 0, 64'h0,        64'hF4}
  };

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic        clr8 = 1'b0, v8 = 1'b0;
  logic [7:0]  d8 = '0;
  logic        clr32 = 1'b0, v32 = 1'b0;
  logic [31:0] d32 = '0;
  logic [63:0] crc_out [NCFG];
  logic [31:0] crc_w;

  always #5 clk = ~clk;

  // ---------------------------------------------------------------- DUTs ---
  logic [31:0] c0;
  logic [15:0] c1, c2;
  logic [7:0]  c3;

  crc #(.WIDTH(32), .POLY(32'h04C11DB7), .INIT(32'hFFFFFFFF), .REFIN(1), .REFOUT(1),
        .XOROUT(32'hFFFFFFFF), .DATA_W(8))
    u_crc32 (.clk_i(clk), .rst_ni(rst_n), .clear_i(clr8), .valid_i(v8), .data_i(d8), .crc_o(c0));
  crc #(.WIDTH(16), .POLY(16'h1021), .INIT(16'hFFFF), .REFIN(0), .REFOUT(0),
        .XOROUT(16'h0), .DATA_W(8))
    u_crc16_ccitt (.clk_i(clk), .rst_ni(rst_n), .clear_i(clr8), .valid_i(v8), .data_i(d8), .crc_o(c1));
  crc #(.WIDTH(16), .POLY(16'h8005), .INIT(16'hFFFF), .REFIN(1), .REFOUT(1),
        .XOROUT(16'h0), .DATA_W(8))
    u_crc16_modbus (.clk_i(clk), .rst_ni(rst_n), .clear_i(clr8), .valid_i(v8), .data_i(d8), .crc_o(c2));
  crc #(.WIDTH(8), .POLY(8'h07), .INIT(8'h00), .REFIN(0), .REFOUT(0),
        .XOROUT(8'h0), .DATA_W(8))
    u_crc8 (.clk_i(clk), .rst_ni(rst_n), .clear_i(clr8), .valid_i(v8), .data_i(d8), .crc_o(c3));
  crc #(.WIDTH(32), .POLY(32'h04C11DB7), .INIT(32'hFFFFFFFF), .REFIN(1), .REFOUT(1),
        .XOROUT(32'hFFFFFFFF), .DATA_W(32))
    u_crc32_x32 (.clk_i(clk), .rst_ni(rst_n), .clear_i(clr32), .valid_i(v32), .data_i(d32), .crc_o(crc_w));

  assign crc_out[0] = 64'(c0);
  assign crc_out[1] = 64'(c1);
  assign crc_out[2] = 64'(c2);
  assign crc_out[3] = 64'(c3);

  // ------------------------------------------------------ reference models --
  function automatic logic [63:0] reflect(logic [63:0] x, int unsigned n);
    logic [63:0] r = '0;
    for (int unsigned i = 0; i < n; i++) r[n-1-i] = x[i];
    return r;
  endfunction

  // Model A: textbook MSB-first shift-left algorithm, any configuration.
  function automatic logic [63:0] ref_crc(msg_t msg, crc_cfg_t c);
    logic [63:0] mask = (64'(1) << c.width) - 1;
    logic [63:0] r = c.init;
    foreach (msg[k]) begin
      logic [7:0] b = c.refin ? 8'(reflect(msg[k], 8)) : msg[k];
      for (int i = 7; i >= 0; i--) begin
        bit top = r[c.width-1] ^ b[i];
        r = (r << 1) & mask;
        if (top) r ^= c.poly;
      end
    end
    if (c.refout) r = reflect(r, c.width);
    return r ^ c.xorout;
  endfunction

  // Model B: reflected shift-right algorithm (only for REFIN = REFOUT = 1).
  function automatic logic [63:0] ref_crc_reflected(msg_t msg, crc_cfg_t c);
    logic [63:0] rpoly = reflect(c.poly, c.width);
    logic [63:0] r = reflect(c.init, c.width);
    foreach (msg[k]) begin
      r ^= 64'(msg[k]);
      repeat (8) r = r[0] ? (r >> 1) ^ rpoly : r >> 1;
    end
    return r ^ c.xorout;
  endfunction

  // ------------------------------------------------------------- drivers ---
  // how_clear: 0 = separate clear cycle, 1 = clear together with the first word
  task automatic send(msg_t msg, bit how_clear, int unsigned gap_pct);
    fork
      begin : byte_bus
        @(negedge clk);
        clr8 = 1'b1;
        v8   = how_clear && msg.size() != 0;
        d8   = v8 ? msg[0] : 8'($urandom);
        for (int k = v8 ? 1 : 0; k < msg.size(); k++) begin
          @(negedge clk);
          clr8 = 1'b0;
          while (chance(gap_pct)) begin
            v8 = 1'b0;
            d8 = 8'($urandom);                // must be ignored
            cov_sample("gap_in_message");
            @(negedge clk);
          end
          v8 = 1'b1;
          d8 = msg[k];
        end
        @(negedge clk);
        clr8 = 1'b0;
        v8   = 1'b0;
      end
      begin : word_bus
        if (msg.size() % 4 == 0) begin
          @(negedge clk);
          clr32 = 1'b1;
          v32   = 1'b0;
          for (int k = 0; k < msg.size(); k += 4) begin
            @(negedge clk);
            clr32 = 1'b0;
            v32   = 1'b1;
            d32   = {msg[k+3], msg[k+2], msg[k+1], msg[k]};
          end
          @(negedge clk);
          clr32 = 1'b0;
          v32   = 1'b0;
        end
      end
    join
    #1;
    for (int i = 0; i < NCFG; i++) begin
      logic [63:0] exp = ref_crc(msg, CFG[i]);
      if (CFG[i].refin && CFG[i].refout)
        check_eq(ref_crc_reflected(msg, CFG[i]), exp, {CFG[i].name, ": model A vs model B"});
      check_eq(crc_out[i], exp, $sformatf("%s, %0d-byte message", CFG[i].name, msg.size()));
    end
    if (msg.size() % 4 == 0) begin
      check_eq(crc_w, ref_crc(msg, CFG[0]), $sformatf("CRC-32 x32, %0d-byte message", msg.size()));
      cov_sample("x32_message");
    end
    sample_len(msg.size());
    if (how_clear && msg.size() != 0) cov_sample("clear_with_valid");
    else cov_sample("clear_separate");
  endtask

  function automatic void sample_len(int unsigned n);
    if (n == 0)       cov_sample("len.0");
    else if (n == 1)  cov_sample("len.1");
    else if (n <= 4)  cov_sample("len.2_4");
    else if (n <= 16) cov_sample("len.5_16");
    else if (n <= 64) cov_sample("len.17_64");
    else              cov_sample("len.65_plus");
  endfunction

  function automatic msg_t str2msg(string s);
    msg_t m;
    foreach (s[i]) m.push_back(s[i]);
    return m;
  endfunction

  // ------------------------------------------------------------ sequence ---
  initial begin
    msg_t m;
    start("crc");
    cov_declare("len.0");     cov_declare("len.1");     cov_declare("len.2_4");
    cov_declare("len.5_16");  cov_declare("len.17_64"); cov_declare("len.65_plus");
    cov_declare("gap_in_message");
    cov_declare("clear_with_valid");
    cov_declare("clear_separate");
    cov_declare("x32_message");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Reference models against the published check values.
    m = str2msg("123456789");
    foreach (CFG[i]) check_eq(ref_crc(m, CFG[i]), CFG[i].check, {CFG[i].name, " catalogue check"});
    send(m, 1'b0, 0);
    send(m, 1'b1, 30);
    m = str2msg("12345678");
    send(m, 1'b0, 0);
    check_eq(crc_w, 32'h9AE0DAAF, "CRC-32 x32 of \"12345678\"");

    // Empty message: CRC of nothing.
    m.delete();
    send(m, 1'b0, 0);

    // Random messages; lengths biased so every length class is hit.
    repeat (400) begin
      int unsigned len;
      randcase
        1: len = 1;
        3: len = $urandom_range(4, 2);
        4: len = $urandom_range(16, 5);
        3: len = $urandom_range(64, 17);
        1: len = $urandom_range(200, 65);
      endcase
      if (chance(50)) len = (len + 3) & ~32'd3;   // exercise the x32 instance
      m.delete();
      repeat (len) m.push_back(8'($urandom));
      send(m, chance(50), chance(50) ? 0 : 25);
    end
    finish();
  end

endmodule
