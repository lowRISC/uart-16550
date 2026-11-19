# UART 16550 DV

This page defines the first (V1) DV target for the UART 16550 wrapper: one smoke test with a
single selected configuration.
It was written before the bench so that the checks were agreed first.
The testpoints are in [`data/uart16550_testplan.hjson`](../../data/uart16550_testplan.hjson).

**Status:** initial bench. The bench and the `uart16550_smoke` test are in [`dv/`](../../dv).
The results below cover only this V1 smoke at commit `b424bde`. They are not a V1 sign-off: the V2
and V3 testpoints are not implemented, coverage is not collected, and the bench has not run in a
scheduled Mocha nightly.

## Results at `b424bde`

Xcelium 24.03 through DVSim. Each command below follows
`dvsim hw/ip/uart16550/dv/uart16550_sim_cfg.hjson -t xcelium`; negative controls add
`--run-opts +smoke_fault=<name>`. Expected values come from the contract below, not from the RTL.

| Run | Options | DVSim exit | Result |
|-|-|-|-|
| Clean smoke | `-i uart16550_smoke --fixed-seed 1` | 0 | Pass |
| Ten seeds | `-i nightly --seeds 1 2 3 4 5 6 7 8 9 10 --reseed 10` | 0 | 10 of 10 pass |
| `wrong_tx` | `-i uart16550_smoke --fixed-seed 1` | 1 | TX frame 1 is 0x54, expected 0x55 |
| `wrong_rx` | as above | 1 | RBR byte 0 is 0xAB, expected 0xAA |
| `missing_tx` | as above | 1 | Later frames mismatch in order, then only 3 of 4 frames within 100 us |
| `missing_rx` | as above | 1 | DR not set within 20 us. The resulting abort also leaves a TL-UL request outstanding, so `tlul_assert` reports it at the end; that is a consequence, not the primary failure. |
| `extra_tx` | as above | 1 | Unexpected fifth frame 0x3C, then 5 frames counted instead of 4 |
| `rx_frame_err` | as above | 1 | One error only: a poll read of 0xE8 has FE and LSR[7] set. RBR byte 0 (0xAA) and the end checks still pass. |
| Clean smoke after the controls | `-i smoke --fixed-seed 1` | 0 | Pass |

