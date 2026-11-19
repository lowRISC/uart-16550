// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class uart16550_env_cfg extends uvm_object;
  virtual clk_rst_if clk_rst_vif;

  tl_agent_cfg    m_tl_agent_cfg;
  uart_agent_cfg  m_uart_agent_cfg;
  alert_agent_cfg m_alert_agent_cfg;

  `uvm_object_utils(uart16550_env_cfg)

  function new(string name = "");
    super.new(name);

    m_tl_agent_cfg = tl_agent_cfg::type_id::create("m_tl_agent_cfg");
    m_tl_agent_cfg.if_mode = Host;
    m_tl_agent_cfg.en_cov  = 0;

    m_uart_agent_cfg = uart_agent_cfg::type_id::create("m_uart_agent_cfg");
    m_uart_agent_cfg.if_mode = Device;  // drives cio_rx_i, monitors cio_tx_o
    m_uart_agent_cfg.en_cov  = 0;

    // Alert receiver, synchronous to the DUT clock. It performs the documented initialization
    // handshake after reset and acks any alert. The default response sequence also starts a ping
    // sequence; push the ping delay (in clock cycles) far beyond the 1 ms whole-test limit so that
    // no ping is sent in V1.
    m_alert_agent_cfg = alert_agent_cfg::type_id::create("m_alert_agent_cfg");
    m_alert_agent_cfg.if_mode        = Device;
    m_alert_agent_cfg.is_async       = 0;
    m_alert_agent_cfg.en_cov         = 0;
    m_alert_agent_cfg.ping_delay_min = 1_000_000;
    m_alert_agent_cfg.ping_delay_max = 1_000_000;
  endfunction
endclass
