// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// Top of the UART 16550 V1 smoke bench. Tie-offs and observed outputs follow doc/dv/README.md,
// "Auxiliary outputs and tie-offs".
module tb;
  import uvm_pkg::*;
  import dv_utils_pkg::*;
  import uart16550_env_pkg::*;
  import uart16550_test_pkg::*;

  `include "uvm_macros.svh"
  `include "prim_assert.sv"

  localparam int unsigned NumAlerts = uart_reg_pkg::NumAlerts;

  wire clk, rst_n;
  wire cio_tx, cio_tx_en, lsio_trigger;
  wire intr_tx_watermark, intr_tx_empty, intr_rx_watermark, intr_tx_done;
  wire intr_rx_overflow, intr_rx_frame_err, intr_rx_break_err, intr_rx_timeout;
  wire intr_rx_parity_err;
  top_racl_pkg::racl_error_log_t racl_error;
  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx;
  prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx;

  clk_rst_if clk_rst_if (.clk(clk), .rst_n(rst_n));
  tl_if      tl_if      (.clk(clk), .rst_n(rst_n));
  uart_if    uart_if    ();
  alert_if   alert_if   (.clk(clk), .rst_n(rst_n));  // the single fatal_fault alert

  assign alert_rx[0]       = alert_if.alert_rx;
  assign alert_if.alert_tx = alert_tx[0];
  assign uart_if.uart_tx   = cio_tx;

  uart16550 dut (
    .clk_i                (clk),
    .rst_ni               (rst_n),
    .tl_i                 (tl_if.h2d),
    .tl_o                 (tl_if.d2h),
    .alert_rx_i           (alert_rx),
    .alert_tx_o           (alert_tx),
    // RACL is not implemented by the wrapper; use the default policies.
    .racl_policies_i      (top_racl_pkg::RACL_POLICY_VEC_DEFAULT),
    .racl_error_o         (racl_error),
    .lsio_trigger_o       (lsio_trigger),
    .cio_rx_i             (uart_if.uart_rx),
    .cio_tx_o             (cio_tx),
    .cio_tx_en_o          (cio_tx_en),
    .intr_tx_watermark_o  (intr_tx_watermark),
    .intr_tx_empty_o      (intr_tx_empty),
    .intr_rx_watermark_o  (intr_rx_watermark),
    .intr_tx_done_o       (intr_tx_done),
    .intr_rx_overflow_o   (intr_rx_overflow),
    .intr_rx_frame_err_o  (intr_rx_frame_err),
    .intr_rx_break_err_o  (intr_rx_break_err),
    .intr_rx_timeout_o    (intr_rx_timeout),
    .intr_rx_parity_err_o (intr_rx_parity_err)
  );

  // The UART agent stores decoded TX bits two-state, where X would read as 0. Check the serial
  // output is known out of reset before it is decoded.
  `ASSERT_KNOWN(CioTxKnown_A, cio_tx, clk, !rst_n)

  // The wrapper README says these interrupts are never enabled, so they stay low.
  `ASSERT(IntrTxWatermarkLow_A, intr_tx_watermark === 1'b0, clk, !rst_n)
  `ASSERT(IntrTxDoneLow_A, intr_tx_done === 1'b0, clk, !rst_n)
  `ASSERT(IntrRxTimeoutLow_A, intr_rx_timeout === 1'b0, clk, !rst_n)

  initial begin
    dv_report_server m_report_server;
    m_report_server = new();
    uvm_report_server::set_server(m_report_server);

    clk_rst_if.set_active();
    uvm_config_db#(virtual clk_rst_if)::set(null, "*.env", "clk_rst_vif", clk_rst_if);
    uvm_config_db#(virtual tl_if)::set(null, "*.env.m_tl_agent*", "vif", tl_if);
    uvm_config_db#(virtual uart_if)::set(null, "*.env.m_uart_agent*", "vif", uart_if);
    uvm_config_db#(virtual alert_if)::set(null, "*.env.m_alert_agent*", "vif", alert_if);
    $timeformat(-12, 0, " ps", 12);
    run_test();
  end
endmodule
