// -----------------------------------------------------------------------------
// fir_filter — pipelined direct-form FIR filter, signed fixed point.
//
//   y[n] = sum_{k=0}^{TAPS-1} c[k] * x[n-k]
//
// * Full-precision output (OUT_W bits): no rounding, no overflow possible.
// * Coefficients are loaded through a simple write port; they should be
//   changed only while no samples are in flight.
// * Samples arrive with valid_i (any rate up to one per cycle); each one
//   produces a result on valid_o LATENCY = 3 cycles later:
//   stage 0 delay line, stage 1 products, stage 2 adder.
// -----------------------------------------------------------------------------
module fir_filter #(
  parameter int unsigned  DATA_W = 16,
  parameter int unsigned  COEF_W = 16,
  parameter int unsigned  TAPS   = 8,
  localparam int unsigned IW     = (TAPS > 1) ? $clog2(TAPS) : 1,
  localparam int unsigned PROD_W = DATA_W + COEF_W,
  localparam int unsigned OUT_W  = PROD_W + $clog2(TAPS)
) (
  input  logic                     clk_i,
  input  logic                     rst_ni,

  input  logic                     coef_we_i,
  input  logic [IW-1:0]            coef_idx_i,
  input  logic signed [COEF_W-1:0] coef_i,

  input  logic                     valid_i,
  input  logic signed [DATA_W-1:0] data_i,
  output logic                     valid_o,
  output logic signed [OUT_W-1:0]  data_o
);

  logic signed [COEF_W-1:0] coef_q [TAPS];
  logic signed [DATA_W-1:0] x_q    [TAPS];   // x_q[k] = x[n-k]
  logic signed [PROD_W-1:0] prod_q [TAPS];
  logic signed [OUT_W-1:0]  sum;
  logic                     v0_q, v1_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned k = 0; k < TAPS; k++) coef_q[k] <= '0;
    end else if (coef_we_i) begin
      coef_q[coef_idx_i] <= coef_i;
    end
  end

  // Stage 0: delay line. The history starts at zero after reset.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned k = 0; k < TAPS; k++) x_q[k] <= '0;
    end else if (valid_i) begin
      x_q[0] <= data_i;
      for (int unsigned k = 1; k < TAPS; k++) x_q[k] <= x_q[k-1];
    end
  end

  // Stage 1: products.
  always_ff @(posedge clk_i) begin
    if (v0_q) begin
      for (int unsigned k = 0; k < TAPS; k++) prod_q[k] <= x_q[k] * coef_q[k];
    end
  end

  // Stage 2: sum of products (the tool balances the adder tree).
  always_comb begin
    sum = '0;
    for (int unsigned k = 0; k < TAPS; k++) sum += OUT_W'(prod_q[k]);
  end

  always_ff @(posedge clk_i) begin
    if (v1_q) data_o <= sum;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      v0_q    <= 1'b0;
      v1_q    <= 1'b0;
      valid_o <= 1'b0;
    end else begin
      v0_q    <= valid_i;
      v1_q    <= v0_q;
      valid_o <= v1_q;
    end
  end

`ifndef SYNTHESIS
  initial assert (TAPS >= 2) else $fatal(1, "fir_filter: TAPS must be >= 2");
  a_coef_idx: assert property (@(posedge clk_i) disable iff (!rst_ni)
                               coef_we_i |-> 32'(coef_idx_i) < TAPS);
`endif

endmodule
