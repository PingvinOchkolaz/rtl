// -----------------------------------------------------------------------------
// sync_2ff — two-flop synchroniser for a multi-bit value that is guaranteed to
// change by at most one bit at a time (e.g. a Gray-coded pointer).
// -----------------------------------------------------------------------------
module sync_2ff #(
  parameter int unsigned WIDTH = 1
) (
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic [WIDTH-1:0] d_i,
  output logic [WIDTH-1:0] q_o
);

  logic [WIDTH-1:0] meta_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      meta_q <= '0;
      q_o    <= '0;
    end else begin
      meta_q <= d_i;
      q_o    <= meta_q;
    end
  end

endmodule
