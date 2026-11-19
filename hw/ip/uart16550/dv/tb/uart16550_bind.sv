// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// TL-UL protocol assertions on the DUT's device port.
module uart16550_bind;
  bind uart16550 tlul_assert #(
    .EndpointType("Device")
  ) tlul_assert_device (
    .clk_i,
    .rst_ni,
    .h2d (tl_i),
    .d2h (tl_o)
  );
endmodule
