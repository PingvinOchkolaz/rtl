// -----------------------------------------------------------------------------
// tb_axis_skid_buffer — AXI-Stream source/sink with random valid/ready.
//
// The source obeys the AXI rule (valid and data held until the handshake);
// the sink toggles ready freely. A scoreboard checks order and content,
// a throughput phase checks one transfer per cycle, and a structural check
// verifies that s_axis_tready does not depend combinationally on m_axis_tready.
// -----------------------------------------------------------------------------
module tb_axis_skid_buffer;
  import tb_pkg::*;

  localparam int unsigned W = 16;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         s_valid = 1'b0, s_ready, s_last = 1'b0;
  logic [W-1:0] s_data = '0;
  logic         m_valid, m_ready = 1'b0, m_last;
  logic [W-1:0] m_data;

  always #5 clk = ~clk;

  axis_skid_buffer #(.DATA_W(W)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .s_axis_tvalid_i(s_valid), .s_axis_tready_o(s_ready),
    .s_axis_tdata_i(s_data), .s_axis_tlast_i(s_last),
    .m_axis_tvalid_o(m_valid), .m_axis_tready_i(m_ready),
    .m_axis_tdata_o(m_data), .m_axis_tlast_o(m_last)
  );

  logic [W:0]  sb [$];
  int unsigned src_pct, snk_pct;
  int unsigned n_in, n_out;
  bit          pending;             // source offered a word that was not taken

  // Source and sink run in one process per cycle so the order is explicit.
  initial forever begin
    logic s_ready_before;
    @(negedge clk);
    if (!rst_n) begin
      s_valid = 1'b0;
      pending = 1'b0;
      continue;
    end
    // ---- sink: consume the word presented since the last rising edge
    m_ready = chance(snk_pct);
    s_ready_before = s_ready;
    #1;
    if (!rst_n) begin                // reset asserted in this very cycle
      s_valid = 1'b0;
      pending = 1'b0;
      continue;
    end
    check_eq(s_ready, s_ready_before, "s_axis_tready changed with m_axis_tready (comb path)");
    if (m_valid && m_ready) begin
      check(sb.size() != 0, "output transfer without input");
      if (sb.size() != 0) check_eq({m_last, m_data}, sb.pop_front(), "m_axis {tlast, tdata}");
      n_out++;
    end
    // ---- source: new word only after the previous one was accepted
    if (!pending) begin
      s_valid = chance(src_pct);
      s_data  = W'($urandom);
      s_last  = chance(20);
    end
    if (s_valid && s_ready) begin
      sb.push_back({s_last, s_data});
      n_in++;
      pending = 1'b0;
    end else begin
      pending = s_valid;
    end
    check(sb.size() <= 2, "more than two words buffered");
    sample_state();
  end

  function automatic void sample_state();
    string st;
    unique case ({dut.out_valid_q, dut.skid_valid_q})
      2'b00: st = "empty";
      2'b10: st = "out";
      2'b11: st = "out_skid";
      default: begin check(1'b0, "skid valid without output valid"); st = "bad"; end
    endcase
    cov_sample($sformatf("state.%s.svalid%0d.mready%0d", st, s_valid, m_ready));
  endfunction

  task automatic phase(int unsigned cycles, int unsigned sp, int unsigned mp);
    src_pct = sp;
    snk_pct = mp;
    repeat (cycles) @(posedge clk);
  endtask

  // Cross: buffer occupancy x source valid x sink ready.
  string STATES [3] = '{"empty", "out", "out_skid"};

  initial begin
    int unsigned n0;
    start("axis_skid_buffer");
    foreach (STATES[s])
      for (int v = 0; v < 2; v++)
        for (int r = 0; r < 2; r++)
          cov_declare($sformatf("state.%s.svalid%0d.mready%0d", STATES[s], v, r));

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Full throughput: always valid, always ready -> one word per cycle.
    phase(10, 100, 100);
    n0 = n_out;
    phase(200, 100, 100);
    check(n_out - n0 >= 199, $sformatf("throughput: %0d words in 200 cycles", n_out - n0));

    phase(2000, 50, 50);
    phase(2000, 90, 30);            // sink slower -> skid used often
    phase(2000, 30, 90);
    phase(1000, 100, 50);
    phase(200, 100, 0);             // complete stall
    phase(200, 0, 100);             // drain

    // Reset while holding data.
    phase(20, 100, 0);
    @(negedge clk);
    rst_n = 1'b0;
    sb.delete();
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    phase(1000, 70, 70);
    phase(50, 0, 100);

    check(sb.size() == 0, "scoreboard empty at the end");
    $display("[axis_skid_buffer] %0d words in, %0d out", n_in, n_out);
    finish();
  end

  default clocking cb @(posedge clk); endclocking
  c_skid_fill:  cover property (disable iff (!rst_n) $rose(dut.skid_valid_q));
  c_skid_drain: cover property (disable iff (!rst_n) $fell(dut.skid_valid_q));
  c_last:       cover property (disable iff (!rst_n) m_valid && m_ready && m_last);

endmodule
