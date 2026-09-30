// -----------------------------------------------------------------------------
// tb_async_fifo — two free-running clocks with a changing frequency ratio.
//
// The writer and reader run as independent processes in their own clock
// domains and share a scoreboard queue. Because full/empty are pessimistic,
// the check is on data integrity/ordering, on the absence of overflow and
// underflow, and on the flags settling once traffic stops.
// -----------------------------------------------------------------------------
module tb_async_fifo;
  import tb_pkg::*;

  localparam int unsigned W     = 12;
  localparam int unsigned AW    = 3;
  localparam int unsigned DEPTH = 1 << AW;

  logic         wclk = 1'b0, rclk = 1'b0;
  logic         wrst_n = 1'b0, rrst_n = 1'b0;
  logic         wr_en = 1'b0, rd_en = 1'b0;
  logic [W-1:0] wr_data = '0, rd_data;
  logic         full, empty;

  real          whalf = 5.0, rhalf = 7.3;   // half periods, ns
  int unsigned  wr_pct, rd_pct;
  bit           traffic_on;

  always begin #(whalf); wclk = ~wclk; end
  always begin #(rhalf); rclk = ~rclk; end

  async_fifo #(.WIDTH(W), .AW(AW)) dut (
    .wclk_i(wclk), .wrst_ni(wrst_n), .wr_en_i(wr_en), .wr_data_i(wr_data), .full_o(full),
    .rclk_i(rclk), .rrst_ni(rrst_n), .rd_en_i(rd_en), .rd_data_o(rd_data), .empty_o(empty)
  );

  logic [W-1:0] sb [$];
  int unsigned  n_wr, n_rd, n_flushed;

  // ---------------------------------------------------------------- writer --
  initial forever begin
    @(negedge wclk);
    if (!wrst_n) begin
      wr_en = 1'b0;
      continue;
    end
    // Sometimes write while full on purpose: it must be dropped by the DUT.
    wr_en   = traffic_on && chance(wr_pct);
    wr_data = W'($urandom);
    if (wr_en && !full) begin
      sb.push_back(wr_data);
      n_wr++;
      check(sb.size() <= DEPTH, "occupancy exceeds DEPTH: full_o asserted too late");
    end
  end

  // ---------------------------------------------------------------- reader --
  initial forever begin
    @(negedge rclk);
    if (!rrst_n) begin
      rd_en = 1'b0;
      continue;
    end
    rd_en = traffic_on && chance(rd_pct);
    if (rd_en && !empty) begin
      check(sb.size() != 0, "read from empty FIFO: empty_o deasserted too early");
      if (sb.size() != 0) check_eq(rd_data, sb.pop_front(), "rd_data_o");
      n_rd++;
    end
  end

  // -------------------------------------------------------------- helpers --
  task automatic reset_both();
    traffic_on = 1'b0;
    #1;
    wrst_n = 1'b0;
    rrst_n = 1'b0;
    n_flushed += sb.size();   // words in flight are lost by the reset
    sb.delete();
    repeat (3) @(posedge wclk);
    repeat (3) @(posedge rclk);
    check(empty && !full, "flags after reset");
    @(negedge wclk) wrst_n = 1'b1;
    @(negedge rclk) rrst_n = 1'b1;
  endtask

  task automatic phase(int unsigned n_writes, int unsigned wp, int unsigned rp,
                       real wh, real rh);
    int unsigned target;
    whalf  = wh;
    rhalf  = rh;
    wr_pct = wp;
    rd_pct = rp;
    target = n_wr + n_writes;
    traffic_on = 1'b1;
    wait (n_wr >= target);
    $display("[async_fifo] phase wclk/2=%0.1f rclk/2=%0.1f wr=%0d%% rd=%0d%%: %0d written, %0d read",
             wh, rh, wp, rp, n_wr, n_rd);
  endtask

  // Stop writing, keep reading until the scoreboard drains, then flags settle.
  task automatic drain();
    int unsigned guard = 0;
    wr_pct = 0;
    rd_pct = 100;
    while (sb.size() != 0 && guard < 10000) begin
      @(posedge rclk);
      guard++;
    end
    check(sb.size() == 0, "drain timed out");
    traffic_on = 1'b0;
    repeat (4) @(posedge rclk);
    repeat (4) @(posedge wclk);
    check(empty, "empty_o settles after drain");
    check(!full, "full_o settles after drain");
  endtask

  // ------------------------------------------------------------- sequence --
  initial begin
    start("async_fifo");
    reset_both();

    phase(300, 90, 30,  5.0, 13.0);  // fast writer, slow reader -> full
    phase(300, 40, 95, 11.0,  3.0);  // slow writer, fast reader -> empty
    phase(500, 60, 60,  5.0,  5.0);  // equal frequencies
    phase(500, 100, 100, 4.0, 4.3);  // near-equal, streaming
    phase(300, 80, 80,  2.5, 17.5);  // 7:1 ratio
    phase(300, 80, 80, 17.5,  2.5);  // 1:7 ratio
    drain();

    // Reset both domains in the middle of traffic and start again.
    phase(40, 90, 10, 5.0, 7.0);
    reset_both();
    phase(400, 70, 70, 6.1, 4.7);
    drain();

    check(n_wr == n_rd + n_flushed, "every accepted word was read back or flushed");
    $display("[async_fifo] total words transferred: %0d", n_rd);
    finish();
  end

  // ------------------------------------------------------------- coverage --
  c_full:          cover property (@(posedge wclk) disable iff (!wrst_n) full);
  c_wr_when_full:  cover property (@(posedge wclk) disable iff (!wrst_n) wr_en && full);
  c_full_release:  cover property (@(posedge wclk) disable iff (!wrst_n) $fell(full));
  c_wptr_wrap:     cover property (@(posedge wclk) disable iff (!wrst_n) $fell(dut.wbin_q[AW]));
  c_empty:         cover property (@(posedge rclk) disable iff (!rrst_n) empty);
  c_rd_when_empty: cover property (@(posedge rclk) disable iff (!rrst_n) rd_en && empty);
  c_empty_release: cover property (@(posedge rclk) disable iff (!rrst_n) $fell(empty));
  c_rptr_wrap:     cover property (@(posedge rclk) disable iff (!rrst_n) $fell(dut.rbin_q[AW]));
  c_rst_not_empty: cover property (@(posedge rclk) $fell(rrst_n) && !$past(empty));

endmodule
