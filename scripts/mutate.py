#!/usr/bin/env python3
"""Mutation testing: inject typical RTL bugs and make sure the tests catch them.

Each mutant replaces one exact code fragment in an RTL file, rebuilds and runs
that module's test with one seed, then restores the file. A mutant that
passes the test ("survivor") points at a hole in the verification.

Usage: mutate.py [module ...]      (default: all mutants)
"""
import os
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SIGTERM/SIGHUP (closed terminal, killed job) would otherwise skip the
# `finally` below and leave a mutant in the RTL.
def _abort(signum, _frame):
    raise SystemExit(128 + signum)

for _sig in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(_sig, _abort)

# (module, file, original fragment, mutated fragment, description)
MUTANTS = [
    ("sync_fifo", "sync_fifo.sv", "assign rd_fire = rd_en_i && !empty_o;",
     "assign rd_fire = rd_en_i;", "read allowed while empty"),
    ("sync_fifo", "sync_fifo.sv", "overflow_o  <= wr_en_i && full_o;",
     "overflow_o  <= 1'b0;", "overflow flag stuck at 0"),
    ("async_fifo", "async_fifo.sv",
     "full_o  <= (wgray_d == {~rgray_sync[AW:AW-1], rgray_sync[AW-2:0]});",
     "full_o  <= (wgray_d == {~rgray_sync[AW], rgray_sync[AW-1:0]});",
     "full flag decoded from wrong Gray bits"),
    ("rr_arbiter", "rr_arbiter.sv", "mask_q <= ~((gnt_o << 1) - 1'b1);",
     "mask_q <= ~(gnt_o - 1'b1);", "priority pointer not advanced past winner"),
    ("rr_arbiter", "rr_arbiter.sv", "end else if (gnt_valid_o && ready_i) begin",
     "end else if (gnt_valid_o) begin", "priority rotates while stalled"),
    ("uart", "uart_tx.sv", "parity_q    <= ^tx_data_i ^ parity_odd_i;",
     "parity_q    <= ^tx_data_i;", "odd parity ignored in TX"),
    ("uart", "uart_rx.sv", "if (sample) state_q <= rx_q ? S_IDLE : S_DATA;",
     "if (sample) state_q <= S_DATA;", "no glitch rejection on start bit"),
    ("spi_master", "spi_master.sv", "if (leading ^ cpha_q) begin",
     "if (leading) begin", "CPHA ignored for sampling"),
    ("spi_master", "spi_master.sv", "cnt_q  <= tick ? div_q : cnt_q - 1'b1;",
     "cnt_q  <= tick ? div_q - 1'b1 : cnt_q - 1'b1;", "SCLK half period one cycle short"),
    ("apb_regfile", "apb_regfile.sv", "assign err       = !mapped || (pwrite_i && ro);",
     "assign err       = !mapped;", "writes to RO registers not flagged"),
    ("apb_regfile", "apb_regfile.sv", "                  | irq_event_i;",
     "                  ;", "interrupt events lost"),
    ("axis_skid_buffer", "axis_skid_buffer.sv", "assign out_free = !out_valid_q || m_axis_tready_i;",
     "assign out_free = m_axis_tready_i;", "output register never fills without ready"),
    ("axis_skid_buffer", "axis_skid_buffer.sv", "      if (m_axis_tready_i) out_q <= skid_q;",
     "      if (m_axis_tready_i) out_q <= out_q;", "skid word dropped"),
    ("crc", "crc.sv", "for (int unsigned i = 0; i < 8; i++) b[i] = REFIN ? d[8*n + 7 - i] : d[8*n + i];",
     "for (int unsigned i = 0; i < 8; i++) b[i] = d[8*n + i];", "REFIN ignored"),
    ("crc", "crc.sv", "else if (clear_i)  state_q <= valid_i ? crc_update(INIT, data_i) : INIT;",
     "else if (clear_i)  state_q <= INIT;", "data lost when clear and valid coincide"),
    ("seq_divider", "seq_divider.sv", "assign diff  = trial - {1'b0, divisor_q};",
     "assign diff  = {1'b0, rem_q} - {1'b0, divisor_q};", "dividend bit not brought down"),
    ("seq_divider", "seq_divider.sv", "rem_q  <= dividend_i;",
     "rem_q  <= '0;", "wrong remainder on division by zero"),
    ("fir_filter", "fir_filter.sv", "for (int unsigned k = 1; k < TAPS; k++) x_q[k] <= x_q[k-1];",
     "for (int unsigned k = 2; k < TAPS; k++) x_q[k] <= x_q[k-1];", "delay line tap 1 stuck"),
    ("fir_filter", "fir_filter.sv", "for (int unsigned k = 0; k < TAPS; k++) sum += OUT_W'(prod_q[k]);",
     "for (int unsigned k = 0; k < TAPS; k++) sum += OUT_W'($unsigned(prod_q[k]));",
     "products added unsigned"),
]

def run(mod):
    cmd = ["make", "--no-print-directory", f"test-{mod}", "SEEDS=1"]
    r = subprocess.run(cmd, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return r.returncode == 0


def main():
    only = set(sys.argv[1:])
    killed, survived = 0, []
    for mod, fname, orig, mut, desc in MUTANTS:
        if only and mod not in only:
            continue
        path = os.path.join(ROOT, "modules", mod, "rtl", fname)
        src = open(path).read()
        if src.count(orig) != 1:
            print(f"[ERROR] {mod}: fragment not found exactly once: {orig!r}")
            sys.exit(2)
        try:
            with open(path, "w") as f:
                f.write(src.replace(orig, mut))
            passed = run(mod)
        finally:
            with open(path, "w") as f:
                f.write(src)
        if passed:
            survived.append((mod, desc))
            print(f"[SURVIVED] {mod}: {desc}")
        else:
            killed += 1
            print(f"[KILLED]   {mod}: {desc}")
    total = killed + len(survived)
    print(f"\nmutants killed: {killed}/{total}")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
