// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// V1 smoke test. Inputs, expected values and limits are those of the test contract in
// doc/dv/README.md ("Smoke test contract"); step numbers below refer to its table.
//
// Negative controls (off by default): +smoke_fault=<name> alters the stimulus only. The expected
// values always come from the constants below.
//   wrong_tx   write 0x54 instead of 0x55 to THR
//   wrong_rx   drive 0xAB instead of 0xAA on cio_rx_i
//   missing_tx skip the THR write of the second byte
//   missing_rx skip driving the second RX byte
//   extra_tx   write one extra, unexpected byte (0x3C) to THR
// Checker QA control for LSR polling (not V2 receive-error coverage). It shows that an error seen
// and cleared by an early poll read still fails the test; without the per-read check it passed.
//   rx_frame_err before the first RX byte, drive a frame with a framing error, then poll LSR while
//                the first valid byte is still arriving
class uart16550_smoke_test extends uvm_test;
  uart16550_env_cfg cfg;
  uart16550_env     env;

  localparam bit [7:0]    TxBytes[4] = '{8'h55, 8'h01, 8'h80, 8'h00};
  localparam bit [7:0]    RxBytes[4] = '{8'hAA, 8'h02, 8'h40, 8'h7E};
  localparam int unsigned NumTx = 4;
  localparam int unsigned NumRx = 4;

  // Bounded waits (contract "Bounded waits").
  localparam int unsigned TlTimeoutClks     = 1000;
  localparam int unsigned TxFramesTimeoutNs = 100_000;
  localparam int unsigned TxEmptyTimeoutNs  = 20_000;
  localparam int unsigned RxReadyTimeoutNs  = 20_000;
  localparam int unsigned QuietWindowNs     = 20_000;  // 2 character times at 1 Mbaud
  localparam int unsigned TestTimeoutNs     = 1_000_000;

  // LSR[7], BI, FE, PE and OE (Section 8.6.3). The smoke expects none of them.
  localparam bit [7:0] LsrErrorBits = 8'h9E;

  // Printed only when every step and end check has run; DVSim requires it to pass.
  localparam string EndMarker = "UART16550_SMOKE_END_CHECKS_DONE";

  string       fault;
  int unsigned rx_bytes_checked;
  bit          end_checks_done;

  `uvm_component_utils(uart16550_smoke_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    void'($value$plusargs("smoke_fault=%s", fault));
    if (!(fault inside {"", "wrong_tx", "wrong_rx", "missing_tx", "missing_rx", "extra_tx",
                        "rx_frame_err"})) begin
      `uvm_fatal(`gfn, $sformatf("Unknown +smoke_fault=%s", fault))
    end
    if (fault != "") `uvm_info(`gfn, $sformatf("Negative control: %s", fault), UVM_NONE)

    cfg = uart16550_env_cfg::type_id::create("cfg");
    uvm_config_db#(uart16550_env_cfg)::set(this, "env", "cfg", cfg);
    env = uart16550_env::type_id::create("env", this);
  endfunction

  task run_phase(uvm_phase phase);
    phase.raise_objection(this);
    fork begin : isolation_fork
      fork
        run_smoke();
        begin
          #(TestTimeoutNs * 1ns);
          `uvm_fatal(`gfn, $sformatf("Whole-test limit of %0d ns reached", TestTimeoutNs))
        end
      join_any
      disable fork;
    end join
    phase.drop_objection(this);
  endtask

  virtual task run_smoke();
    bit [31:0] rdata;
    bit        rx_sent = 1'b1;

    // Step 1: reset, with the serial input idle (high) from reset; SOUT idle high (Table 3).
    `uvm_info(`gfn, "Step 1: reset", UVM_LOW)
    cfg.m_uart_agent_cfg.reset_asserted();
    cfg.m_uart_agent_cfg.vif.reset_uart_rx();
    cfg.clk_rst_vif.set_freq_mhz(50);
    cfg.clk_rst_vif.apply_reset(.reset_width_clks(20));
    cfg.m_uart_agent_cfg.reset_deasserted();
    cfg.clk_rst_vif.wait_clks(1);
    if (cfg.m_uart_agent_cfg.vif.uart_tx !== 1'b1) begin
      `uvm_error(`gfn, $sformatf("cio_tx_o after reset: %b, expected 1",
                                 cfg.m_uart_agent_cfg.vif.uart_tx))
    end

    // Step 2: reset values (datasheet Table 3, with the LCR and MSR exceptions of registers.md).
    `uvm_info(`gfn, "Step 2: reset readback", UVM_LOW)
    csr_rd_check(IER,     32'h00, "IER");
    csr_rd_check(IIR_FCR, 32'h01, "IIR");
    csr_rd_check(LCR,     32'h13, "LCR");
    csr_rd_check(MCR,     32'h00, "MCR");
    csr_rd_check(LSR,     32'h60, "LSR");
    csr_rd_check(MSR,     32'h00, "MSR");

    // Steps 3-7: 8N1 with DLAB set, divisor (enables TX/RX), DLAB clear, FIFOs, scratch.
    `uvm_info(`gfn, "Steps 3-7: configuration", UVM_LOW)
    csr_wr(LCR, 32'h83);
    csr_rd_check(LCR, 32'h83, "LCR (DLAB=1)");
    csr_wr(DLL, 32'h03);
    csr_wr(DLM, 32'h00);
    csr_rd_check(DLL, 32'h03, "DLL");
    csr_rd_check(DLM, 32'h00, "DLM");
    csr_wr(LCR, 32'h03);
    csr_rd_check(LCR, 32'h03, "LCR (DLAB=0)");
    csr_wr(IIR_FCR, 32'h07);
    csr_wr(SCR, 32'hA5);
    csr_rd_check(SCR, 32'hA5, "SCR");

    // Step 8: TX bytes, checked by the env against the serial output, in order.
    `uvm_info(`gfn, "Step 8: TX", UVM_LOW)
    for (int i = 0; i < NumTx; i++) begin
      bit [7:0] data = TxBytes[i];
      env.exp_tx_q.push_back(TxBytes[i]);
      if (fault == "wrong_tx" && i == 0) data = 8'h54;
      if (fault == "missing_tx" && i == 1) continue;
      csr_wr(RBR_THR, data);
    end
    if (fault == "extra_tx") csr_wr(RBR_THR, 8'h3C);
    wait_for_tx_frames();

    // Step 9: THRE and TEMT set once the last frame has gone (Section 8.6.3).
    `uvm_info(`gfn, "Step 9: wait for THRE/TEMT", UVM_LOW)
    poll_lsr(8'h60, TxEmptyTimeoutNs, rdata);
    check_value(rdata, 32'h60, "LSR after TX");

    // Steps 10-11: one RX byte at a time; DR, no errors, then RBR (Section 8.6.3).
    `uvm_info(`gfn, "Steps 10-11: RX", UVM_LOW)
    for (int i = 0; i < NumRx; i++) begin
      bit [7:0] data = RxBytes[i];
      if (fault == "wrong_rx" && i == 0) data = 8'hAB;
      if (fault == "rx_frame_err" && i == 0) begin
        // The errored frame is not pushed into the RCVR FIFO (README.md), so FE and LSR[7] are set
        // while DR is 0. Early polls see the error and the read clears it (Section 8.6.3) before
        // the valid byte sets DR. No error is expected, so the test must fail.
        send_rx_frame_error(8'h5A);
        rx_sent = 1'b0;
        fork
          begin
            send_rx_byte(data);
            rx_sent = 1'b1;
          end
        join_none
      end else if (!(fault == "missing_rx" && i == 1)) begin
        send_rx_byte(data);
      end
      poll_lsr(8'h01, RxReadyTimeoutNs, rdata);
      csr_rd_check(RBR_THR, RxBytes[i], $sformatf("RBR byte %0d", i));
      rx_bytes_checked++;
      wait (rx_sent);
    end

    // Step 12 and end checks: quiet window, final LSR, exact counts, empty queue.
    `uvm_info(`gfn, "Step 12: quiet window and end checks", UVM_LOW)
    begin
      int unsigned frames_before = env.tx_frames_seen;
      #(QuietWindowNs * 1ns);
      if (env.tx_frames_seen != frames_before) begin
        `uvm_error(`gfn, "TX frame seen during the quiet window")
      end
    end
    csr_rd_check(LSR, 32'h60, "LSR at end");
    if (env.tx_frames_seen != NumTx) begin
      `uvm_error(`gfn, $sformatf("TX frames: %0d, expected %0d", env.tx_frames_seen, NumTx))
    end
    if (rx_bytes_checked != NumRx) begin
      `uvm_error(`gfn, $sformatf("RX bytes checked: %0d, expected %0d", rx_bytes_checked, NumRx))
    end
    if (env.exp_tx_q.size() != 0) begin
      `uvm_error(`gfn, $sformatf("Expected TX bytes left: %p", env.exp_tx_q))
    end
    end_checks_done = 1;
  endtask

  // Wait until NumTx frames have been decoded (contract: 100 us after the last THR write).
  virtual task wait_for_tx_frames();
    fork begin : isolation_fork
      fork
        wait (env.tx_frames_seen >= NumTx);
        begin
          #(TxFramesTimeoutNs * 1ns);
          `uvm_fatal(`gfn, $sformatf("Only %0d of %0d TX frames within %0d ns",
                                     env.tx_frames_seen, NumTx, TxFramesTimeoutNs))
        end
      join_any
      disable fork;
    end join
  endtask

  // Drive one 8N1 frame on cio_rx_i; returns after the stop bit.
  virtual task send_rx_byte(bit [7:0] data);
    uart_seq seq = uart_seq::type_id::create("seq");
    seq.set_sequencer(env.m_uart_agent.sequencer);  // the constraints use p_sequencer
    `DV_CHECK_RANDOMIZE_WITH_FATAL(seq, data == local::data; parity_err == 0; frame_err == 0;)
    seq.start(env.m_uart_agent.sequencer);
  endtask

  // rx_frame_err control: one 8N1 frame with a 0 stop bit (framing error), driven directly on
  // cio_rx_i at the bench bit time, then 2 idle bit times. The agent's RX monitor is paused because
  // it would report the deliberate stop bit; the RX driver is idle meanwhile.
  virtual task send_rx_frame_error(bit [7:0] data);
    bit [9:0] frame = {1'b0, data, 1'b0};  // stop, data, start; sent from bit 0 (LSB first)
    cfg.m_uart_agent_cfg.en_rx_monitor = 1'b0;
    for (int b = 0; b < 10; b++) begin
      cfg.m_uart_agent_cfg.vif.uart_rx = frame[b];
      #(cfg.m_uart_agent_cfg.vif.uart_clk_period);
    end
    cfg.m_uart_agent_cfg.vif.uart_rx = 1'b1;
    #(2 * cfg.m_uart_agent_cfg.vif.uart_clk_period);
    cfg.m_uart_agent_cfg.en_rx_monitor = 1'b1;
  endtask

  // One TL-UL access: PutFullData or Get, a_size 2, a_mask 0xF, word aligned (contract "Bus").
  // The limit starts when the request is issued and includes waiting for a_ready.
  virtual task csr_access(bit write, bit [31:0] addr, bit [31:0] wdata, output bit [31:0] rdata);
    tl_host_single_seq#() seq = tl_host_single_seq#()::type_id::create("seq");
    seq.min_req_delay          = 0;
    seq.max_req_delay          = 0;
    seq.control_addr_alignment = 1;
    seq.control_rand_size      = 1;
    seq.control_rand_opcode    = 1;
    `DV_CHECK_RANDOMIZE_WITH_FATAL(seq,
        write  == local::write;
        addr   == local::addr;
        data   == local::wdata;
        mask   == 4'hF;
        size   == 2;
        opcode == (local::write ? tlul_pkg::PutFullData : tlul_pkg::Get);)
    fork begin : isolation_fork
      fork
        seq.start(env.m_tl_agent.sequencer);
        begin
          cfg.clk_rst_vif.wait_clks(TlTimeoutClks);
          `uvm_fatal(`gfn, $sformatf("No TL-UL response within %0d clocks (addr 0x%02x)",
                                     TlTimeoutClks, addr))
        end
      join_any
      disable fork;
    end join
    if (seq.rsp.d_error !== 1'b0) begin
      `uvm_error(`gfn, $sformatf("d_error on %s of addr 0x%02x", write ? "write" : "read", addr))
    end
    rdata = seq.rsp.d_data;
  endtask

  virtual task csr_wr(bit [31:0] addr, bit [31:0] data);
    bit [31:0] unused;
    csr_access(1'b1, addr, data, unused);
  endtask

  // Reads compare all 32 bits; the upper 3 bytes read 0 (registers.md).
  virtual task csr_rd_check(bit [31:0] addr, bit [31:0] exp, string name);
    bit [31:0] rdata;
    csr_access(1'b0, addr, '0, rdata);
    check_value(rdata, exp, name);
  endtask

  function void check_value(bit [31:0] got, bit [31:0] exp, string name);
    if (got !== exp) begin
      `uvm_error(`gfn, $sformatf("%s: got 0x%08x, expected 0x%08x", name, got, exp))
    end else begin
      `uvm_info(`gfn, $sformatf("%s = 0x%08x as expected", name, got), UVM_MEDIUM)
    end
  endfunction

  // Read LSR until all bits in mask are set, within timeout_ns. Every read is checked before the
  // next one, because an LSR read clears OE, PE, FE, BI and LSR[7] (Section 8.6.3): a later read
  // cannot show an earlier error. DR, THRE and TEMT may change while polling.
  virtual task poll_lsr(bit [7:0] mask, int unsigned timeout_ns, output bit [31:0] lsr);
    fork begin : isolation_fork
      fork
        do begin
          csr_access(1'b0, LSR, '0, lsr);
          `uvm_info(`gfn, $sformatf("LSR poll read 0x%08x", lsr), UVM_MEDIUM)
          check_lsr_poll(lsr);
        end while ((lsr[7:0] & mask) != mask);
        begin
          #(timeout_ns * 1ns);
          `uvm_fatal(`gfn, $sformatf("LSR bits 0x%02x not set within %0d ns (last LSR 0x%02x)",
                                     mask, timeout_ns, lsr))
        end
      join_any
      disable fork;
    end join
  endtask

  // Upper 3 bytes read 0 (registers.md) and no error bit is set.
  function void check_lsr_poll(bit [31:0] lsr);
    if (lsr[31:8] != 0) begin
      `uvm_error(`gfn, $sformatf("LSR poll read 0x%08x: upper 3 bytes are not 0", lsr))
    end
    if ((lsr[7:0] & LsrErrorBits) != 0) begin
      `uvm_error(`gfn, $sformatf("LSR poll read 0x%08x: unexpected error bits 0x%02x %s",
                                 lsr, lsr[7:0] & LsrErrorBits, "(OE/PE/FE/BI/LSR[7])"))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!end_checks_done) begin
      `uvm_error(`gfn, "The test did not reach its end checks")
    end else begin
      $display(EndMarker);
    end
  endfunction
endclass
