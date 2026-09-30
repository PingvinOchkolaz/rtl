// -----------------------------------------------------------------------------
// sync_fifo — single-clock FIFO with first-word-fall-through read port.
//
// * DEPTH must be a power of two; pointers carry one extra wrap bit, so
//   full/empty are decoded without a separate counter.
// * rd_data_o is valid whenever empty_o == 0 (show-ahead); rd_en_i pops.
// * A write while full or a read while empty is ignored and flagged with a
//   one-cycle overflow_o / underflow_o pulse.
// -----------------------------------------------------------------------------
module sync_fifo #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned DEPTH = 16,
  localparam int unsigned AW   = $clog2(DEPTH)
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic             wr_en_i,
  input  logic [WIDTH-1:0] wr_data_i,
  output logic             full_o,

  input  logic             rd_en_i,
  output logic [WIDTH-1:0] rd_data_o,
  output logic             empty_o,

  output logic [AW:0]      count_o,
  output logic             overflow_o,
  output logic             underflow_o
);

  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [AW:0]      wr_ptr_q, rd_ptr_q;
  logic             wr_fire, rd_fire;

  assign empty_o   = (wr_ptr_q == rd_ptr_q);
  assign full_o    = (wr_ptr_q[AW] != rd_ptr_q[AW]) && (wr_ptr_q[AW-1:0] == rd_ptr_q[AW-1:0]);
  assign count_o   = wr_ptr_q - rd_ptr_q;
  assign rd_data_o = mem_q[rd_ptr_q[AW-1:0]];

  assign wr_fire = wr_en_i && !full_o;
  assign rd_fire = rd_en_i && !empty_o;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_ptr_q    <= '0;
      rd_ptr_q    <= '0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
    end else begin
      if (wr_fire) wr_ptr_q <= wr_ptr_q + 1'b1;
      if (rd_fire) rd_ptr_q <= rd_ptr_q + 1'b1;
      overflow_o  <= wr_en_i && full_o;
      underflow_o <= rd_en_i && empty_o;
    end
  end

  // Storage has no reset: it is never read before being written.
  always_ff @(posedge clk_i) begin
    if (wr_fire) mem_q[wr_ptr_q[AW-1:0]] <= wr_data_i;
  end

`ifndef SYNTHESIS
  initial begin
    assert (DEPTH >= 2 && (DEPTH & (DEPTH - 1)) == 0)
      else $fatal(1, "sync_fifo: DEPTH (%0d) must be a power of two >= 2", DEPTH);
  end

  a_count_range: assert property (@(posedge clk_i) disable iff (!rst_ni) count_o <= (AW+1)'(DEPTH));
  a_not_full_and_empty: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                         !(full_o && empty_o));
  // Occupancy moves by at most one per cycle and only in the right direction.
  a_count_step: assert property (@(posedge clk_i) disable iff (!rst_ni)
      count_o == $past(count_o) + (AW+1)'($past(wr_fire)) - (AW+1)'($past(rd_fire)));
`endif

endmodule
