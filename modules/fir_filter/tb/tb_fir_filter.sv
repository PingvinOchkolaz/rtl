// -----------------------------------------------------------------------------
// tb_fir_filter — bit-exact convolution model (64-bit integers).
//
// For several coefficient sets (random, extreme, symmetric low-pass, delay)
// the test runs an impulse, a step, full-scale extremes and random bursty
// streams, and checks every output value and the fixed latency.
// -----------------------------------------------------------------------------
module tb_fir_filter;
  import tb_pkg::*;

  localparam int unsigned DW    = 16;
  localparam int unsigned CW    = 16;
  localparam int unsigned TAPS  = 8;
  localparam int unsigned OUT_W = DW + CW + $clog2(TAPS);
  localparam int unsigned LAT   = 3;
  localparam int          XMAX  = 32767;
  localparam int          XMIN  = -32768;

  logic                   clk = 1'b0;
  logic                   rst_n = 1'b0;
  logic                   coef_we = 1'b0;
  logic [2:0]             coef_idx = '0;
  logic signed [CW-1:0]   coef = '0;
  logic                   valid_in = 1'b0, valid_out;
  logic signed [DW-1:0]   x = '0;
  logic signed [OUT_W-1:0] y;

  always #5 clk = ~clk;

  fir_filter #(.DATA_W(DW), .COEF_W(CW), .TAPS(TAPS)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .coef_we_i(coef_we), .coef_idx_i(coef_idx), .coef_i(coef),
    .valid_i(valid_in), .data_i(x), .valid_o(valid_out), .data_o(y)
  );

  // ---------------------------------------------------------------- model --
  longint      c_m [TAPS];
  longint      hist [TAPS];       // hist[k] = x[n-k]
  longint      exp_q [$];
  int unsigned in_cycle [$];      // cycle of each input, for the latency check
  int unsigned cycle;

  always @(posedge clk) cycle++;

  function automatic longint model_push(longint s);
    longint acc = 0;
    for (int k = TAPS - 1; k > 0; k--) hist[k] = hist[k-1];
    hist[0] = s;
    for (int k = 0; k < TAPS; k++) acc += c_m[k] * hist[k];
    return acc;
  endfunction

  always @(negedge clk) begin
    if (rst_n && valid_out) begin
      longint e;
      check(exp_q.size() != 0, "output without input");
      if (exp_q.size() != 0) begin
        e = exp_q.pop_front();
        check_eq(64'(y), 64'(e), "y[n]");
        check_eq(cycle - in_cycle.pop_front(), LAT, "latency");
        if (e > 64'sd1 <<< 32)        cov_sample("y.pos_huge");
        else if (e < -(64'sd1 <<< 32)) cov_sample("y.neg_huge");
        else if (e == 0)              cov_sample("y.zero");
      end
    end
  end

  // -------------------------------------------------------------- drivers --
  task automatic load_coefs(int c [TAPS], string name);
    wait (exp_q.size() == 0);                  // pipeline empty
    for (int k = 0; k < TAPS; k++) begin
      @(negedge clk);
      coef_we  = 1'b1;
      coef_idx = 3'(k);
      coef     = CW'(c[k]);
      c_m[k]   = c[k];
    end
    @(negedge clk);
    coef_we = 1'b0;
    cov_sample({"coefs.", name});
  endtask

  task automatic sample(longint s);
    @(negedge clk);
    valid_in = 1'b1;
    x        = DW'(s);
    exp_q.push_back(model_push(s));
    in_cycle.push_back(cycle);
    @(negedge clk);
    valid_in = 1'b0;
    x        = DW'($urandom);                  // ignored without valid
  endtask

  // Back-to-back samples with probability-driven gaps.
  task automatic stream(int unsigned n, int unsigned gap_pct, int kind = 0);
    for (int unsigned i = 0; i < n; i++) begin
      longint s;
      case (kind)
        1:       s = chance(50) ? XMAX : XMIN;
        default: s = longint'($signed(DW'($urandom)));
      endcase
      @(negedge clk);
      if (chance(gap_pct)) begin
        valid_in = 1'b0;
        x        = DW'($urandom);
        cov_sample("stream.gap");
        continue;
      end
      valid_in = 1'b1;
      x        = DW'(s);
      exp_q.push_back(model_push(s));
      in_cycle.push_back(cycle);
    end
    @(negedge clk);
    valid_in = 1'b0;
  endtask

  task automatic flush();
    repeat (TAPS) sample(0);
  endtask

  // ------------------------------------------------------------- sequence --
  int RAND_C [TAPS];
  int EXT_C  [TAPS] = '{default: -32768};
  int LPF_C  [TAPS] = '{-1310, 2621, 7864, 13107, 13107, 7864, 2621, -1310};
  int DLY_C  [TAPS] = '{0, 0, 0, 1, 0, 0, 0, 0};
  int ALT_C  [TAPS] = '{32767, -32768, 32767, -32768, 32767, -32768, 32767, -32768};

  task automatic run_set(int c [TAPS], string name);
    load_coefs(c, name);
    flush();
    // Impulse: the response must reproduce the coefficients.
    sample(1);
    repeat (TAPS) sample(0);
    sample(XMIN);                              // negative full-scale impulse
    repeat (TAPS) sample(0);
    // Step response.
    repeat (TAPS + 2) sample(XMAX);
    flush();
    stream(20, 0, 1);                          // full-scale extremes, no gaps
    stream(200, 0);                            // one sample per cycle
    stream(200, 40);                           // bursty
    flush();
  endtask

  initial begin
    start("fir_filter");
    cov_declare("coefs.random");   cov_declare("coefs.extreme"); cov_declare("coefs.lowpass");
    cov_declare("coefs.delay");    cov_declare("coefs.alternating");
    cov_declare("y.pos_huge");     cov_declare("y.neg_huge");    cov_declare("y.zero");
    cov_declare("stream.gap");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Samples right after reset: history must be zero.
    stream(20, 0);

    foreach (RAND_C[k]) RAND_C[k] = int'($signed(CW'($urandom)));
    run_set(RAND_C, "random");
    run_set(EXT_C, "extreme");                 // -32768 * -32768 on every tap
    run_set(LPF_C, "lowpass");
    run_set(DLY_C, "delay");
    run_set(ALT_C, "alternating");
    repeat (4) begin
      foreach (RAND_C[k]) RAND_C[k] = int'($signed(CW'($urandom)));
      run_set(RAND_C, "random");
    end

    wait (exp_q.size() == 0);
    repeat (5) @(negedge clk);
    finish();
  end

endmodule
