// -----------------------------------------------------------------------------
// async_fifo — dual-clock FIFO (Cummings style).
//
// * Binary pointers address the memory; Gray-coded copies cross the clock
//   domain through two-flop synchronisers.
// * full/empty are registered and pessimistic: they deassert a couple of
//   cycles late, never early, so the FIFO can not overflow or underflow.
// * Depth is 2**AW. Each domain has its own active-low reset.
// -----------------------------------------------------------------------------
module async_fifo #(
  parameter int unsigned WIDTH = 8,
  parameter int unsigned AW    = 4
) (
  // write domain
  input  logic             wclk_i,
  input  logic             wrst_ni,
  input  logic             wr_en_i,
  input  logic [WIDTH-1:0] wr_data_i,
  output logic             full_o,

  // read domain
  input  logic             rclk_i,
  input  logic             rrst_ni,
  input  logic             rd_en_i,
  output logic [WIDTH-1:0] rd_data_o,
  output logic             empty_o
);

  localparam int unsigned DEPTH = 1 << AW;

  function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  logic [WIDTH-1:0] mem_q [DEPTH];
  logic [AW:0]      wbin_q, wgray_q, wbin_d, wgray_d, rgray_sync;
  logic [AW:0]      rbin_q, rgray_q, rbin_d, rgray_d, wgray_sync;
  logic             wr_fire, rd_fire;

  // ------------------------------------------------------------ write side --

  assign wr_fire = wr_en_i && !full_o;
  assign wbin_d  = wbin_q + (AW+1)'(wr_fire);
  assign wgray_d = bin2gray(wbin_d);

  always_ff @(posedge wclk_i or negedge wrst_ni) begin
    if (!wrst_ni) begin
      wbin_q  <= '0;
      wgray_q <= '0;
      full_o  <= 1'b0;
    end else begin
      wbin_q  <= wbin_d;
      wgray_q <= wgray_d;
      // Full: next write pointer equals the read pointer with both MSBs inverted.
      full_o  <= (wgray_d == {~rgray_sync[AW:AW-1], rgray_sync[AW-2:0]});
    end
  end

  always_ff @(posedge wclk_i) begin
    if (wr_fire) mem_q[wbin_q[AW-1:0]] <= wr_data_i;
  end

  sync_2ff #(.WIDTH(AW + 1)) u_sync_r2w (
    .clk_i(wclk_i), .rst_ni(wrst_ni), .d_i(rgray_q), .q_o(rgray_sync)
  );

  // ------------------------------------------------------------- read side --
  assign rd_fire   = rd_en_i && !empty_o;
  assign rbin_d    = rbin_q + (AW+1)'(rd_fire);
  assign rgray_d   = bin2gray(rbin_d);
  assign rd_data_o = mem_q[rbin_q[AW-1:0]];

  always_ff @(posedge rclk_i or negedge rrst_ni) begin
    if (!rrst_ni) begin
      rbin_q  <= '0;
      rgray_q <= '0;
      empty_o <= 1'b1;
    end else begin
      rbin_q  <= rbin_d;
      rgray_q <= rgray_d;
      empty_o <= (rgray_d == wgray_sync);
    end
  end

  sync_2ff #(.WIDTH(AW + 1)) u_sync_w2r (
    .clk_i(rclk_i), .rst_ni(rrst_ni), .d_i(wgray_q), .q_o(wgray_sync)
  );

`ifndef SYNTHESIS
  initial assert (AW >= 2) else $fatal(1, "async_fifo: AW must be >= 2");

  // Only one bit of a Gray pointer may change per clock — the CDC premise.
  a_wgray_onehot: assert property (@(posedge wclk_i) disable iff (!wrst_ni)
                                   $countones(wgray_q ^ $past(wgray_q)) <= 1);
  a_rgray_onehot: assert property (@(posedge rclk_i) disable iff (!rrst_ni)
                                   $countones(rgray_q ^ $past(rgray_q)) <= 1);
  a_gray_matches_bin: assert property (@(posedge wclk_i) disable iff (!wrst_ni)
                                       wgray_q == bin2gray(wbin_q));
`endif

endmodule
