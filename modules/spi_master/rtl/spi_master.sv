// -----------------------------------------------------------------------------
// spi_master — SPI master, all four CPOL/CPHA modes, MSB first.
//
// * One transfer of DATA_W bits per request; cs_n_o frames each transfer.
// * SCLK half period = clk_div_i + 1 system clocks (clk_div_i = 0 -> clk/2).
// * The mode and divider are latched when a transfer starts.
// * Timing: cs_n falls, half an SCLK period of setup, 2*DATA_W SCLK edges,
//   half a period of hold, cs_n rises; done_o pulses together with rx_data_o.
// -----------------------------------------------------------------------------
module spi_master #(
  parameter int unsigned DATA_W = 8,
  parameter int unsigned DIV_W  = 8
) (
  input  logic              clk_i,
  input  logic              rst_ni,

  input  logic              cpol_i,
  input  logic              cpha_i,
  input  logic [DIV_W-1:0]  clk_div_i,

  input  logic              start_i,       // request, accepted when ready_o
  input  logic [DATA_W-1:0] tx_data_i,
  output logic              ready_o,
  output logic              done_o,        // one-cycle pulse
  output logic [DATA_W-1:0] rx_data_o,

  output logic              sclk_o,
  output logic              mosi_o,
  input  logic              miso_i,
  output logic              cs_n_o
);

  localparam int unsigned EW = $clog2(2 * DATA_W + 1);

  typedef enum logic [1:0] {S_IDLE, S_XFER, S_HOLD} state_e;

  state_e            state_q;
  logic [DIV_W-1:0]  div_q, cnt_q;
  logic [EW-1:0]     edge_q;          // SCLK edges issued so far
  logic [DATA_W-1:0] tx_q, rx_q;
  logic              cpol_q, cpha_q;
  logic              tick, leading;

  assign tick    = (cnt_q == '0);
  // Edge number edge_q is about to be issued: even edges are leading ones.
  assign leading = !edge_q[0];
  assign ready_o = (state_q == S_IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q   <= S_IDLE;
      div_q     <= '0;
      cnt_q     <= '0;
      edge_q    <= '0;
      tx_q      <= '0;
      rx_q      <= '0;
      cpol_q    <= 1'b0;
      cpha_q    <= 1'b0;
      sclk_o    <= 1'b0;
      mosi_o    <= 1'b0;
      cs_n_o    <= 1'b1;
      done_o    <= 1'b0;
      rx_data_o <= '0;
    end else begin
      done_o <= 1'b0;
      cnt_q  <= tick ? div_q : cnt_q - 1'b1;
      unique case (state_q)
        S_IDLE: begin
          sclk_o <= cpol_i;
          if (start_i) begin
            state_q <= S_XFER;             // first edge after div+1 cycles: CS setup
            cpol_q  <= cpol_i;
            cpha_q  <= cpha_i;
            div_q   <= clk_div_i;
            cnt_q   <= clk_div_i;
            edge_q  <= '0;
            cs_n_o  <= 1'b0;
            // CPHA=0: the first bit must be on the line before the first edge.
            mosi_o  <= cpha_i ? 1'b0 : tx_data_i[DATA_W-1];
            tx_q    <= cpha_i ? tx_data_i : tx_data_i << 1;
          end
        end
        S_XFER: begin
          if (tick) begin
            sclk_o <= ~sclk_o;
            edge_q <= edge_q + 1'b1;
            // Sample on leading edges for CPHA=0, on trailing ones for CPHA=1;
            // shift out on the other edge.
            if (leading ^ cpha_q) begin
              rx_q <= {rx_q[DATA_W-2:0], miso_i};
            end else if (cpha_q || edge_q != EW'(2 * DATA_W - 1)) begin
              mosi_o <= tx_q[DATA_W-1];
              tx_q   <= tx_q << 1;
            end
            if (edge_q == EW'(2 * DATA_W - 1)) state_q <= S_HOLD;
          end
        end
        S_HOLD: begin
          if (tick) begin
            state_q   <= S_IDLE;
            cs_n_o    <= 1'b1;
            done_o    <= 1'b1;
            rx_data_o <= rx_q;
          end
        end
        // verilator coverage_off
        default: state_q <= S_IDLE;   // unreachable: all encodings handled
        // verilator coverage_on
      endcase
    end
  end

`ifndef SYNTHESIS
  initial assert (DATA_W >= 2) else $fatal(1, "spi_master: DATA_W must be >= 2");

  // SCLK is back at CPOL during the CS hold phase.
  a_sclk_idle: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                state_q == S_HOLD |-> sclk_o == cpol_q);
  a_cs_stable: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                state_q != S_IDLE |-> !cs_n_o);
`endif

endmodule
