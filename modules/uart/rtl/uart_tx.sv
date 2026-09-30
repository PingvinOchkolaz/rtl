// -----------------------------------------------------------------------------
// uart_tx — UART transmitter, 8 data bits LSB first.
//
// Frame: start(0) | d0..d7 | [parity] | stop(1) [| stop(1)]
// Bit time = clks_per_bit_i clock cycles. The configuration is latched at the
// start of every frame, so it may change between frames without glitches.
// -----------------------------------------------------------------------------
module uart_tx #(
  parameter int unsigned DIV_W = 16
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic [DIV_W-1:0] clks_per_bit_i,  // >= 2
  input  logic             parity_en_i,
  input  logic             parity_odd_i,
  input  logic             stop2_i,

  input  logic             tx_valid_i,
  input  logic [7:0]       tx_data_i,
  output logic             tx_ready_o,

  output logic             tx_o
);

  typedef enum logic [2:0] {
    S_IDLE, S_START, S_DATA, S_PARITY, S_STOP
  } state_e;

  state_e           state_q;
  logic [DIV_W-1:0] div_q, cnt_q;
  logic [7:0]       shift_q;
  logic [2:0]       bit_q;
  logic             parity_q, parity_en_q, stop2_q;
  logic             bit_end;

  assign bit_end    = (cnt_q == '0);
  assign tx_ready_o = (state_q == S_IDLE);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_IDLE;
      tx_o        <= 1'b1;
      div_q       <= '0;
      cnt_q       <= '0;
      shift_q     <= '0;
      bit_q       <= '0;
      parity_q    <= 1'b0;
      parity_en_q <= 1'b0;
      stop2_q     <= 1'b0;
    end else begin
      cnt_q <= bit_end ? div_q - 1'b1 : cnt_q - 1'b1;
      unique case (state_q)
        S_IDLE: begin
          tx_o <= 1'b1;
          if (tx_valid_i) begin
            state_q     <= S_START;
            tx_o        <= 1'b0;
            div_q       <= clks_per_bit_i;
            cnt_q       <= clks_per_bit_i - 1'b1;
            shift_q     <= tx_data_i;
            parity_q    <= ^tx_data_i ^ parity_odd_i;
            parity_en_q <= parity_en_i;
            stop2_q     <= stop2_i;
            bit_q       <= '0;
          end
        end
        S_START: begin
          if (bit_end) begin
            state_q <= S_DATA;
            tx_o    <= shift_q[0];
            shift_q <= shift_q >> 1;
          end
        end
        S_DATA: begin
          if (bit_end) begin
            if (bit_q == 3'd7) begin
              state_q <= parity_en_q ? S_PARITY : S_STOP;
              tx_o    <= parity_en_q ? parity_q : 1'b1;
            end else begin
              tx_o    <= shift_q[0];
              shift_q <= shift_q >> 1;
            end
            bit_q <= bit_q + 1'b1;
          end
        end
        S_PARITY: begin
          if (bit_end) begin
            state_q <= S_STOP;
            tx_o    <= 1'b1;
          end
        end
        S_STOP: begin
          if (bit_end) begin
            if (stop2_q) stop2_q <= 1'b0;
            else         state_q <= S_IDLE;
          end
        end
        // verilator coverage_off
        default: state_q <= S_IDLE;   // unreachable: all encodings handled
        // verilator coverage_on
      endcase
    end
  end

`ifndef SYNTHESIS
  a_idle_high: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                (state_q == S_IDLE) |-> tx_o);
  a_start_low: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                (state_q == S_START) |-> !tx_o);

  c_back_to_back: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                  state_q == S_IDLE && $past(state_q == S_STOP) && tx_valid_i);
`endif

endmodule
