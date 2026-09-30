// -----------------------------------------------------------------------------
// tb_sync_fifo — cycle-accurate reference model (SV queue) + scoreboard.
//
// Stimulus is driven on the falling edge; DUT outputs are compared with the
// model at the next falling edge, i.e. after the rising edge has been applied.
// -----------------------------------------------------------------------------
module tb_sync_fifo;
  import tb_pkg::*;

  localparam int unsigned W  = 16;
  localparam int unsigned D  = 8;
  localparam int unsigned AW = $clog2(D);

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         wr_en = 1'b0, rd_en = 1'b0;
  logic [W-1:0] wr_data = '0, rd_data;
  logic         full, empty, overflow, underflow;
  logic [AW:0]  count;

  always #5 clk = ~clk;

  sync_fifo #(.WIDTH(W), .DEPTH(D)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .wr_en_i(wr_en), .wr_data_i(wr_data), .full_o(full),
    .rd_en_i(rd_en), .rd_data_o(rd_data), .empty_o(empty),
    .count_o(count), .overflow_o(overflow), .underflow_o(underflow)
  );

  // ---------------------------------------------------------------- model --
  logic [W-1:0] model [$];
  bit           exp_ovf, exp_unf;

  function automatic void compare();
    check_eq(empty, model.size() == 0, "empty_o");
    check_eq(full,  model.size() == D, "full_o");
    check_eq(count, model.size(),      "count_o");
    check_eq(overflow,  exp_ovf, "overflow_o");
    check_eq(underflow, exp_unf, "underflow_o");
    if (model.size() != 0) check_eq(rd_data, model[0], "rd_data_o");
    if (rst_n) cov_sample($sformatf("count.%0d", model.size()));
  endfunction

  // One clock of stimulus: check, drive new inputs, predict next state.
  task automatic step(bit wr, bit rd, logic [W-1:0] data = W'($urandom));
    bit do_wr, do_rd;
    @(negedge clk);
    compare();
    wr_en   = wr;
    rd_en   = rd;
    wr_data = data;
    do_wr   = wr && model.size() != D;
    do_rd   = rd && model.size() != 0;
    exp_ovf = wr && model.size() == D;
    exp_unf = rd && model.size() == 0;
    if (do_rd) void'(model.pop_front());
    if (do_wr) model.push_back(data);
  endtask

  task automatic apply_reset();
    @(negedge clk);
    rst_n = 1'b0;
    wr_en = 1'b0;
    rd_en = 1'b0;
    model.delete();
    exp_ovf = 1'b0;
    exp_unf = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
  endtask

  task automatic random_phase(int unsigned cycles, int unsigned wr_pct, int unsigned rd_pct);
    repeat (cycles) step(chance(wr_pct), chance(rd_pct));
  endtask

  // ------------------------------------------------------------- sequence --
  initial begin
    start("sync_fifo");
    cov_declare_range("count", 0, D);
    apply_reset();

    // Directed: fill completely, push past full, drain, pop past empty.
    repeat (D + 3) step(1'b1, 1'b0);
    step(1'b1, 1'b1);                   // simultaneous rd/wr while full
    repeat (D + 3) step(1'b0, 1'b1);
    step(1'b1, 1'b1);                   // simultaneous rd/wr while empty
    step(1'b0, 1'b0);

    // Walking-ones data pattern for full data-path toggle coverage.
    for (int i = 0; i < W; i++) step(1'b1, 1'b1, W'(1) << i);
    repeat (4) step(1'b0, 1'b1);

    // Random traffic with different fill tendencies.
    random_phase(600, 90, 20);          // mostly full
    random_phase(600, 20, 90);          // mostly empty
    random_phase(1000, 50, 50);
    random_phase(400, 100, 100);        // streaming
    random_phase(600, 70, 60);

    // Reset in the middle of traffic.
    random_phase(20, 80, 10);
    apply_reset();
    random_phase(300, 60, 60);

    step(1'b0, 1'b0);
    step(1'b0, 1'b0);
    finish();
  end

  // ------------------------------------------------------------- coverage --
  default clocking cb @(posedge clk); endclocking

  c_full:           cover property (disable iff (!rst_n) full);
  c_wr_when_full:   cover property (disable iff (!rst_n) wr_en && full);
  c_rd_when_empty:  cover property (disable iff (!rst_n) rd_en && empty);
  c_rw_when_full:   cover property (disable iff (!rst_n) wr_en && rd_en && full);
  c_rw_when_empty:  cover property (disable iff (!rst_n) wr_en && rd_en && empty);
  c_full_then_pop:  cover property (disable iff (!rst_n) $past(full) && !full);
  c_back_to_back:   cover property (disable iff (!rst_n)
                                     dut.wr_fire && $past(dut.wr_fire, 1) && $past(dut.wr_fire, 2));
  c_wr_ptr_wrap:    cover property (disable iff (!rst_n) $fell(dut.wr_ptr_q[AW]));
  c_rst_while_busy: cover property ($fell(rst_n) && !$past(empty));

endmodule
