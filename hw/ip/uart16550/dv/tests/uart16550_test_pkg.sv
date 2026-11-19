// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

package uart16550_test_pkg;
  import uvm_pkg::*;
  import dv_utils_pkg::*;
  import tl_agent_pkg::*;
  import uart_agent_pkg::*;
  import uart16550_env_pkg::*;

  `include "uvm_macros.svh"
  `include "dv_macros.svh"

  `include "uart16550_smoke_test.sv"
endpackage
