// -----------------------------------------------------------------------------
// axis_skid_buffer — AXI4-Stream register slice ("skid buffer").
//
// * Breaks every combinational path between the two sides: m_* outputs and
//   s_axis_tready_o all come straight from flops.
// * Sustains one transfer per cycle. When the sink stalls, the word already
//   accepted in the same cycle is parked in the skid register, so tready can
//   be registered without losing throughput.
// -----------------------------------------------------------------------------
module axis_skid_buffer #(
  parameter int unsigned DATA_W = 32
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              s_axis_tvalid_i,
  output logic              s_axis_tready_o,
  input  logic [DATA_W-1:0] s_axis_tdata_i,
  input  logic              s_axis_tlast_i,

  output logic              m_axis_tvalid_o,
  input  logic              m_axis_tready_i,
  output logic [DATA_W-1:0] m_axis_tdata_o,
  output logic              m_axis_tlast_o
);

  logic [DATA_W:0] out_q, skid_q;       // {tlast, tdata}
  logic            out_valid_q, skid_valid_q;
  logic            out_free;

  assign s_axis_tready_o = !skid_valid_q;
  assign m_axis_tvalid_o = out_valid_q;
  assign {m_axis_tlast_o, m_axis_tdata_o} = out_q;
  assign out_free = !out_valid_q || m_axis_tready_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      out_valid_q  <= 1'b0;
      skid_valid_q <= 1'b0;
    end else if (skid_valid_q) begin
      // Upstream is stalled; drain the skid register first.
      if (m_axis_tready_i) begin
        out_valid_q  <= 1'b1;
        skid_valid_q <= 1'b0;
      end
    end else if (out_free) begin
      out_valid_q <= s_axis_tvalid_i;
    end else if (s_axis_tvalid_i) begin
      skid_valid_q <= 1'b1;                // accepted while the output stalls
    end
  end

  // Data path without reset.
  always_ff @(posedge clk_i) begin
    if (skid_valid_q) begin
      if (m_axis_tready_i) out_q <= skid_q;
    end else if (out_free) begin
      if (s_axis_tvalid_i) out_q <= {s_axis_tlast_i, s_axis_tdata_i};
    end else if (s_axis_tvalid_i) begin
      skid_q <= {s_axis_tlast_i, s_axis_tdata_i};
    end
  end

`ifndef SYNTHESIS
  // AXI-Stream source rule on the master side: hold data until accepted.
  a_m_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
                               m_axis_tvalid_o && !m_axis_tready_i |=>
                               m_axis_tvalid_o && $stable(out_q));
  a_skid_implies_out: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                       skid_valid_q |-> out_valid_q);
`endif

endmodule
