// -----------------------------------------------------------------------------
// tb_uart — UART core verification.
//
//  * TX: a time-based serial monitor decodes tx_o at bit centres, independent
//    of the DUT clock, and checks start/data/parity/stop bits.
//  * RX: a serial driver generates frames with optional baud skew, bad
//    parity, bad stop bit and short glitches.
//  * Loopback: tx_o is fed back into rx_i.
// Every combination of divisor x parity x stop bits is exercised.
// -----------------------------------------------------------------------------
module tb_uart;
  import tb_pkg::*;

  localparam real CLK_NS = 10.0;

  logic        clk = 1'b0;
  logic        rst_n = 1'b0;
  logic [15:0] div = 16'd16;
  logic        par_en = 1'b0, par_odd = 1'b0, stop2 = 1'b0;
  logic        tx_valid = 1'b0, tx_ready, tx;
  logic [7:0]  tx_data = '0;
  logic        rx_line = 1'b1, loopback = 1'b0;
  logic        rx_valid, par_err, frm_err;
  logic [7:0]  rx_data;

  always #(CLK_NS / 2) clk = ~clk;

  uart dut (
    .clk_i(clk), .rst_ni(rst_n),
    .clks_per_bit_i(div), .parity_en_i(par_en), .parity_odd_i(par_odd), .stop2_i(stop2),
    .tx_valid_i(tx_valid), .tx_data_i(tx_data), .tx_ready_o(tx_ready), .tx_o(tx),
    .rx_i(loopback ? tx : rx_line),
    .rx_valid_o(rx_valid), .rx_data_o(rx_data), .parity_err_o(par_err), .frame_err_o(frm_err)
  );

  typedef struct {
    logic [7:0] data;
    bit         par_err;
    bit         frm_err;
  } rx_item_t;

  logic [7:0] tx_exp [$];
  rx_item_t   rx_exp [$];
  bit         in_grid;          // current config is one of the declared bins

  function automatic string cfg_name();
    string par;
    if (!par_en)      par = "none";
    else if (par_odd) par = "odd";
    else              par = "even";
    return $sformatf("div%0d.%s.stop%0d", div, par, stop2 ? 2 : 1);
  endfunction

  function automatic logic parity_bit(logic [7:0] d);
    return ^d ^ par_odd;
  endfunction

  // ----------------------------------------------------------- TX monitor --
  initial begin
    @(posedge rst_n);
    forever begin
      real        t_bit;
      logic [7:0] d;
      @(negedge tx);
      t_bit = div * CLK_NS;
      #(t_bit / 2);
      check(tx === 1'b0, "tx start bit");
      for (int i = 0; i < 8; i++) begin
        #(t_bit);
        d[i] = tx;
      end
      if (par_en) begin
        #(t_bit);
        check_eq(tx, parity_bit(d), "tx parity bit");
      end
      #(t_bit);
      check(tx === 1'b1, "tx stop bit 1");
      if (stop2) begin
        #(t_bit);
        check(tx === 1'b1, "tx stop bit 2");
      end
      check(tx_exp.size() != 0, "tx frame without a request");
      if (tx_exp.size() != 0) check_eq(d, tx_exp.pop_front(), "tx data");
      if (in_grid) cov_sample({"tx_cfg.", cfg_name()});
    end
  end

  // ----------------------------------------------------------- RX monitor --
  always @(negedge clk) begin
    if (rst_n && rx_valid) begin
      rx_item_t e;
      check(rx_exp.size() != 0, $sformatf("unexpected rx frame 0x%02h", rx_data));
      if (rx_exp.size() != 0) begin
        e = rx_exp.pop_front();
        check_eq(rx_data, e.data, "rx data");
        check_eq(par_err, e.par_err, "rx parity_err");
        check_eq(frm_err, e.frm_err, "rx frame_err");
      end
    end
  end

  // -------------------------------------------------------------- drivers --
  task automatic send_tx(logic [7:0] d, bit expect_rx = 1'b0);
    @(negedge clk);
    tx_valid = 1'b1;
    tx_data  = d;
    while (!tx_ready) @(negedge clk);
    tx_exp.push_back(d);                      // accepted at the next rising edge
    if (expect_rx) rx_exp.push_back('{d, 1'b0, 1'b0});
    @(negedge clk);
    tx_valid = 1'b0;
  endtask

  // skew_pct: TB bit time deviates from the DUT's by this percentage.
  task automatic drive_rx(logic [7:0] d, bit bad_par = 0, bit bad_stop = 0,
                          real skew_pct = 0.0, int unsigned gap_bits = 1);
    real t_bit = div * CLK_NS * (1.0 + skew_pct / 100.0);
    rx_exp.push_back('{d, par_en && bad_par, bad_stop});
    rx_line = 1'b0;
    #(t_bit);
    for (int i = 0; i < 8; i++) begin
      rx_line = d[i];
      #(t_bit);
    end
    if (par_en) begin
      rx_line = parity_bit(d) ^ bad_par;
      #(t_bit);
    end
    rx_line = !bad_stop;
    #(t_bit);
    rx_line = 1'b1;
    #(t_bit * gap_bits);
    if (bad_stop) cov_sample("rx.frame_err");
    if (par_en && bad_par) cov_sample("rx.parity_err");
    if (gap_bits == 0) cov_sample("rx.back_to_back");
    if (skew_pct > 0) cov_sample("rx.baud_slow");
    if (skew_pct < 0) cov_sample("rx.baud_fast");
  endtask

  // A low pulse shorter than half a bit must be ignored.
  task automatic glitch_rx();
    rx_line = 1'b0;
    #(div * CLK_NS * 0.3);
    rx_line = 1'b1;
    #(div * CLK_NS * 2);
    cov_sample("rx.glitch_rejected");
  endtask

  task automatic wait_idle();
    wait (tx_exp.size() == 0 && rx_exp.size() == 0 && tx_ready);
    repeat (div * 2) @(posedge clk);
  endtask

  // --------------------------------------------------------- one config ---
  task automatic run_config(int unsigned d, bit pe, bit po, bit s2, bit grid = 1'b1);
    div     = 16'(d);
    par_en  = pe;
    par_odd = po;
    stop2   = s2;
    in_grid = grid;
    if (grid) cov_sample({"rx_cfg.", cfg_name()});

    // TX with random data, including the all-zero / all-one corners.
    send_tx(8'h00);
    send_tx(8'hFF);
    repeat (6) send_tx(8'($urandom));
    wait_idle();

    // RX: clean frames, then error injection.
    drive_rx(8'h00);
    drive_rx(8'hFF);
    repeat (4) drive_rx(8'($urandom), 0, 0, 0.0, $urandom_range(2, 0));
    drive_rx(8'($urandom), 1, 0);            // bad parity (ignored if disabled)
    drive_rx(8'($urandom), 0, 1);            // bad stop bit -> framing error
    drive_rx(8'($urandom), 1, 1);
    glitch_rx();
    drive_rx(8'($urandom));                  // receiver recovered
    if (d >= 16) begin
      drive_rx(8'($urandom), 0, 0, +3.0);    // baud tolerance
      drive_rx(8'($urandom), 0, 0, -3.0);
    end
    wait_idle();

    // Loopback.
    loopback = 1'b1;
    repeat (4) send_tx(8'($urandom), 1'b1);
    wait_idle();
    loopback = 1'b0;
  endtask

  // ------------------------------------------------------------- sequence --
  localparam int unsigned DIVS [4] = '{4, 7, 16, 27};

  initial begin
    start("uart");
    for (int i = 0; i < 4; i++)
      for (int p = 0; p < 3; p++)
        for (int s = 0; s < 2; s++) begin
          div = 16'(DIVS[i]); par_en = (p != 0); par_odd = (p == 2); stop2 = s[0];
          cov_declare({"tx_cfg.", cfg_name()});
          cov_declare({"rx_cfg.", cfg_name()});
        end
    cov_declare("rx.frame_err");
    cov_declare("rx.parity_err");
    cov_declare("rx.back_to_back");
    cov_declare("rx.baud_slow");
    cov_declare("rx.baud_fast");
    cov_declare("rx.glitch_rejected");
    cov_declare("div.max");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int i = 0; i < 4; i++)
      for (int p = 0; p < 3; p++)
        for (int s = 0; s < 2; s++)
          run_config(DIVS[i], p != 0, p == 2, s[0]);

    // Slowest baud rate: the full divisor range (counter-width corner).
    div = 16'hFFFF; par_en = 1'b1; par_odd = 1'b1; stop2 = 1'b1; in_grid = 1'b0;
    send_tx(8'($urandom));
    wait_idle();
    drive_rx(8'($urandom));
    wait_idle();
    cov_sample("div.max");

    // Divisor change and random configuration order.
    repeat (6) run_config($urandom_range(40, 4), $urandom_range(1, 0), $urandom_range(1, 0),
                          $urandom_range(1, 0), 1'b0);
    finish();
  end

  // Protocol-level covers (false start, wait-for-idle, back-to-back TX) live
  // in the RTL next to the FSMs they observe.

endmodule
