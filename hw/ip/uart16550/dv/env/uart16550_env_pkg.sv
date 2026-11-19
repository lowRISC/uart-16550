// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// V1 smoke environment for the UART 16550 wrapper.
//
// A plain uvm_env reusing the OpenTitan tl_agent, uart_agent and alert_agent. There is no RAL
// model and no CIP layer (see doc/dv/README.md, "Planned bench"). Expected values come from the
// test contract in doc/dv/README.md, not from the RTL.
package uart16550_env_pkg;
  import uvm_pkg::*;
  import dv_utils_pkg::*;
  import tl_agent_pkg::*;
  import uart_agent_pkg::*;
  import alert_agent_pkg::*;

  `include "uvm_macros.svh"
  `include "dv_macros.svh"

  // Register byte offsets (doc/registers.md). Offsets 0x0 and 0x4 depend on LCR.DLAB.
  localparam bit [31:0] RBR_THR = 32'h00;  // DLL when DLAB = 1
  localparam bit [31:0] IER     = 32'h04;  // DLM when DLAB = 1
  localparam bit [31:0] IIR_FCR = 32'h08;  // IIR on read, FCR on write
  localparam bit [31:0] LCR     = 32'h0C;
  localparam bit [31:0] MCR     = 32'h10;
  localparam bit [31:0] LSR     = 32'h14;
  localparam bit [31:0] MSR     = 32'h18;
  localparam bit [31:0] SCR     = 32'h1C;
  localparam bit [31:0] DLL     = RBR_THR;
  localparam bit [31:0] DLM     = IER;

  // Alert channel initialization limit after reset (contract "Bounded waits").
  localparam int unsigned AlertInitTimeoutClks = 1000;

  `include "uart16550_env_cfg.sv"
  `include "uart16550_env.sv"
endpackage
