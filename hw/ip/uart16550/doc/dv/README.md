# UART 16550 DV

This page defines the first (V1) DV target for the UART 16550 wrapper: one smoke test with a
single selected configuration.
It is written before the bench so that the checks are agreed first.
The testpoints are in [`data/uart16550_testplan.hjson`](../../data/uart16550_testplan.hjson).

**Status:** test contract only. The UVM bench and the `uart16550_smoke` test do not exist yet.

## Sources

Expected behaviour comes from these sources, not from the RTL:

1. TI PC16550D datasheet, SNLS378C, Rev C, May 2015.
   Copy used: <https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf>,
   SHA-256 `dee039d0fc7d6e236e7864211bf7cd60fc7c904403c4ca4e5f53e291c07e00f9`.
   The [archived copy](https://web.archive.org/web/20180826215135/http://www.ti.com/lit/ds/symlink/pc16550d.pdf)
   linked from the README has not been checked against this one.
2. The wrapper exceptions in [`README.md`](../../README.md) and [`registers.md`](../registers.md).
   Where they differ from the datasheet, the wrapper documents win.
3. OpenTitan UART [programmer's guide](../../../../vendor/lowrisc_ip/ip/uart/doc/programmers_guide.md)
   and [theory of operation](../../../../vendor/lowrisc_ip/ip/uart/doc/theory_of_operation.md),
   for the baud rate and receiver sampling.

The contract is pinned to commit `356f09deec62b49c76384ffb085c2d559354ae38`.
PR #13 (IIR receive timeout) and PR #14 (HJSON/RDL, vendor directory move) were open at that
point. Neither changes the smoke expectations below, but re-check them if either merges.

## Smoke test contract

### Fixed configuration

| Item | Value | Source |
|-|-|-|
| Clock | 50 MHz (20 ns) | `registers.md`, DLL row |
| Reset | `rst_ni` low for at least 10 clock cycles | Bench choice |
| Baud rate | DUT: 50 MHz x 20972 / 2^20 = 1,000,023 baud. Bench: 1,000,000 baud (1000 ns bit time). The 0.002% difference is far inside the receiver's +/-5.5% tolerance. | `registers.md`, DLL row; OT programmer's guide and theory of operation |
| Frame | 8 data bits, no parity, 1 stop bit; start bit 0, data LSB first, stop bit 1. The wrapper also supports parity; the smoke uses only this one selected mode. | Datasheet Table 1 note 1, Section 8.6.2; `registers.md` LCR row |
| Bus | TL-UL `PutFullData`/`Get`, `a_size` 2, `a_mask` 0xF, word-aligned, upper 3 data bytes written as 0 | `registers.md` |
| Interrupts | Not used (IER = 0); status is polled through LSR | Bench choice |
| Serial input | Driven high (idle) from reset | Datasheet Section 8.6.3, BI |

The divisor value does not set the baud rate in this wrapper.
DLL = 0x03 is still written because it is the nearest datasheet divisor for 1 Mbaud at 50 MHz
(50 MHz / (16 x 1 Mbaud) = 3.125, Section 8.5.1), and because the first DLL/DLM write enables
TX and RX.

### Sequence and expected values

All register reads compare the full 32-bit data (upper 3 bytes read 0) and require `d_error` = 0.
Offsets are byte addresses.

| Step | Access | Expected | Source |
|-|-|-|-|
| 1 | Reset, then check `cio_tx_o` | 1 (idle) | Datasheet Table 3, SOUT |
| 2 | Read IER (0x4), IIR (0x8), LCR (0xC), MCR (0x10), LSR (0x14), MSR (0x18) | 0x00, 0x01, 0x13, 0x00, 0x60, 0x00 | Datasheet Table 3; LCR and MSR rows of `registers.md` |
| 3 | Write LCR = 0x83, read LCR | 0x83 | Section 8.6.2; `registers.md` LCR row |
| 4 | Write DLL (0x0) = 0x03, DLM (0x4) = 0x00, read both | 0x03, 0x00 | `registers.md` DLL/DLM rows |
| 5 | Write LCR = 0x03, read LCR | 0x03 | as step 3 |
| 6 | Write FCR (0x8) = 0x07 | - | Datasheet Section 8.6.4; `registers.md` FCR and IIR rows (trigger level 1 byte) |
| 7 | Write SCR (0x1C) = 0xA5, read SCR | 0xA5 | Section 8.6.9 |
| 8 | Write THR (0x0) = 0x55, 0x01, 0x80, 0x00 | 4 frames on `cio_tx_o`, same order | Section 8.6.2, Table 1 |
| 9 | Poll LSR until THRE and TEMT are set | 0x60 | Section 8.6.3 |
| 10 | Drive 0xAA, 0x02, 0x40, 0x7E on `cio_rx_i` | - | Bench choice |
| 11 | For each byte: poll LSR until DR = 1, check LSR[4:1] = 0 and LSR[7] = 0, read RBR | RBR = driven byte, same order | Section 8.6.3 |
| 12 | Wait 2 character times (20 us), then read LSR | No new TX frame; LSR = 0x60 | Section 8.6.3 |

Byte choices:

- TX 0x01 and 0x80 catch bit-order and off-by-one sampling errors; 0x55 alternates; 0x00 has the
  longest low period, so a missing stop bit is caught.
- RX avoids 0x00, because the wrapper returns 0 when RBR is read with an empty FIFO
  (`registers.md`, RBR row).
- RX and TX bytes differ, so a TX/RX mix-up does not match by accident.
- 4 bytes fit in both FIFOs (32 TX, 64 RX), so no flow control is needed.

### Checks that make the test fail

Each check reports `UVM_ERROR` (or `UVM_FATAL` for a timeout) when it fails:

1. A register read returns the wrong data, or any access returns `d_error` = 1.
2. A TX frame has the wrong data, a bad start bit or a bad stop bit.
3. A TX frame is seen when no byte is expected (unexpected data).
4. An RBR read returns the wrong byte, or LSR shows an error bit before the read.
5. Expected counts are exactly 4 TX and 4 RX bytes. At the end both expected queues must be empty.
   A missing transfer fails this check even if no comparison ever ran.
6. `intr_tx_watermark_o`, `intr_tx_done_o` or `intr_rx_timeout_o` goes high
   (the wrapper README says they are never enabled).
7. The alert protocol checker reports an error on `alert_tx_o`/`alert_rx_i`, or an alert is sent
   (see [Auxiliary outputs and tie-offs](#auxiliary-outputs-and-tie-offs)).
8. Any wait passes its limit (below).

### Bounded waits

These are starting values. Change them only with a recorded reason.

| Wait | Limit |
|-|-|
| One TL-UL access (from the request first being presented, `a_valid` = 1, to the response; this includes waiting for `a_ready`) | 1000 clock cycles |
| All 4 TX frames after the last THR write | 100 us (about 2.5x the 40 us needed) |
| LSR.THRE/TEMT after the last TX frame | 20 us |
| LSR.DR for each RX byte after its stop bit | 20 us |
| Whole test | 1 ms of simulated time (about 0.15 ms expected) |

### Pass criteria

The smoke passes only if all of these hold:

- the test reaches its end checks and they pass;
- the log has zero `UVM_ERROR` and zero `UVM_FATAL`, and no simulator error (`*E`, `*F`);
- the test prints its pass message; and
- the DVSim job status and the process exit status both report pass.

A build, elaboration or license failure is a tool failure, not a test result.
Report it separately and do not count it as a pass or a DUT failure.

## Negative controls

These show that the checks can fail.
Run each once with a test-only fault switch (off by default) or in a throw-away worktree,
confirm the failure reaches the DVSim and process status, then remove the fault and rerun the
clean smoke.

| Control | Fault | Expected result |
|-|-|-|
| Wrong TX byte | Write 0x54 instead of 0x55 to THR, expectation unchanged | TX mismatch, test fails |
| Wrong RX byte | Drive 0xAB instead of 0xAA, expectation unchanged | RBR mismatch, test fails |
| Missing TX transfer | Skip one THR write, expected count stays 4 | TX timeout or non-empty queue at end, test fails |
| Missing RX transfer | Skip one RX frame, expected count stays 4 | LSR.DR wait times out, test fails |
| Extra TX byte | Write one extra THR byte that is not expected | Unexpected-data error, test fails |
| Tool failure | Remove a source file from the build | Build failure, reported as a tool failure |

## Auxiliary outputs and tie-offs

| Port | Smoke bench | Check in V1 |
|-|-|-|
| `alert_rx_i` / `alert_tx_o` | Driven by an OpenTitan `alert_esc_agent` acting as the alert receiver, so `alert_rx_i` always carries legal differential values and any alert gets a legal ack. No pings are sent in V1. | Alert protocol checked passively for the whole test by the agent's monitor and interface checks; no alert sent |
| `racl_policies_i` / `racl_error_o` | `RACL_POLICY_VEC_DEFAULT` | Observed only (RACL is not implemented) |
| `lsio_trigger_o` | Observed | None |
| `cio_tx_en_o` | Observed | None (not a 16550 signal) |
| `intr_tx_watermark_o`, `intr_tx_done_o`, `intr_rx_timeout_o` | Observed | Stay low |
| Other `intr_*_o` | Observed | None in V1 (see the `interrupts` testpoint) |

## Planned bench

Reuse OpenTitan DV components where they save work, without the full CIP layer for V1:

- `dv_lib` base classes, `tl_agent` (host), `uart_agent` (supports 1 Mbaud) and
  `alert_esc_agent` (alert receiver and passive protocol checks).
  Register accesses use small helper tasks on raw offsets. A complete RAL model is not required.
- Not `cip_lib` for V1. At OpenTitan `012fb0fe`, `cip_base_env_cfg` stops with a fatal error when
  the register block has no `alert_test` register, and the 16550 map has none.
  Its generic register checks would also run before the custom data checks.
  Alert protocol checking is kept by instantiating `alert_esc_agent` directly.
  If that agent does not check the differential encoding and handshake on its own, the first
  bench slice adds a small assertion checker on the alert interface.
- Directed alert fault injection and ping tests are later work (V2 `alerts` testpoint).
- These libraries are not vendored yet. They need `hw/dv/sv` (including `bus_params_pkg` and
  `alert_esc_agent` with its dependencies) and
  the DVSim configuration from `hw/dv/tools` at the same OpenTitan revision, with no RTL change.
  This must be coordinated with the vendor directory move in PR #14.
- `dv_base_env_cfg` always creates a register model of type `RAL_T`. Using it with no generated
  register model has to be proven first in the next slice.

## Running

The existing flows are unchanged:

```sh
fusesoc --cores-root=. run --target=lint lowrisc:ip:uart16550
fusesoc --cores-root=. run --target=sim lowrisc:dv:uart16550_tb   # pre_dv, prints "Test passed!"
```

Both need Verilator 5.054 or newer (from the project dev shell).

The smoke test will be run with DVSim and Xcelium. The command will be added with the bench.

## Later work

V2 and V3 testpoints in the testplan list later work: full CSR checks, TL-UL errors, interrupts,
FIFO limits and overrun, receive errors, other line settings and loopback, directed alert fault
injection, stress, reset during transfers and coverage. None of these is needed for the V1 smoke.
