# RTL portfolio

Ten synthesizable SystemVerilog blocks, each with a self-checking randomized
testbench, assertions, functional coverage and mutation testing. The whole
flow runs on open-source tools: **Verilator 5** (simulation, lint, coverage)
and **Yosys** (synthesis).

| Module | What it is | Verification highlights |
|---|---|---|
| [`sync_fifo`](modules/sync_fifo) | Single-clock FWFT FIFO, wrap-bit pointers, overflow/underflow flags | Cycle-accurate queue model + scoreboard |
| [`async_fifo`](modules/async_fifo) | Dual-clock FIFO, Gray pointers, 2-FF synchronisers, pessimistic flags | Two free-running clocks with a changing ratio, independent reader/writer processes |
| [`rr_arbiter`](modules/rr_arbiter) | N-way round-robin arbiter, priority frozen while stalled | Reference model + fairness (starvation) monitor |
| [`uart`](modules/uart) | Full-duplex UART: parity, 1/2 stop bits, glitch rejection, framing errors | Time-based serial monitor/driver, baud skew, error injection, loopback |
| [`spi_master`](modules/spi_master) | SPI master, all four CPOL/CPHA modes, programmable divider | Behavioural slave driven only by `cs_n`/`sclk` edges, SCLK timing checks |
| [`apb_regfile`](modules/apb_regfile) | APB4 slave: RO/RW/W1C registers, `pstrb`, `pslverr`, interrupts | APB master BFM + register model |
| [`axis_skid_buffer`](modules/axis_skid_buffer) | AXI4-Stream register slice, full throughput, all outputs registered | Random valid/ready, throughput phase, check that `tready` has no combinational path |
| [`crc`](modules/crc) | Parameterised parallel CRC (Rocksoft model), N bytes per cycle | Catalogue check values, two independent reference models, 32-bit vs 8-bit instance |
| [`seq_divider`](modules/seq_divider) | Radix-2 restoring divider, RISC-V divide-by-zero semantics | Corner-class operand generation, latency and handshake checks |
| [`fir_filter`](modules/fir_filter) | Pipelined direct-form FIR, full-precision signed fixed point | Bit-exact convolution model: impulse, step, extremes, bursty streams |

Every RTL file starts with a header that serves as its specification; every
testbench header explains the checking strategy.

## Quick start

Requires `verilator` (5.x, with `--timing`), `yosys`, `python3`, and
optionally `lcov` for an HTML coverage report.

```sh
make test               # build and run every module with seeds 1 2 3
make test MOD=crc       # one module
make cov                # regression + coverage table (build/coverage.md)
make lint               # verilator -Wall on the RTL only
make synth              # yosys generic synthesis, cell counts
make mutate             # mutation testing
make SEEDS="1 2 3 4 5"  # change the regression seed list
```

A run passes only if the simulator exits cleanly **and** prints `TEST PASSED`.
`tb_pkg::finish()` also fails a test that executed no checks.

## Verification approach

- **Self-checking, randomized.** Each testbench drives constrained-random
  stimulus alongside directed corner cases and compares the DUT with a
  reference model or scoreboard every cycle or transaction. Seeds come from
  `+verilator+seed`, so any failure can be reproduced.
- **Assertions.** Concurrent SVA properties embedded in the RTL (under
  `ifndef SYNTHESIS`) check invariants and protocol rules, such as FIFO
  occupancy stepping and AXI valid/data stability. `cover property`
  statements in the testbenches mark scenarios that must occur.
- **Functional coverage.** Verilator does not support covergroups yet, so
  [`common/tb_pkg.sv`](common/tb_pkg.sv) provides a small bin collector:
  bins are declared up front, which means missed bins are reported instead of
  silently absent.
- **Code coverage.** Line, branch and toggle coverage from Verilator are
  merged across seeds by [`scripts/coverage_report.py`](scripts/coverage_report.py),
  which also produces an lcov `.info` file.
- **Mutation testing.** [`scripts/mutate.py`](scripts/mutate.py) injects 19
  realistic bugs into the RTL, such as a Gray-code full flag decoded from the
  wrong bits, a lost W1C interrupt event, or products added unsigned. It then
  checks that the tests catch each one. 100% coverage shows that the code was
  exercised; mutation testing shows that the checks would catch a bug in it.

## Results

Regression with seeds 1, 2 and 3:

| Module | Line | Branch | Toggle | Functional | Mutants killed | Yosys cells |
|---|---|---|---|---|---|---|
| `sync_fifo` | 100% | 100% | 100% | 18/18 | 2/2 | 350 |
| `async_fifo` | 100% | 100% | 100% | 9/9 | 1/1 | 391 |
| `rr_arbiter` | 100% | 100% | 100% | 23/23 | 2/2 | 42 |
| `uart` | 100% | 100% | 100% | 58/58 | 2/2 | 611 |
| `spi_master` | 100% | 100% | 100% | 22/22 | 2/2 | 165 |
| `apb_regfile` | 100% | 100% | 100% | 38/38 | 2/2 | 503 |
| `axis_skid_buffer` | 100% | 100% | 100% | 15/15 | 2/2 | 112 |
| `crc` | 100% | 100% | 100% | 10/10 | 2/2 | 272 |
| `seq_divider` | 100% | 100% | 100% | 43/43 | 2/2 | 558 |
| `fir_filter` | 100% | 100% | 100% | 9/9 | 2/2 | 16131 |

Cell counts come from Yosys generic `synth` with default parameters and are
meant for comparing blocks, not as an estimate for any particular technology.
The FIR filter's count is dominated by its eight 16×16 multipliers, which
are built from gates here and would map to DSP blocks on an FPGA.

## Layout

```
common/tb_pkg.sv          shared checks, RNG warm-up, functional coverage bins
modules/<name>/rtl/       synthesizable RTL
modules/<name>/tb/        testbench (top: tb_<name>)
scripts/coverage_report.py  merge coverage across seeds -> markdown + lcov
scripts/mutate.py         mutation testing
Makefile                  build / regression / coverage / lint / synth flow
```
