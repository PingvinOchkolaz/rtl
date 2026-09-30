// -----------------------------------------------------------------------------
// rr_arbiter — N-way round-robin arbiter, combinational grant.
//
// Priority rotates: after requester k is granted, requesters k+1..N-1 get
// priority over 0..k in the next arbitration. A requester that keeps its
// request asserted is granted within N cycles (no starvation).
// The priority state changes only in cycles where a grant is issued and
// ready_i is high, so a stalled consumer does not shuffle priority.
// -----------------------------------------------------------------------------
module rr_arbiter #(
  parameter int unsigned N  = 4,
  localparam int unsigned IW = (N > 1) ? $clog2(N) : 1
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  logic [N-1:0]  req_i,
  input  logic          ready_i,     // consumer accepts the current grant
  output logic [N-1:0]  gnt_o,       // one-hot or zero
  output logic [IW-1:0] gnt_idx_o,
  output logic          gnt_valid_o
);

  logic [N-1:0] mask_q;              // requesters above the last grant
  logic [N-1:0] req_masked, gnt_masked, gnt_unmasked;

  // x & -x isolates the lowest set bit.
  assign req_masked   = req_i & mask_q;
  assign gnt_masked   = req_masked & (~req_masked + 1'b1);
  assign gnt_unmasked = req_i & (~req_i + 1'b1);
  assign gnt_o        = (|req_masked) ? gnt_masked : gnt_unmasked;
  assign gnt_valid_o  = |req_i;

  always_comb begin
    gnt_idx_o = '0;
    for (int unsigned i = 0; i < N; i++) begin
      if (gnt_o[i]) gnt_idx_o = IW'(i);
    end
  end

  // Next mask: every bit strictly above the granted one.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mask_q <= '1;
    end else if (gnt_valid_o && ready_i) begin
      mask_q <= ~((gnt_o << 1) - 1'b1);
    end
  end

`ifndef SYNTHESIS
  a_onehot:    assert property (@(posedge clk_i) disable iff (!rst_ni) $onehot0(gnt_o));
  a_gnt_req:   assert property (@(posedge clk_i) disable iff (!rst_ni) (gnt_o & ~req_i) == '0);
  a_work_cons: assert property (@(posedge clk_i) disable iff (!rst_ni) (|req_i) == (|gnt_o));
`endif

endmodule
