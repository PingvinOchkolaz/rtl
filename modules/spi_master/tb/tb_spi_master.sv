// -----------------------------------------------------------------------------
// tb_spi_master — master DUT against a behavioural SPI slave model.
//
// The slave reacts only to cs_n/sclk edges (no knowledge of the DUT clock),
// shifts a random word out on MISO and captures MOSI according to the
// selected mode. It also measures SCLK timing and idle levels.
// -----------------------------------------------------------------------------
module tb_spi_master;
  import tb_pkg::*;

  localparam int unsigned N      = 8;
  localparam real         CLK_NS = 10.0;

  logic         clk = 1'b0;
  logic         rst_n = 1'b0;
  logic         cpol = 1'b0, cpha = 1'b0;
  logic [7:0]   div = '0;
  logic         start_req = 1'b0, ready, done;
  logic [N-1:0] tx_data = '0, rx_data;
  logic         sclk, mosi, miso = 1'b0, cs_n;

  always #(CLK_NS / 2) clk = ~clk;

  spi_master #(.DATA_W(N), .DIV_W(8)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .cpol_i(cpol), .cpha_i(cpha), .clk_div_i(div),
    .start_i(start_req), .tx_data_i(tx_data), .ready_o(ready), .done_o(done),
    .rx_data_o(rx_data),
    .sclk_o(sclk), .mosi_o(mosi), .miso_i(miso), .cs_n_o(cs_n)
  );

  logic [N-1:0] mosi_exp [$];     // words the master should send
  logic [N-1:0] miso_exp [$];     // words the slave sent: master must receive
  int unsigned  n_xfers;

  // ---------------------------------------------------------- slave model --
  initial forever begin
    logic [N-1:0] s_tx, s_rx;
    int           tx_idx, n_rx;
    realtime      t_last;
    real          half_ns;
    @(negedge cs_n);
    check_eq(sclk, cpol, "SCLK idle level at CS assertion");
    half_ns = (div + 1) * CLK_NS;
    s_tx    = N'($urandom);
    s_rx    = '0;
    n_rx    = 0;
    tx_idx  = N - 1;
    if (!cpha) miso = s_tx[tx_idx--];         // CPHA=0: first bit before first edge
    t_last  = $realtime;
    forever begin
      @(sclk or posedge cs_n);
      if (cs_n) break;
      // The first edge follows the CS setup time, later ones half a period.
      check($realtime - t_last == half_ns,
            $sformatf("SCLK half period %0t, expected %0.1f ns", $realtime - t_last, half_ns));
      t_last = $realtime;
      if ((sclk != cpol) ^ cpha) begin        // sampling edge
        s_rx = {s_rx[N-2:0], mosi};
        n_rx++;
      end else if (tx_idx >= 0) begin         // shifting edge
        miso = s_tx[tx_idx--];
      end
    end
    check($realtime - t_last == half_ns, "CS hold time");
    check_eq(sclk, cpol, "SCLK idle level at CS release");
    check_eq(n_rx, N, "number of sampled bits");
    check(mosi_exp.size() != 0, "transfer without a request");
    if (mosi_exp.size() != 0) check_eq(s_rx, mosi_exp.pop_front(), "MOSI word");
    miso_exp.push_back(s_tx);
    miso = 1'($urandom);                      // bus garbage between transfers
  end

  // ------------------------------------------------------ done monitoring --
  always @(negedge clk) begin
    if (rst_n && done) begin
      check(miso_exp.size() != 0, "done without a finished transfer");
      if (miso_exp.size() != 0) check_eq(rx_data, miso_exp.pop_front(), "rx_data_o (MISO word)");
      check_eq(cs_n, 1'b1, "cs_n released with done");
      n_xfers++;
    end
  end

  // -------------------------------------------------------------- driver ---
  task automatic transfer(logic [N-1:0] d, bit keep_start = 1'b0);
    @(negedge clk);
    start_req = 1'b1;
    tx_data   = d;
    while (!ready) @(negedge clk);
    mosi_exp.push_back(d);
    cov_sample($sformatf("mode%0d.div%0d", {cpol, cpha}, div), 1'b0);
    if (!keep_start) begin
      @(negedge clk);
      start_req = 1'b0;
      // Hold changes of mode/divider until the transfer is over.
      wait (done);
    end else begin
      @(negedge clk);
      cov_sample("back_to_back");
    end
  endtask

  task automatic set_mode(int unsigned mode, int unsigned d);
    wait (ready && !start_req);
    @(negedge clk);
    {cpol, cpha} = 2'(mode);
    div          = 8'(d);
  endtask

  localparam int unsigned DIVS [5] = '{0, 1, 2, 7, 255};

  initial begin
    start("spi_master");
    for (int m = 0; m < 4; m++)
      foreach (DIVS[i]) cov_declare($sformatf("mode%0d.div%0d", m, DIVS[i]));
    cov_declare("back_to_back");
    cov_declare("mode_switch_in_idle");

    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    for (int m = 0; m < 4; m++) begin
      foreach (DIVS[i]) begin
        set_mode(m, DIVS[i]);
        transfer('0);
        transfer('1);
        transfer(N'('hA5));
        repeat (DIVS[i] > 7 ? 2 : 10) transfer(N'($urandom));
      end
      // Back-to-back transfers with start held high.
      set_mode(m, 1);
      repeat (5) transfer(N'($urandom), 1'b1);
      @(negedge clk);
      start_req = 1'b0;
      wait (mosi_exp.size() == 0 && miso_exp.size() == 0);
    end

    // Random modes and dividers; switching mode between transfers.
    repeat (60) begin
      set_mode($urandom_range(3, 0), $urandom_range(12, 0));
      cov_sample("mode_switch_in_idle");
      transfer(N'($urandom));
    end

    wait (mosi_exp.size() == 0 && miso_exp.size() == 0);
    repeat (5) @(negedge clk);
    $display("[spi_master] %0d transfers", n_xfers);
    finish();
  end

endmodule
