// -----------------------------------------------------------------------------
// tb_rr_arbiter — reference model (explicit rotating scan) + fairness monitor.
//
// Requesters behave like real masters: once a request is raised it is held
// until granted (with ready), then may drop or continue.
// -----------------------------------------------------------------------------
module tb_rr_arbiter;
  import tb_pkg::*;

  localparam int unsigned N  = 5;
  localparam int unsigned IW = $clog2(N);

  logic          clk = 1'b0;
  logic          rst_n = 1'b0;
  logic [N-1:0]  req = '0;
  logic          ready = 1'b0;
  logic [N-1:0]  gnt;
  logic [IW-1:0] gnt_idx;
  logic          gnt_valid;

  always #5 clk = ~clk;

  rr_arbiter #(.N(N)) dut (
    .clk_i(clk), .rst_ni(rst_n), .req_i(req), .ready_i(ready),
    .gnt_o(gnt), .gnt_idx_o(gnt_idx), .gnt_valid_o(gnt_valid)
  );

  // ---------------------------------------------------------------- model --
  int unsigned last = N - 1;          // index granted last; reset gives 0 priority
  int unsigned wait_cnt [N];
  int unsigned n_grants [N];

  function automatic int model_grant(logic [N-1:0] r);
    for (int unsigned k = 1; k <= N; k++) begin
      int unsigned i = (last + k) % N;
      if (r[i]) return i;
    end
    return -1;
  endfunction

  // Checks run after inputs settle (the grant is combinational).
  task automatic check_and_advance();
    int exp;
    #1;
    exp = model_grant(req);
    if (exp < 0) begin
      check_eq(gnt, '0, "gnt_o with no request");
      check_eq(gnt_valid, 1'b0, "gnt_valid_o");
    end else begin
      check_eq(gnt, N'(1) << exp, "gnt_o");
      check_eq(gnt_idx, exp, "gnt_idx_o");
      check_eq(gnt_valid, 1'b1, "gnt_valid_o");
    end
    // Fairness: a held request waits for at most N-1 accepted grants.
    for (int unsigned i = 0; i < N; i++) begin
      if (!req[i]) wait_cnt[i] = 0;
      check(wait_cnt[i] < N, $sformatf("requester %0d starved (%0d grants)", i, wait_cnt[i]));
    end
    if (exp >= 0 && ready) begin
      cov_sample($sformatf("gnt.%0d", exp));
      cov_sample($sformatf("pending.%0d", $countones(req)));
      // exp wins although a lower index is requesting: rotation at work
      if ((req & ((N'(1) << exp) - 1)) != '0) cov_sample($sformatf("gnt_rotated.%0d", exp));
      if (wait_cnt[exp] == N - 1) cov_sample($sformatf("gnt_after_max_wait.%0d", exp));
      for (int unsigned i = 0; i < N; i++) begin
        if (req[i] && i != exp) wait_cnt[i]++;
      end
      wait_cnt[exp] = 0;
      n_grants[exp]++;
      last = exp;
    end
  endtask

  // Next request vector: held requests stay, new ones appear with prob new_pct,
  // granted ones drop with prob drop_pct.
  task automatic cycle(int unsigned new_pct, int unsigned drop_pct, int unsigned ready_pct);
    logic [N-1:0] nxt;
    @(negedge clk);
    nxt = req;
    for (int unsigned i = 0; i < N; i++) begin
      if (!req[i]) nxt[i] = chance(new_pct);
      else if (gnt[i] && ready) nxt[i] = !chance(drop_pct);
    end
    req   = nxt;
    ready = chance(ready_pct);
    check_and_advance();
  endtask

  task automatic force_req(logic [N-1:0] r, bit rdy = 1'b1);
    @(negedge clk);
    req   = r;
    ready = rdy;
    check_and_advance();
  endtask

  // ------------------------------------------------------------- sequence --
  initial begin
    start("rr_arbiter");
    cov_declare_range("gnt", 0, N - 1);
    cov_declare_range("pending", 1, N);
    cov_declare_range("gnt_rotated", 1, N - 1);   // index 0 can never be "rotated"
    cov_declare_range("gnt_after_max_wait", 0, N - 1);
    repeat (2) @(negedge clk);
    rst_n = 1'b1;

    // Directed: idle, all requesting (pure rotation), single requester, stall.
    force_req('0);
    repeat (3 * N) force_req('1);
    for (int unsigned i = 0; i < N; i++) repeat (2) force_req(N'(1) << i);
    repeat (4) force_req('1, 1'b0);            // ready low: priority frozen
    force_req(N'(5'b10001));
    force_req(N'(5'b10001));
    force_req(N'(5'b10001));                   // wrap-around from 4 back to 0

    repeat (2000) cycle(30, 50, 100);          // moderate load
    repeat (2000) cycle(90, 10, 100);          // heavy load
    repeat (2000) cycle(60, 60, 60);           // back-pressure
    repeat (1000) cycle(5, 90, 100);           // sparse

    for (int unsigned i = 0; i < N; i++) begin
      $display("[rr_arbiter] requester %0d: %0d grants", i, n_grants[i]);
      check(n_grants[i] > 0, $sformatf("requester %0d never granted", i));
    end
    finish();
  end

  // ------------------------------------------------------------- coverage --
  default clocking cb @(posedge clk); endclocking

  c_idle:        cover property (disable iff (!rst_n) req == '0);
  c_all_req:     cover property (disable iff (!rst_n) req == '1 && ready);
  c_stall:       cover property (disable iff (!rst_n) gnt_valid && !ready);
  c_wrap:        cover property (disable iff (!rst_n)
                                 gnt_valid && $past(gnt_valid && ready) && gnt_idx < $past(gnt_idx));

endmodule
