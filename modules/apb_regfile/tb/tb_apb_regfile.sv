// -----------------------------------------------------------------------------
// tb_apb_regfile — APB4 master BFM + register model.
//
// The model is updated on the rising edge from TB-driven signals only (APB
// request and irq_event_i), mirroring the specification in the RTL header.
// Reads, pslverr, ctrl_o and irq_o are compared with it on the falling edge.
// -----------------------------------------------------------------------------
module tb_apb_regfile;
  import tb_pkg::*;

  localparam logic [31:0] ID   = 32'h4150_4201;
  localparam int unsigned NIRQ = 8;

  logic            clk = 1'b0;
  logic            rst_n = 1'b0;
  logic            psel = 1'b0, penable = 1'b0, pwrite = 1'b0;
  logic [7:0]      paddr = '0;
  logic [31:0]     pwdata = '0, prdata;
  logic [3:0]      pstrb = '0;
  logic            pready, pslverr;
  logic [31:0]     ctrl, status = '0;
  logic [NIRQ-1:0] irq_event = '0;
  logic            irq;

  always #5 clk = ~clk;

  apb_regfile #(.ID_VALUE(ID), .NIRQ(NIRQ)) dut (
    .pclk_i(clk), .presetn_i(rst_n),
    .psel_i(psel), .penable_i(penable), .pwrite_i(pwrite), .paddr_i(paddr),
    .pwdata_i(pwdata), .pstrb_i(pstrb), .prdata_o(prdata), .pready_o(pready),
    .pslverr_o(pslverr),
    .ctrl_o(ctrl), .status_i(status), .irq_event_i(irq_event), .irq_o(irq)
  );

  // ---------------------------------------------------------------- model --
  logic [31:0]     m_ctrl, m_scratch;
  logic [NIRQ-1:0] m_irq_st, m_irq_en;
  string           reg_names [8'h00:8'h14];

  function automatic bit m_ro(logic [7:0] a);
    return a == 8'h00 || a == 8'h08;
  endfunction

  function automatic bit m_mapped(logic [7:0] a);
    return a[1:0] == 2'b00 && a <= 8'h14;
  endfunction

  function automatic bit m_err(logic [7:0] a, bit write);
    return !m_mapped(a) || (write && m_ro(a));
  endfunction

  function automatic logic [31:0] m_read(logic [7:0] a);
    case (a)
      8'h00:   return ID;
      8'h04:   return m_ctrl;
      8'h08:   return status;
      8'h0C:   return 32'(m_irq_st);
      8'h10:   return 32'(m_irq_en);
      8'h14:   return m_scratch;
      default: return '0;
    endcase
  endfunction

  function automatic logic [31:0] merge(logic [31:0] old, logic [31:0] d, logic [3:0] strb);
    for (int b = 0; b < 4; b++) if (strb[b]) old[8*b +: 8] = d[8*b +: 8];
    return old;
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      m_ctrl <= '0; m_scratch <= '0; m_irq_st <= '0; m_irq_en <= '0;
    end else begin
      logic [NIRQ-1:0] clr = '0;
      if (psel && penable && pwrite && !m_err(paddr, 1'b1)) begin
        case (paddr)
          8'h04: m_ctrl    <= merge(m_ctrl, pwdata, pstrb);
          8'h14: m_scratch <= merge(m_scratch, pwdata, pstrb);
          8'h10: m_irq_en  <= NIRQ'(merge(32'(m_irq_en), pwdata, pstrb));
          8'h0C: clr = NIRQ'(merge('0, pwdata, pstrb));
          default: ;
        endcase
      end
      m_irq_st <= (m_irq_st & ~clr) | irq_event;
    end
  end

  always @(negedge clk) begin
    if (rst_n) begin
      check_eq(ctrl, m_ctrl, "ctrl_o");
      check_eq(irq, |(m_irq_st & m_irq_en), "irq_o");
      check_eq(pready, 1'b1, "pready_o");
      if (!(psel && penable)) check_eq(pslverr, 1'b0, "pslverr_o outside access phase");
    end
  end

  // ------------------------------------------------------------------ BFM --
  task automatic apb_xfer(bit write, logic [7:0] addr, logic [31:0] data = '0,
                          logic [3:0] strb = 4'hF, bit b2b = 1'b0);
    bit exp_err;
    // Setup phase
    @(negedge clk);
    psel    = 1'b1;
    penable = 1'b0;
    pwrite  = write;
    paddr   = addr;
    pwdata  = write ? data : 32'($urandom);    // pwdata is don't-care on reads
    pstrb   = write ? strb : 4'h0;
    // Access phase: completes at the next rising edge (pready = 1).
    @(negedge clk);
    penable = 1'b1;
    #1;
    exp_err = m_err(addr, write);
    check_eq(pslverr, exp_err, $sformatf("pslverr_o %s 0x%02h", write ? "write" : "read", addr));
    if (!write) check_eq(prdata, exp_err ? '0 : m_read(addr), $sformatf("prdata_o @0x%02h", addr));
    sample_cov(write, addr, strb, exp_err);
    if (!b2b) begin
      @(negedge clk);
      psel    = 1'b0;
      penable = 1'b0;
    end
  endtask

  task automatic apb_write(logic [7:0] addr, logic [31:0] data, logic [3:0] strb = 4'hF);
    apb_xfer(1'b1, addr, data, strb);
  endtask

  task automatic apb_read(logic [7:0] addr);
    apb_xfer(1'b0, addr);
  endtask

  // ------------------------------------------------------------- coverage --
  function automatic void sample_cov(bit write, logic [7:0] addr, logic [3:0] strb, bit err);
    string op = write ? "wr" : "rd";
    if (m_mapped(addr)) cov_sample($sformatf("%s.%s", op, reg_names[addr]));
    else if (addr[1:0] != 0) cov_sample({"err.misaligned_", op});
    else cov_sample({"err.unmapped_", op});
    if (write && m_mapped(addr) && m_ro(addr)) cov_sample("err.write_ro");
    if (write && !err) cov_sample($sformatf("strb.%0d", strb));
    if (write && !err && addr == 8'h0C && (irq_event & pwdata[NIRQ-1:0] & {NIRQ{strb[0]}}) != 0)
      cov_sample("irq.set_and_clear_same_cycle");
  endfunction

  function automatic void declare_cov();
    reg_names[8'h00] = "ID";         reg_names[8'h04] = "CTRL";
    reg_names[8'h08] = "STATUS";     reg_names[8'h0C] = "IRQ_STATUS";
    reg_names[8'h10] = "IRQ_ENABLE"; reg_names[8'h14] = "SCRATCH";
    for (int a = 0; a <= 8'h14; a += 4) begin
      cov_declare({"rd.", reg_names[a]});
      cov_declare({"wr.", reg_names[a]});
    end
    cov_declare("err.unmapped_rd");
    cov_declare("err.unmapped_wr");
    cov_declare("err.misaligned_rd");
    cov_declare("err.misaligned_wr");
    cov_declare("err.write_ro");
    cov_declare_range("strb", 0, 15);
    cov_declare("irq.set_and_clear_same_cycle");
    cov_declare("apb.back_to_back");
  endfunction

  default clocking cb @(posedge clk); endclocking
  c_irq_rise:  cover property (disable iff (!rst_n) $rose(irq));
  c_irq_fall:  cover property (disable iff (!rst_n) $fell(irq));
  c_all_irq:   cover property (disable iff (!rst_n) dut.irq_st_q == '1);

  // ------------------------------------------------------------- sequence --
  logic [7:0] ADDRS [$] = '{8'h00, 8'h04, 8'h08, 8'h0C, 8'h10, 8'h14};

  initial begin
    bit events_on = 1'b0;
    start("apb_regfile");
    declare_cov();

    // Random status input and interrupt events, independent of the bus.
    fork
      forever begin
        @(negedge clk);
        status    = tb_pkg::chance(10) ? 32'($urandom) : status;
        irq_event = events_on ? NIRQ'($urandom & $urandom & $urandom) : '0;
      end
    join_none

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Reset values, then walking ones through every RW register.
    foreach (ADDRS[i]) apb_read(ADDRS[i]);
    foreach (ADDRS[i]) begin
      for (int b = 0; b < 32; b++) apb_write(ADDRS[i], 32'(1) << b);
      apb_write(ADDRS[i], '1);
      apb_read(ADDRS[i]);
      apb_write(ADDRS[i], '0);
      apb_read(ADDRS[i]);
    end

    // Byte strobes.
    for (int s = 0; s < 16; s++) begin
      apb_write(8'h14, 32'($urandom), 4'(s));
      apb_read(8'h14);
    end

    // Error responses: unmapped, misaligned, write to read-only.
    apb_read(8'h18);  apb_write(8'hFC, '1);
    apb_read(8'h05);  apb_write(8'h0E, '1);
    apb_write(8'h00, '1); apb_write(8'h08, '1);
    apb_read(8'h00);

    // Interrupts: enable, let events arrive, clear with W1C.
    apb_write(8'h10, '1);
    events_on = 1'b1;
    repeat (200) begin
      if (tb_pkg::chance(50)) apb_write(8'h0C, 32'($urandom), 4'($urandom));
      else apb_read(8'h0C);
      if (tb_pkg::chance(20)) apb_write(8'h10, 32'($urandom));
    end
    events_on = 1'b0;
    apb_write(8'h0C, '1);
    apb_read(8'h0C);

    // Back-to-back transfers (setup phase directly after access phase).
    repeat (20) begin
      apb_xfer(tb_pkg::chance(50), ADDRS[$urandom_range(5, 0)], 32'($urandom), 4'hF, 1'b1);
      cov_sample("apb.back_to_back");
    end
    @(negedge clk);
    psel = 1'b0;
    penable = 1'b0;

    // Fully random traffic, including invalid addresses.
    events_on = 1'b1;
    repeat (3000) begin
      logic [7:0] a = tb_pkg::chance(80) ? ADDRS[$urandom_range(5, 0)] : 8'($urandom);
      apb_xfer(tb_pkg::chance(50), a, 32'($urandom), 4'($urandom), tb_pkg::chance(30));
    end
    @(negedge clk);
    psel = 1'b0;
    penable = 1'b0;
    repeat (3) @(negedge clk);
    finish();
  end

endmodule
