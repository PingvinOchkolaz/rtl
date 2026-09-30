// -----------------------------------------------------------------------------
// uart — full-duplex UART core: uart_tx + uart_rx sharing one configuration.
// -----------------------------------------------------------------------------
module uart #(
  parameter int unsigned DIV_W = 16
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic [DIV_W-1:0] clks_per_bit_i,
  input  logic             parity_en_i,
  input  logic             parity_odd_i,
  input  logic             stop2_i,

  input  logic             tx_valid_i,
  input  logic [7:0]       tx_data_i,
  output logic             tx_ready_o,
  output logic             tx_o,

  input  logic             rx_i,
  output logic             rx_valid_o,
  output logic [7:0]       rx_data_o,
  output logic             parity_err_o,
  output logic             frame_err_o
);

  uart_tx #(.DIV_W(DIV_W)) u_tx (
    .clk_i, .rst_ni,
    .clks_per_bit_i, .parity_en_i, .parity_odd_i, .stop2_i,
    .tx_valid_i, .tx_data_i, .tx_ready_o, .tx_o
  );

  uart_rx #(.DIV_W(DIV_W)) u_rx (
    .clk_i, .rst_ni,
    .clks_per_bit_i, .parity_en_i, .parity_odd_i,
    .rx_i, .rx_valid_o, .rx_data_o, .parity_err_o, .frame_err_o
  );

endmodule
