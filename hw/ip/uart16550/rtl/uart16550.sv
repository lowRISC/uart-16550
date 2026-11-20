// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module uart16550
    import uart_reg_pkg::*;
#(
  parameter logic [NumAlerts-1:0]           AlertAsyncOn              = {NumAlerts{1'b1}},
  // Number of cycles a differential skew is tolerated on the alert signal
  parameter int unsigned                    AlertSkewCycles           = 1,
  parameter bit                             EnableRacl                = 1'b0,
  parameter bit                             RaclErrorRsp              = EnableRacl,
  parameter top_racl_pkg::racl_policy_sel_t RaclPolicySelVec[NumRegs] = '{NumRegs{0}}
) (
  input           clk_i,
  input           rst_ni,

  // Bus Interface
  input  tlul_pkg::tl_h2d_t tl_i,
  output tlul_pkg::tl_d2h_t tl_o,

  // Alerts
  input  prim_alert_pkg::alert_rx_t [NumAlerts-1:0] alert_rx_i,
  output prim_alert_pkg::alert_tx_t [NumAlerts-1:0] alert_tx_o,

  // RACL interface
  input  top_racl_pkg::racl_policy_vec_t racl_policies_i,
  output top_racl_pkg::racl_error_log_t  racl_error_o,

  output logic    lsio_trigger_o,

  // Generic IO
  input           cio_rx_i,
  output logic    cio_tx_o,
  output logic    cio_tx_en_o,

  // Interrupts
  output logic    intr_tx_watermark_o,
  output logic    intr_tx_empty_o,
  output logic    intr_rx_watermark_o,
  output logic    intr_tx_done_o,
  output logic    intr_rx_overflow_o,
  output logic    intr_rx_frame_err_o,
  output logic    intr_rx_break_err_o,
  output logic    intr_rx_timeout_o,
  output logic    intr_rx_parity_err_o
);

  // TileLink signals.
  // Initialisation requests to the MUX
  tlul_pkg::tl_h2d_t tl_init_h2d;
  tlul_pkg::tl_d2h_t tl_init_d2h;

  // Translated requests to the MUX
  tlul_pkg::tl_h2d_t tl_translated_h2d;
  tlul_pkg::tl_d2h_t tl_translated_d2h;

  // Multiplexed requests to the OpenTitan UART core
  tlul_pkg::tl_h2d_t tl_mux_h2d;
  tlul_pkg::tl_d2h_t tl_mux_d2h;

  // Initialisation select signal
  // When high, the external TL-UL interface is blocked and the
  // initialisation block has access to the OpenTitan UART core
  logic init_sel;

  // UART initialisation block
  // Sends requests on initialisation to better match 16550 default behaviour
  uart16550_init u_uart_init(
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .init_sel_o (init_sel),
    .uart_tl_o  (tl_init_h2d),
    .uart_tl_i  (tl_init_d2h)
  );

  // Register translation block
  uart16550_translate u_reg_translate(
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .host_tl_i (tl_i),
    .host_tl_o (tl_o),
    .uart_tl_o (tl_translated_h2d),
    .uart_tl_i (tl_translated_d2h)
  );

  // TL-UL MUX
  // Allows either u_uart_init or u_reg_translate to have access to the
  // OpenTitan UART core depending on the value of init_sel
  always_comb begin
    if (init_sel) begin
      // Pass through initialisation requests
      tl_mux_h2d  = tl_init_h2d;
      tl_init_d2h = tl_mux_d2h;

      // Block translated requests
      tl_translated_d2h         = tlul_pkg::TL_D2H_DEFAULT;
      tl_translated_d2h.a_ready = 1'b0;
    end else begin
      // Pass through translated requests
      tl_mux_h2d        = tl_translated_h2d;
      tl_translated_d2h = tl_mux_d2h;

      // Block initialisation requests
      tl_init_d2h         = tlul_pkg::TL_D2H_DEFAULT;
      tl_init_d2h.a_ready = 1'b0;
    end
  end

  // OpenTitan UART core instance
  uart #(
    .AlertAsyncOn     ( AlertAsyncOn     ),
    .AlertSkewCycles  ( AlertSkewCycles  ),
    .EnableRacl       ( EnableRacl       ),
    .RaclErrorRsp     ( RaclErrorRsp     ),
    .RaclPolicySelVec ( RaclPolicySelVec )
  ) u_uart_core(
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .tl_i                 (tl_mux_h2d),
    .tl_o                 (tl_mux_d2h),
    .alert_rx_i           (alert_rx_i),
    .alert_tx_o           (alert_tx_o),
    .racl_policies_i      (racl_policies_i),
    .racl_error_o         (racl_error_o),
    .lsio_trigger_o       (lsio_trigger_o),
    .cio_rx_i             (cio_rx_i),
    .cio_tx_o             (cio_tx_o),
    .cio_tx_en_o          (cio_tx_en_o),
    .intr_tx_watermark_o  (intr_tx_watermark_o),
    .intr_tx_empty_o      (intr_tx_empty_o),
    .intr_rx_watermark_o  (intr_rx_watermark_o),
    .intr_tx_done_o       (intr_tx_done_o),
    .intr_rx_overflow_o   (intr_rx_overflow_o),
    .intr_rx_frame_err_o  (intr_rx_frame_err_o),
    .intr_rx_break_err_o  (intr_rx_break_err_o),
    .intr_rx_timeout_o    (intr_rx_timeout_o),
    .intr_rx_parity_err_o (intr_rx_parity_err_o)
  );

endmodule