At the same commit, the existing lint and `pre_dv` flows pass, `reuse lint` passes, and the commit
metadata check passes for the branch. The tool-failure control in
[Negative controls](#negative-controls) was not run.

`rx_frame_err` is a check on the bench itself. An LSR read clears FE and LSR[7]
(datasheet Section 8.6.3), so an error seen only by an early poll read must fail the test. At
`15b14b1`, before every poll read was checked, the same control passed wrongly (DVSim exit 0).

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
| 9 | Poll LSR until THRE and TEMT are set; check every poll read (below) | 0x60 | Section 8.6.3 |
| 10 | Drive 0xAA, 0x02, 0x40, 0x7E on `cio_rx_i` | - | Bench choice |
| 11 | For each byte: poll LSR until DR = 1, checking every poll read (below), then read RBR | RBR = driven byte, same order | Section 8.6.3 |
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
4. An RBR read returns the wrong byte, or any LSR poll read (steps 9 and 11) has OE, PE, FE, BI or
   LSR[7] set, or non-zero upper 3 bytes. Every poll read is checked before the next one, because
   an LSR read clears these error bits (Section 8.6.3) and a later read could hide them. DR, THRE
   and TEMT may change while polling.
5. Expected counts are exactly 4 TX frames and 4 RX bytes. TX frames are compared in order
   against an expected queue, which must be empty at the end. RX bytes are checked one at a time
   against a fixed list (there is no RX queue): each RBR read is compared and counted, and the
   count must be 4. A missing transfer fails this check even if no comparison ever ran.
6. `intr_tx_watermark_o`, `intr_tx_done_o` or `intr_rx_timeout_o` goes high
   (the wrapper README says they are never enabled).
7. The alert channel does not finish its initialization handshake in time, an alert pair is
   wrongly encoded after initialization, or an alert is sent
   (see [Alert channel](#alert-channel)).
8. Any wait passes its limit (below).

### Bounded waits

These are starting values. Change them only with a recorded reason.

| Wait | Limit |
|-|-|
| One TL-UL access (from the request first being presented, `a_valid` = 1, to the response; this includes waiting for `a_ready`) | 1000 clock cycles |
| All 4 TX frames after the last THR write | 100 us (about 2.5x the 40 us needed) |
| LSR.THRE/TEMT after the last TX frame | 20 us |
| LSR.DR for each RX byte after its stop bit | 20 us |
| Alert channel initialization after `rst_ni` is released | 1000 clock cycles (bench choice) |
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

Each control except the tool failure is a test-only `+smoke_fault=<name>` option.

| Control | Fault | Expected result |
|-|-|-|
| Wrong TX byte | Write 0x54 instead of 0x55 to THR, expectation unchanged | TX mismatch, test fails |
| Wrong RX byte | Drive 0xAB instead of 0xAA, expectation unchanged | RBR mismatch, test fails |
| Missing TX transfer | Skip one THR write, expected count stays 4 | TX mismatch (frames compare in order), then TX timeout, test fails |
| Missing RX transfer | Skip one RX frame, expected count stays 4 | LSR.DR wait times out, test fails |
| Extra TX byte | Write one extra THR byte that is not expected | Unexpected-data error, test fails |
| LSR error hidden by polling (`rx_frame_err`, checker QA, not V2 error coverage) | Before the first RX byte, drive a frame with a 0 stop bit (framing error; not pushed into the RCVR FIFO, README), then poll LSR while the first valid byte is still arriving | Early polls see FE and LSR[7] with DR = 0, and the read clears them (Section 8.6.3). The LSR poll check reports FE and LSR[7] on the early read, test fails. At `15b14b1`, before every poll read was checked, this control passed wrongly (poll read 0xE8, then clean reads, DVSim exit 0). |
| Tool failure | Remove a source file from the build | Build failure, reported as a tool failure |

## Auxiliary outputs and tie-offs

| Port | Smoke bench | Check in V1 |
|-|-|-|
| `alert_rx_i` / `alert_tx_o` | Driven by an OpenTitan `alert_agent` (`lowrisc:dv:alert_agent`) in device (receiver) mode. It performs the documented post-reset initialization handshake, then keeps `alert_rx_i` correctly encoded and acks any alert. No pings are sent in V1. | See [Alert channel](#alert-channel) |
| `racl_policies_i` / `racl_error_o` | `RACL_POLICY_VEC_DEFAULT` | Observed only (RACL is not implemented) |
| `lsio_trigger_o` | Observed | None |
| `cio_tx_en_o` | Observed | None (not a 16550 signal) |
| `intr_tx_watermark_o`, `intr_tx_done_o`, `intr_rx_timeout_o` | Observed | Stay low |
| Other `intr_*_o` | Observed | None in V1 (see the `interrupts` testpoint) |

## Alert channel

Expected alert behaviour comes from the OpenTitan alert handler specification at `012fb0fe`,
`hw/top_earlgrey/ip_autogen/alert_handler/doc/theory_of_operation.md` (the `alert_agent` README
links to it): "Differential Alert Signaling" and "Monitoring of Signal Integrity Issues" for
normal operation, and the low-power group initialization text (in-band reset) for initialization.

The pairs are not always correctly encoded.
During initialization the receiver deliberately places a signal-integrity error on
`ack_p`/`ack_n` (and `ping_p`/`ping_n`); the sender acknowledges with a signal-integrity error on
`alert_p`/`alert_n` (both equal), and returns to idle when the receiver's error is removed.
The smoke therefore checks in two phases:

1. **Initialization**, after `rst_ni` is released: within 1000 clock cycles, `alert_p == alert_n`
   is seen (the sender's acknowledge), followed by the idle state with all three pairs correctly
   encoded and `alert_p` = 0. Invalid pairs are expected in this phase and are not errors.
   Not finishing in time is an error.
2. **Normal operation**, from initialization done to the end of the test, sampled every clock:
   `alert_p != alert_n`, `ack_p != ack_n` and `ping_p != ping_n` (correct differential encoding),
   and `alert_p` = 0 (no native alert, since the smoke expects none). Any item that the agent's
   monitor publishes (alert or integrity failure) is also an error.

The datasheet and wrapper documents do not describe the alert. The wrapped OpenTitan UART has
one alert, `fatal_fault`, raised on a fatal TL-UL bus integrity fault
(`hw/vendor/lowrisc_ip/ip/uart/doc/interfaces.md`); the smoke sends only well-formed accesses, and
the wrapper README says request integrity errors are ignored, so no alert is expected.

## Bench

The bench reuses OpenTitan DV components without the full CIP layer:

- `dv_lib` base classes, `tl_agent` (host), `uart_agent` (supports 1 Mbaud) and
  `alert_agent` (`lowrisc:dv:alert_agent`, `hw/dv/sv/alert_agent` at OpenTitan `012fb0fe`) as the
  alert receiver.
  Register accesses use small helper tasks on raw offsets. A complete RAL model is not required.
- Not `cip_lib` for V1. At OpenTitan `012fb0fe`, `cip_base_env_cfg` stops with a fatal error when
  the register block has no `alert_test` register, and the 16550 map has none.
  Its generic register checks would also run before the custom data checks.
  Alert protocol checking is kept by instantiating `alert_agent` directly.
- What the pinned `alert_agent` does and does not check (read from its sources):
  - `alert_if` asserts that `ping_p ^ ping_n`, `ack_p ^ ack_n` and `alert_p ^ alert_n` are never
    unknown out of reset.
  - In device mode the driver performs the post-reset init handshake on `alert_rx_i` and acks any
    alert. The monitor waits for that handshake, then reports signal-integrity failures
    (`alert_p == alert_n`, item type `AlertIntFail`) and alerts (`AlertSigTrans`) on its
    `m_alert_port`, and keeps the run phase open while `alert_p` is high.
  - The monitor does not raise `UVM_ERROR` itself (in OpenTitan the CIP scoreboard does).
    The V1 environment therefore subscribes to `m_alert_port` and reports `UVM_ERROR` for every
    item, since no alert is expected.
  - With its default response sequence the agent also starts a ping sequence. V1 sets the ping
    delay far beyond the whole-test limit, so no ping is sent.
- Directed alert fault injection and ping tests are later work (V2 `alerts` testpoint).
- The environment is a plain `uvm_env`/`uvm_test`; `dv_base_env` and its register model are not
  used. `tlul_assert` is bound to the DUT's TL-UL port (`tb/uart16550_bind.sv`).
- The OpenTitan DV libraries and DVSim configuration are vendored from OpenTitan `012fb0fe` (the
  existing lock) into `hw/vendor/lowrisc_ip/dv`, with no RTL change. If PR #14 moves the vendor
  directory, `dv_root` in `hw/dv/tools/dvsim/common_sim_cfg.hjson` moves with it.

| File | Content |
|-|-|
| `dv/uart16550_sim.core` | FuseSoC core `lowrisc:dv:uart16550_sim` |
| `dv/uart16550_sim_cfg.hjson` | DVSim configuration, tests and regressions |
| `dv/tb/tb.sv` | DUT, interfaces, tie-offs, interrupt assertions |
| `dv/env/` | Agents, TX frame checker, alert channel checker |
| `dv/tests/uart16550_smoke_test.sv` | Smoke sequence, register checks, counts, waits, negative controls |
| `hw/dv/tools/dvsim/common_sim_cfg.hjson` (from the repository root) | Project DVSim settings |

## Running

The existing flows are unchanged:

```sh
fusesoc --cores-root=. run --target=lint lowrisc:ip:uart16550
fusesoc --cores-root=. run --target=sim lowrisc:dv:uart16550_tb   # pre_dv, prints "Test passed!"
```

Both need Verilator 5.054 or newer (from the project dev shell).

The smoke test runs with DVSim and Xcelium 24.03, with `xrun`, `dvsim` and `fusesoc` on `PATH`:

```sh
dvsim hw/ip/uart16550/dv/uart16550_sim_cfg.hjson -t xcelium -i uart16550_smoke --fixed-seed 1 \
  --reseed 1 --scratch-root <dir outside the repo>
dvsim hw/ip/uart16550/dv/uart16550_sim_cfg.hjson -t xcelium -i smoke     # 1 random seed
dvsim hw/ip/uart16550/dv/uart16550_sim_cfg.hjson -t xcelium -i nightly   # 10 random seeds
```

A run passes only if the log contains both `TEST PASSED CHECKS` (no UVM warning, error or fatal)
and `UART16550_SMOKE_END_CHECKS_DONE` (the test reached its end checks), and no failure pattern.
The UART agent glitches each driven RX bit for up to 10% of the bit time, so seeds change timing.

Negative controls (see [Negative controls](#negative-controls)) add a run option:

```sh
dvsim ... -i uart16550_smoke --fixed-seed 1 --reseed 1 --run-opts +smoke_fault=wrong_tx
```

with `wrong_tx`, `wrong_rx`, `missing_tx`, `missing_rx`, `extra_tx` or `rx_frame_err`.

For debug, add `--waves shm` and `--verbosity m` (step-by-step register values).

## Later work

V2 and V3 testpoints in the testplan list later work: full CSR checks, TL-UL errors, interrupts,
FIFO limits and overrun, receive errors, other line settings and loopback, directed alert fault
injection, stress, reset during transfers and coverage. None of these is needed for the V1 smoke.
