// -----------------------------------------------------------------------------
// tb_seq_divider — operand-class driven random test against '/' and '%'.
//
// Operands are drawn from corner classes (zero, one, powers of two, maximum,
// divisor above/equal to the dividend) as well as uniformly. The latency of
// every operation and the handshake are checked too.
// -----------------------------------------------------------------------------
module tb_seq_divider;
  import tb_pkg::*;

  localparam int unsigned W = 16;
  localparam logic [W-1:0] MAX = '1;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         start_req = 1'b0, ready, done, dbz;
  logic [W-1:0] dividend = '0, divisor = '0, quotient, remainder;

  always #5 clk = ~clk;

  seq_divider #(.WIDTH(W)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .start_i(start_req), .dividend_i(dividend), .divisor_i(divisor), .ready_o(ready),
    .done_o(done), .quotient_o(quotient), .remainder_o(remainder), .div_by_zero_o(dbz)
  );

  typedef enum int {ZERO, ONE, POW2, MAX_V, SMALL, RANDOM, NCLASS} opclass_e;
  string CLS_NAME [NCLASS] = '{"zero", "one", "pow2", "max", "small", "random"};

  function automatic logic [W-1:0] gen(opclass_e c);
    case (c)
      ZERO:    return '0;
      ONE:     return W'(1);
      POW2:    return W'(1) << $urandom_range(W - 1, 0);
      MAX_V:   return MAX;
      SMALL:   return W'($urandom_range(15, 2));
      default: return W'($urandom);
    endcase
  endfunction

  // lat counts rising edges from the accepting one (inclusive) until done is
  // visible: 1 for division by zero, WIDTH + 1 otherwise.
  task automatic divide(logic [W-1:0] a, logic [W-1:0] b, bit keep_start = 1'b0);
    logic [W-1:0] exp_q, exp_r;
    int unsigned  lat = 0;
    @(negedge clk);
    start_req = 1'b1;
    dividend  = a;
    divisor   = b;
    while (!ready) @(negedge clk);
    @(negedge clk);                           // accepted at the rising edge
    start_req = keep_start;
    dividend  = W'($urandom);                 // operands are latched: scramble them
    divisor   = W'($urandom);
    lat = 1;
    while (!done) begin
      @(negedge clk);
      lat++;
      check(lat <= W + 1, "divider hangs");
      if (lat > W + 1) return;
    end
    exp_q = (b == 0) ? MAX : a / b;
    exp_r = (b == 0) ? a   : a % b;
    check_eq(quotient,  exp_q, $sformatf("quotient  %0d / %0d", a, b));
    check_eq(remainder, exp_r, $sformatf("remainder %0d %% %0d", a, b));
    check_eq(dbz, b == 0, "div_by_zero_o");
    check_eq(lat, (b == 0) ? 1 : W + 1, "latency");
    if (keep_start) cov_sample("back_to_back");
    if (exp_q == 0) cov_sample("result.quotient_zero");
    if (exp_r == 0 && b != 0) cov_sample("result.exact");
    if (b != 0 && exp_q == MAX) cov_sample("result.quotient_max");
  endtask

  initial begin
    start("seq_divider");
    for (int a = 0; a < NCLASS; a++)
      for (int b = 0; b < NCLASS; b++)
        cov_declare($sformatf("cross.dividend_%s.divisor_%s", CLS_NAME[a], CLS_NAME[b]));
    cov_declare("rel.divisor_gt_dividend");
    cov_declare("rel.divisor_eq_dividend");
    cov_declare("result.quotient_zero");
    cov_declare("result.exact");
    cov_declare("result.quotient_max");
    cov_declare("back_to_back");
    cov_declare("start_while_busy");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // Every class combination, several times.
    for (int a = 0; a < NCLASS; a++)
      for (int b = 0; b < NCLASS; b++)
        repeat (8) begin
          logic [W-1:0] x = gen(opclass_e'(a));
          logic [W-1:0] y = gen(opclass_e'(b));
          divide(x, y);
          cov_sample($sformatf("cross.dividend_%s.divisor_%s", CLS_NAME[a], CLS_NAME[b]));
          if (y > x) cov_sample("rel.divisor_gt_dividend");
        end

    // Equal operands and divisor just above the dividend.
    repeat (20) begin
      logic [W-1:0] x = W'($urandom);
      divide(x, x);
      cov_sample("rel.divisor_eq_dividend");
      if (x != MAX) divide(x, x + 1'b1);
    end

    // Start held high: a new operation must start right after done.
    repeat (10) divide(W'($urandom), W'($urandom_range(300, 1)), 1'b1);
    @(negedge clk);
    start_req = 1'b0;
    while (!ready || done) @(negedge clk);   // drain the last back-to-back operation

    // A start pulse while busy must be ignored.
    @(negedge clk);
    start_req = 1'b1; dividend = 16'd1000; divisor = 16'd7;
    @(negedge clk);
    dividend = 16'd5; divisor = 16'd5;       // arrives while busy
    cov_sample("start_while_busy");
    @(negedge clk);
    start_req = 1'b0;
    wait (done);
    @(negedge clk);
    check_eq(quotient, 16'd142, "busy start ignored: quotient");
    check_eq(remainder, 16'd6, "busy start ignored: remainder");

    repeat (3000) divide(W'($urandom), chance(20) ? W'($urandom_range(255, 0)) : W'($urandom));
    finish();
  end

endmodule
