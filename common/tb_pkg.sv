// -----------------------------------------------------------------------------
// tb_pkg — shared testbench utilities:
//   * check/report helpers and RNG warm-up;
//   * a light-weight functional coverage collector ("bins"), a stand-in for
//     covergroups, which Verilator does not support yet. Bins are declared up
//     front so that unhit bins are reported, sampled from the testbench and
//     written to +func_cov=<file> at the end of the test.
// Every testbench calls tb_pkg::start() first and tb_pkg::finish() last.
// -----------------------------------------------------------------------------
package tb_pkg;

  int unsigned n_checks = 0;
  int unsigned n_errors = 0;
  int unsigned max_errors = 10;
  string       test_name = "tb";

  // The simulator's generator returns poorly mixed values for small seeds on the
  // first draws, so discard a few before the test starts.
  function automatic void start(string name);
    test_name = name;
    repeat (64) void'($urandom);
    $display("[%s] ===== test started =====", test_name);
  endfunction

  function automatic void check(bit cond, string what);
    n_checks++;
    if (!cond) begin
      n_errors++;
      $error("[%s] CHECK FAILED: %s", test_name, what);
      if (n_errors >= max_errors) begin
        $display("[%s] too many errors, aborting", test_name);
        $fatal(1, "[%s] TEST FAILED", test_name);
      end
    end
  endfunction

  function automatic void check_eq(logic [63:0] act, logic [63:0] exp, string what);
    check(act === exp, $sformatf("%s: got 0x%0h, expected 0x%0h", what, act, exp));
  endfunction

  function automatic int unsigned rand_range(int unsigned lo, int unsigned hi);
    return $urandom_range(hi, lo);
  endfunction

  // Returns 1 with probability pct/100.
  function automatic bit chance(int unsigned pct);
    return $urandom_range(99, 0) < pct;
  endfunction

  // ------------------------------------------------- functional coverage --
  int unsigned cov_bins [string];

  function automatic void cov_declare(string name);
    if (!cov_bins.exists(name)) cov_bins[name] = 0;
  endfunction

  function automatic void cov_declare_range(string group, int lo, int hi);
    for (int i = lo; i <= hi; i++) cov_declare($sformatf("%s.%0d", group, i));
  endfunction

  // strict = 0: silently ignore undeclared bins (e.g. a cross restricted to a
  // declared grid of values while the stimulus also uses other values).
  function automatic void cov_sample(string name, bit strict = 1'b1);
    if (!cov_bins.exists(name)) begin
      if (!strict) return;
      $error("[%s] coverage bin '%s' was not declared", test_name, name);
      cov_bins[name] = 0;
    end
    cov_bins[name]++;
  endfunction

  function automatic void cov_dump();
    string path;
    int    fd;
    int unsigned hit = 0;
    if (cov_bins.size() == 0) return;
    if (!$value$plusargs("func_cov=%s", path)) path = "func_cov.txt";
    fd = $fopen(path, "w");
    foreach (cov_bins[k]) begin
      $fdisplay(fd, "%s %0d", k, cov_bins[k]);
      if (cov_bins[k] != 0) hit++;
      else $display("[%s] coverage bin not hit: %s", test_name, k);
    end
    $fclose(fd);
    $display("[%s] functional bins: %0d/%0d hit", test_name, hit, cov_bins.size());
  endfunction

  function automatic void finish();
    cov_dump();
    if (n_errors != 0)
      $fatal(1, "[%s] TEST FAILED: %0d error(s) in %0d checks", test_name, n_errors, n_checks);
    if (n_checks == 0)
      $fatal(1, "[%s] TEST FAILED: no checks were executed", test_name);
    $display("[%s] TEST PASSED: %0d checks", test_name, n_checks);
    $finish;
  endfunction

endpackage
