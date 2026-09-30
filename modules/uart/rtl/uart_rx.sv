// -----------------------------------------------------------------------------
// uart_rx — UART receiver, 8 data bits LSB first, mid-bit sampling.
//
// * rx_i is synchronised with two flops before use.
// * A start bit is confirmed at its middle; shorter low pulses are rejected
//   as glitches (false start).
// * rx_valid_o pulses for one cycle at the middle of the (first) stop bit,
//   together with rx_data_o, parity_err_o and frame_err_o.
// * After a framing error the receiver waits for the line to return high
//   before looking for the next start bit.
// -----------------------------------------------------------------------------
module uart_rx #(
  parameter int unsigned DIV_W = 16
) (
  input  logic             clk_i,
  input  logic             rst_ni,

  input  logic [DIV_W-1:0] clks_per_bit_i,  // >= 4
  input  logic             parity_en_i,
  input  logic             parity_odd_i,

  input  logic             rx_i,

  output logic             rx_valid_o,
  output logic [7:0]       rx_data_o,
  output logic             parity_err_o,
  output logic             frame_err_o
);

  typedef enum logic [2:0] {
    S_IDLE, S_START, S_DATA, S_PARITY, S_STOP, S_WAIT_IDLE
  } state_e;

  state_e           state_q;
  logic             rx_meta_q, rx_q;
  logic [DIV_W-1:0] div_q, cnt_q;
  logic [7:0]       shift_q;
  logic [2:0]       bit_q;
  logic             parity_en_q, parity_odd_q, parity_err_q;
  logic             sample;

  assign sample = (cnt_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rx_meta_q <= 1'b1;
      rx_q      <= 1'b1;
    end else begin
      rx_meta_q <= rx_i;
      rx_q      <= rx_meta_q;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      div_q        <= '0;
      cnt_q        <= '0;
      shift_q      <= '0;
      bit_q        <= '0;
      parity_en_q  <= 1'b0;
      parity_odd_q <= 1'b0;
      parity_err_q <= 1'b0;
      rx_valid_o   <= 1'b0;
      rx_data_o    <= '0;
      parity_err_o <= 1'b0;
      frame_err_o  <= 1'b0;
    end else begin
      rx_valid_o <= 1'b0;
      cnt_q      <= sample ? div_q - 1'b1 : cnt_q - 1'b1;
      unique case (state_q)
        S_IDLE: begin
          if (!rx_q) begin
            state_q      <= S_START;
            div_q        <= clks_per_bit_i;
            // To the middle of the start bit. The synchroniser delays the start
            // edge and every later sample equally, so no compensation is needed.
            cnt_q        <= (clks_per_bit_i >> 1) - 1'b1;
            parity_en_q  <= parity_en_i;
            parity_odd_q <= parity_odd_i;
            parity_err_q <= 1'b0;
            bit_q        <= '0;
          end
        end
        S_START: begin
          if (sample) state_q <= rx_q ? S_IDLE : S_DATA;       // high again: glitch
        end
        S_DATA: begin
          if (sample) begin
            shift_q <= {rx_q, shift_q[7:1]};
            bit_q   <= bit_q + 1'b1;
            if (bit_q == 3'd7) state_q <= parity_en_q ? S_PARITY : S_STOP;
          end
        end
        S_PARITY: begin
          if (sample) begin
            parity_err_q <= rx_q ^ (^shift_q) ^ parity_odd_q;
            state_q      <= S_STOP;
          end
        end
        S_STOP: begin
          if (sample) begin
            rx_valid_o   <= 1'b1;
            rx_data_o    <= shift_q;
            parity_err_o <= parity_err_q;
            frame_err_o  <= !rx_q;
            state_q      <= rx_q ? S_IDLE : S_WAIT_IDLE;
          end
        end
        S_WAIT_IDLE: begin
          if (rx_q) state_q <= S_IDLE;
        end
        // verilator coverage_off
        default: state_q <= S_IDLE;   // unreachable: all encodings handled
        // verilator coverage_on
      endcase
    end
  end

`ifndef SYNTHESIS
  a_valid_pulse: assert property (@(posedge clk_i) disable iff (!rst_ni)
                                  rx_valid_o |=> !rx_valid_o);

  c_false_start: cover property (@(posedge clk_i) disable iff (!rst_ni)
                                 state_q == S_START && sample && rx_q);
  c_wait_idle:   cover property (@(posedge clk_i) disable iff (!rst_ni) state_q == S_WAIT_IDLE);
`endif

endmodule
