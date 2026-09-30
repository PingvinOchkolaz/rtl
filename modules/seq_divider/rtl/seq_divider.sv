// -----------------------------------------------------------------------------
// seq_divider — unsigned radix-2 restoring divider, one quotient bit per cycle.
//
// * start_i is accepted when ready_o is high; done_o pulses WIDTH cycles later
//   with quotient_o/remainder_o, which stay valid until the next start.
// * Division by zero finishes in one cycle and follows the RISC-V convention:
//   quotient = all ones, remainder = dividend, div_by_zero_o = 1.
// -----------------------------------------------------------------------------
module seq_divider #(
  parameter int unsigned WIDTH = 32,
  localparam int unsigned CW   = $clog2(WIDTH)
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             start_i,
  input  logic [WIDTH-1:0] dividend_i,
  input  logic [WIDTH-1:0] divisor_i,
  output logic             ready_o,

  output logic             done_o,
  output logic [WIDTH-1:0] quotient_o,
  output logic [WIDTH-1:0] remainder_o,
  output logic             div_by_zero_o
);

  logic             busy_q;
  logic [CW-1:0]    cnt_q;
  logic [WIDTH-1:0] divisor_q;
  logic [WIDTH-1:0] rem_q;        // partial remainder
  logic [WIDTH-1:0] quo_q;        // dividend bits shift out, quotient bits shift in
  logic [WIDTH:0]   trial, diff;

  // One restoring step: bring down the next dividend bit, try to subtract.
  assign trial = {rem_q, quo_q[WIDTH-1]};
  assign diff  = trial - {1'b0, divisor_q};

  assign ready_o     = !busy_q;
  assign quotient_o  = quo_q;
  assign remainder_o = rem_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q        <= 1'b0;
      cnt_q         <= '0;
      divisor_q     <= '0;
      rem_q         <= '0;
      quo_q         <= '0;
      done_o        <= 1'b0;
      div_by_zero_o <= 1'b0;
    end else begin
      done_o <= 1'b0;
      if (!busy_q) begin
        if (start_i) begin
          div_by_zero_o <= (divisor_i == '0);
          if (divisor_i == '0) begin
            quo_q  <= '1;
            rem_q  <= dividend_i;
            done_o <= 1'b1;
          end else begin
            busy_q    <= 1'b1;
            cnt_q     <= CW'(WIDTH - 1);
            divisor_q <= divisor_i;
            rem_q     <= '0;
            quo_q     <= dividend_i;
          end
        end
      end else begin
        if (!diff[WIDTH]) rem_q <= diff[WIDTH-1:0];
        else              rem_q <= trial[WIDTH-1:0];
        quo_q <= {quo_q[WIDTH-2:0], !diff[WIDTH]};
        cnt_q <= cnt_q - 1'b1;
        if (cnt_q == '0) begin
          busy_q <= 1'b0;
          done_o <= 1'b1;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial assert (WIDTH >= 2) else $fatal(1, "seq_divider: WIDTH must be >= 2");

  // Restoring invariant: the partial remainder is always below the divisor.
  a_rem_lt_div: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                 busy_q |-> rem_q < divisor_q);
  a_done_pulse: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                 done_o |=> !done_o || $past(ready_o && start_i));
`endif

endmodule
