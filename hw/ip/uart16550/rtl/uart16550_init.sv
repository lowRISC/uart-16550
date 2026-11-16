// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module uart16550_init(
  // Clock and reset
  input  logic clk_i,
  input  logic rst_ni,

  // UART initialisation select
  output logic init_sel_o,

  // TL-UL interface to the UART core
  output tlul_pkg::tl_h2d_t uart_tl_o,
  input  tlul_pkg::tl_d2h_t uart_tl_i
);

  // Unused signals
  logic unused_sig;
  assign unused_sig = |{uart_tl_i};

  ///////////////////
  // Control logic //
  ///////////////////

  // TODO state enc
  localparam int StateWidth = 10;
  typedef enum logic [StateWidth-1:0] {
    ResetSt       = 10'b1110001010,
    InitReqSt     = 10'b1001000001,
    InitReqWaitSt = 10'b0010101101,
    InitDoneSt    = 10'b0111110000
  } state_e;

  state_e state_d, state_q;

  // Select output registers
  logic init_sel_d;
  logic init_sel_q;

  assign init_sel_o = init_sel_q;

  always_comb begin : p_fsm
    // Default
    state_d             = state_q;
    uart_tl_o           = tlul_pkg::TL_H2D_DEFAULT;
    uart_tl_o.a_size    = 2;
    uart_tl_o.a_mask    = '1;

    init_sel_d = init_sel_q;

    unique case (state_q)
      // Wait for reset release
      ResetSt: begin
        state_d = InitReqSt;
      end
      // Send initialisation request to UART
      InitReqSt: begin
        uart_tl_o.a_valid = 1;
        uart_tl_o.a_opcode = tlul_pkg::PutFullData;
        uart_tl_o.a_address = 'h30; // TIMEOUT_CTRL reg
        uart_tl_o.a_data = '0;
        // Parity is disabled by default
        // 4 character times is 4*(1 + 8 + 1) = 40 bit times
        uart_tl_o.a_data[23:0] = 24'd40;
        uart_tl_o.a_data[31] = 1'b1;  // EN = 1

        if (uart_tl_i.a_ready) begin
          state_d = InitReqWaitSt;
        end
      end
      // Wait for response from UART
      InitReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          // Assume that there is no error as the request is fixed and
          // the first to be done after reset is released
          state_d = InitDoneSt;
        end
      end
      // Signal that initialisation is done
      InitDoneSt: begin
        init_sel_d = 1'b0;
      end
    endcase

    // Calculate UART TL-UL integrity
    uart_tl_o.a_user = '{
      rsvd: '0,
      instr_type: prim_mubi_pkg::MuBi4False,
      cmd_intg: tlul_pkg::get_cmd_intg(.tl(uart_tl_o)),
      data_intg: tlul_pkg::get_data_intg(.data(uart_tl_o.a_data))
    };
  end

  //////////
  // Regs //
  //////////

  // State register
  prim_sparse_fsm_flop #(
    .StateEnumT(state_e),
    .Width($bits(state_e)),
    .ResetValue(ResetSt)
  ) u_state_regs (
    .clk_i   ( clk_i   ),
    .rst_ni  ( rst_ni  ),
    .state_i ( state_d ),
    .state_o ( state_q )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      init_sel_q <= 1'b1;
    end else begin
      init_sel_q <= init_sel_d;
    end
  end

endmodule
