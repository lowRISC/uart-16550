// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Agents plus the two passive checkers of the smoke: the TX frame checker and the alert channel
// checker. The test owns stimulus, register checks and counts.
class uart16550_env extends uvm_env;
  uart16550_env_cfg cfg;

  tl_agent    m_tl_agent;
  uart_agent  m_uart_agent;
  alert_agent m_alert_agent;

  // Frames decoded from cio_tx_o by the uart_agent monitor.
  uvm_tlm_analysis_fifo #(uart_item)      tx_fifo;
  // Items published by the alert_agent monitor (alerts and integrity failures).
  uvm_tlm_analysis_fifo #(alert_seq_item) alert_fifo;

  // TX checker state. The test pushes each expected byte before writing THR.
  bit [7:0]    exp_tx_q[$];
  int unsigned tx_frames_seen;

  bit alert_init_done;

  `uvm_component_utils(uart16550_env)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(uart16550_env_cfg)::get(this, "", "cfg", cfg)) begin
      `uvm_fatal(`gfn, "failed to get cfg from uvm_config_db")
    end
    if (!uvm_config_db#(virtual clk_rst_if)::get(this, "", "clk_rst_vif", cfg.clk_rst_vif)) begin
      `uvm_fatal(`gfn, "failed to get clk_rst_vif from uvm_config_db")
    end

    m_tl_agent = tl_agent::type_id::create("m_tl_agent", this);
    uvm_config_db#(tl_agent_cfg)::set(this, "m_tl_agent*", "cfg", cfg.m_tl_agent_cfg);
    m_uart_agent = uart_agent::type_id::create("m_uart_agent", this);
    uvm_config_db#(uart_agent_cfg)::set(this, "m_uart_agent*", "cfg", cfg.m_uart_agent_cfg);
    m_alert_agent = alert_agent::type_id::create("m_alert_agent", this);
    uvm_config_db#(alert_agent_cfg)::set(this, "m_alert_agent*", "cfg", cfg.m_alert_agent_cfg);

    tx_fifo    = new("tx_fifo", this);
    alert_fifo = new("alert_fifo", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    m_uart_agent.monitor.tx_analysis_port.connect(tx_fifo.analysis_export);
    m_alert_agent.m_alert_port.connect(alert_fifo.analysis_export);
    // The agent vif is known once the agent is built. 1 Mbaud: registers.md DLL row.
    cfg.m_uart_agent_cfg.set_baud_rate(BaudRate1Mbps);
  endfunction

  task run_phase(uvm_phase phase);
    fork
      check_tx_frames();
      check_alert_items();
      check_alert_channel();
    join_none
  endtask

  // Compare each decoded TX frame with the next expected byte, in order (contract checks 2, 3).
  // Start and stop bit levels follow datasheet Section 8.6.2 / Table 1: start 0, stop 1.
  virtual task check_tx_frames();
    uart_item item;
    forever begin
      tx_fifo.get(item);
      tx_frames_seen++;
      if (item.start_bit !== 1'b0 || item.stop_bit !== 1'b1) begin
        `uvm_error(`gfn, $sformatf("TX frame %0d has bad framing: start %b stop %b",
                                   tx_frames_seen, item.start_bit, item.stop_bit))
      end
      if (exp_tx_q.size() == 0) begin
        `uvm_error(`gfn, $sformatf("Unexpected TX frame %0d: 0x%02x, no byte expected",
                                   tx_frames_seen, item.data))
      end else begin
        bit [7:0] exp = exp_tx_q.pop_front();
        if (item.data !== exp) begin
          `uvm_error(`gfn, $sformatf("TX frame %0d mismatch: got 0x%02x, expected 0x%02x",
                                     tx_frames_seen, item.data, exp))
        end else begin
          `uvm_info(`gfn, $sformatf("TX frame %0d matched: 0x%02x", tx_frames_seen, exp), UVM_LOW)
        end
      end
    end
  endtask

  // No alert is expected in the smoke, so every item from the alert monitor is an error.
  virtual task check_alert_items();
    alert_seq_item item;
    forever begin
      alert_fifo.get(item);
      `uvm_error(`gfn, $sformatf("Unexpected alert monitor item: %s", item.m_trans_type.name()))
    end
  endtask

  // True when the differential pair is a known, correctly encoded value.
  function bit pair_ok(logic p, logic n);
    return (p ^ n) === 1'b1;
  endfunction

  // Alert channel checks (doc/dv/README.md "Alert channel"; OpenTitan alert_handler theory of
  // operation, "Differential Alert Signaling" and the in-band initialization text).
  // Sampled on the falling clock edge, away from the rising-edge updates of both sides.
  virtual task check_alert_channel();
    virtual alert_if vif = cfg.m_alert_agent_cfg.vif;

    wait (vif.rst_n === 1'b0);
    wait (vif.rst_n === 1'b1);

    // Phase 1: initialization. The receiver deliberately drives invalid ack/ping pairs and the
    // sender acknowledges with alert_p == alert_n. Invalid pairs are allowed here, but the
    // handshake must finish (back to idle, all pairs valid, alert_p = 0) within the limit.
    fork begin : isolation_fork
      fork
        begin
          do @(negedge vif.clk);
          while (vif.alert_tx.alert_p !== vif.alert_tx.alert_n);
          `uvm_info(`gfn, "Alert init: sender acknowledge (alert_p == alert_n) seen", UVM_MEDIUM)
          do @(negedge vif.clk);
          while (!(pair_ok(vif.alert_tx.alert_p, vif.alert_tx.alert_n) &&
                   pair_ok(vif.alert_rx.ack_p, vif.alert_rx.ack_n) &&
                   pair_ok(vif.alert_rx.ping_p, vif.alert_rx.ping_n) &&
                   vif.alert_tx.alert_p === 1'b0));
        end
        begin
          repeat (AlertInitTimeoutClks) @(negedge vif.clk);
          `uvm_fatal(`gfn, $sformatf("Alert channel initialization not done %0d clocks after reset",
                                     AlertInitTimeoutClks))
        end
      join_any
      disable fork;
    end join
    alert_init_done = 1;
    `uvm_info(`gfn, "Alert channel initialization done", UVM_LOW)

    // Phase 2: normal operation. All pairs correctly encoded and no native alert.
    forever begin
      @(negedge vif.clk);
      if (!pair_ok(vif.alert_tx.alert_p, vif.alert_tx.alert_n) ||
          !pair_ok(vif.alert_rx.ack_p, vif.alert_rx.ack_n) ||
          !pair_ok(vif.alert_rx.ping_p, vif.alert_rx.ping_n)) begin
        `uvm_error(`gfn, $sformatf("Alert pair wrongly encoded: alert %b%b ack %b%b ping %b%b",
                                   vif.alert_tx.alert_p, vif.alert_tx.alert_n,
                                   vif.alert_rx.ack_p, vif.alert_rx.ack_n,
                                   vif.alert_rx.ping_p, vif.alert_rx.ping_n))
      end else if (vif.alert_tx.alert_p === 1'b1) begin
        `uvm_error(`gfn, "Alert sent (alert_p = 1), but no alert is expected")
      end
    end
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (exp_tx_q.size() != 0) begin
      `uvm_error(`gfn, $sformatf("%0d expected TX bytes never seen: %p", exp_tx_q.size(), exp_tx_q))
    end
    if (tx_fifo.used() != 0) begin
      `uvm_error(`gfn, $sformatf("%0d TX frames not checked", tx_fifo.used()))
    end
    if (!alert_init_done) `uvm_error(`gfn, "Alert channel initialization never completed")
  endfunction
endclass
