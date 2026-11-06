// Copyright lowRISC and contributors (COSMIC project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

module uart16550_translate(
  // Clock and reset
  input  logic clk_i,
  input  logic rst_ni,

  // TL-UL interface to the host
  input  tlul_pkg::tl_h2d_t host_tl_i,
  output tlul_pkg::tl_d2h_t host_tl_o,

  // TL-UL interface to the UART core
  output tlul_pkg::tl_h2d_t uart_tl_o,
  input  tlul_pkg::tl_d2h_t uart_tl_i
);

  // Unused signals
  logic unused_sig;
  assign unused_sig = |{host_tl_i, uart_tl_i, req_reg_q};

  // TODO: LSR reads should only clear INTR_STATE bits previously set
  // TODO: incoming host req intg verify
  // TODO: inocoming uart resp intg verify
  // TODO: error resp from UART should prevent any 16550/OT state modification?
  // TODO: PutPartialData or size != 2 handling
  // TODO: unused fields in TL struct
  // TODO: RACL
  // TODO: NCO solving from div

  ///////////////////
  // Control logic //
  ///////////////////

  // TODO state enc
  localparam int StateWidth = 10;
  typedef enum logic [StateWidth-1:0] {
    IdleSt              = 10'b1110001010,
    FifoReqSt       = 10'b1001000001,
    FifoReqWaitSt       = 10'b0010101101,
    FifoRespSt    = 10'b1101101100,
    IERReqSt     = 10'b0111110000,
    IERReqWaitSt  = 10'b1000110110,
    IERRespSt      = 10'b1011111011,
    IIRReqSt      = 10'b0101011111,
    IIRReqWaitSt   = 10'b0011000110,
    IIRRespSt = 10'b0000011000,
    FCRReqSt    = 10'h0,
    FCRReqWaitSt    = 10'h1,
    FCRRespSt    = 10'h2,
    LCRReqSt    = 10'h3,
    LCRReqWaitSt    = 10'h4,
    LCRRespSt    = 10'h5,
    MCRReqSt    = 10'h6,
    MCRReqWaitSt    = 10'h7,
    MCRRespSt    = 10'h8,
    LSRReqSt    = 10'h9,
    LSRReqWaitSt    = 10'hA,
    LSRRespSt    = 10'hB,
    MSRRespSt = 10'hC,
    SCRRespSt = 10'hD,
    DLReqSt = 10'hE,
    DLReqWaitSt = 10'hF,
    DLRespSt = 10'h10,
    TLReqSt     = 10'h11,
    TLReqWaitSt     = 10'h12,
    TLRespSt     = 10'h13,
    ErrorRespSt         = 10'b0100100011
  } state_e;

  state_e state_d, state_q;

  // 16550 register id enum
  localparam int unsigned RegIdWidth = 4;
  typedef enum logic [RegIdWidth-1:0] {
    RBR = 4'h0,
    THR = 4'h1,
    IER = 4'h2,
    IIR = 4'h3,
    FCR = 4'h4,
    LCR = 4'h5,
    MCR = 4'h6,
    LSR = 4'h7,
    MSR = 4'h8,
    SCR = 4'h9,
    DLL = 4'hA,
    DLM = 4'hB
  } reg_e;

  // Latched request parameters
  reg_e                       req_reg_d;
  reg_e                       req_reg_q;
  tlul_pkg::tl_a_op_e         req_opcode_d;
  tlul_pkg::tl_a_op_e         req_opcode_q;
  logic [top_pkg::TL_DW-1:0]  req_data_d;
  logic [top_pkg::TL_DW-1:0]  req_data_q;
  logic [top_pkg::TL_SZW-1:0] req_size_d;
  logic [top_pkg::TL_SZW-1:0] req_size_q;
  logic [top_pkg::TL_DBW-1:0] req_mask_d;
  logic [top_pkg::TL_DBW-1:0] req_mask_q;
  logic [top_pkg::TL_AIW-1:0] req_source_d;
  logic [top_pkg::TL_AIW-1:0] req_source_q;

  // Latched response parameters
  tlul_pkg::tl_d_op_e        resp_opcode_d;
  tlul_pkg::tl_d_op_e        resp_opcode_q;
  logic [top_pkg::TL_DW-1:0] resp_data_d;
  logic [top_pkg::TL_DW-1:0] resp_data_q;
  logic                      resp_error_d;
  logic                      resp_error_q;

  // Additional request control registers
  logic       req_skip_tl_req_d;
  logic       req_skip_tl_req_q;
  logic [1:0] req_step_d;
  logic [1:0] req_step_q;

  // 16550 state registers
  logic edssi_d;
  logic edssi_q;
  logic fifo_en_d;
  logic fifo_en_q;
  logic dma_mode_d;
  logic dma_mode_q;
  logic pen_d;
  logic pen_q;
  logic eps_d;
  logic eps_q;
  logic break_d;
  logic break_q;
  logic dlab_d;
  logic dlab_q;
  logic loop_d;
  logic loop_q;
  logic dtr_d;
  logic dtr_q;
  logic rts_d;
  logic rts_q;
  logic out1_d;
  logic out1_q;
  logic out2_d;
  logic out2_q;
  logic [7:0] scr_d;
  logic [7:0] scr_q;
  logic [7:0] dll_d;
  logic [7:0] dll_q;
  logic [7:0] dlm_d;
  logic [7:0] dlm_q;

  // OT state registers
  logic txrx_en_d;
  logic txrx_en_q;

  always_comb begin : p_fsm
    // Default
    state_d             = state_q;
    host_tl_o           = tlul_pkg::TL_D2H_DEFAULT;
    host_tl_o.a_ready   = 1'b0;         // Not ready for a new request by default
    host_tl_o.d_size    = req_size_q;   // Return size of the request
    host_tl_o.d_source  = req_source_q; // Return source of the request
    uart_tl_o           = tlul_pkg::TL_H2D_DEFAULT;
    uart_tl_o.a_size    = 2;
    uart_tl_o.a_mask    = '1;

    req_reg_d = req_reg_q;
    req_opcode_d = req_opcode_q;
    req_data_d = req_data_q;
    req_size_d = req_size_q;
    req_mask_d = req_mask_q;
    req_source_d = req_source_q;
    resp_opcode_d = resp_opcode_q;
    resp_data_d = resp_data_q;
    resp_error_d = resp_error_q;

    req_skip_tl_req_d = req_skip_tl_req_q;
    req_step_d = req_step_q;

    edssi_d = edssi_q;
    fifo_en_d = fifo_en_q;
    dma_mode_d = dma_mode_q;
    pen_d = pen_q;
    eps_d = eps_q;
    break_d = break_q;
    dlab_d = dlab_q;
    loop_d = loop_q;
    dtr_d = dtr_q;
    rts_d = rts_q;
    out1_d = out1_q;
    out2_d = out2_q;
    scr_d = scr_q;
    txrx_en_d = txrx_en_q;
    dll_d = dll_q;
    dlm_d = dlm_q;

    unique case (state_q)
      // Wait for new host request
      IdleSt: begin
        // Ready to accept a new request from the host
        host_tl_o.a_ready = 1'b1;

        // Clear latched response data
        resp_data_d = '0;

        if (host_tl_i.a_valid) begin
          // Request param latching
          req_opcode_d = host_tl_i.a_opcode;
          req_data_d = host_tl_i.a_data;
          req_size_d = host_tl_i.a_size;
          req_mask_d = host_tl_i.a_mask;
          req_source_d = host_tl_i.a_source;

          req_step_d = 2'h0;

          // Clear response error
          resp_error_d = 1'b0;

          // Decode request
          unique case (host_tl_i.a_address[4:0])
            'h0: begin
              if (!dlab_q) begin
                req_reg_d = (host_tl_i.a_opcode == tlul_pkg::Get) ? RBR : THR;
                req_skip_tl_req_d = 1'b0;
                state_d = TLReqSt;
              end else begin
                req_reg_d = DLL;
                req_skip_tl_req_d = (host_tl_i.a_opcode == tlul_pkg::Get); // Reads do not require a request to the UART core
                state_d = TLReqSt;
              end
            end
            'h4: begin
              if (!dlab_q) begin
                req_reg_d = IER;
                req_skip_tl_req_d = 1'b0;
                state_d = TLReqSt;
              end else begin
                req_reg_d = DLM;
                req_skip_tl_req_d = (host_tl_i.a_opcode == tlul_pkg::Get); // Reads do not require a request to the UART core
                state_d = TLReqSt;
              end
            end
            'h8: begin
              if (host_tl_i.a_opcode == tlul_pkg::Get) begin
                req_reg_d = IIR;
                req_skip_tl_req_d = 1'b0;
                state_d = IIRReqSt;
                state_d = TLReqSt;
              end else begin
                req_reg_d = FCR;
                req_skip_tl_req_d = 1'b0;
                state_d = FCRReqSt;
              end
            end
            'hC: begin
              req_reg_d = LCR;
              req_skip_tl_req_d = (host_tl_i.a_opcode == tlul_pkg::Get); // Reads do not require a request to the UART core
              if (host_tl_i.a_opcode == tlul_pkg::Get) begin
                // LCR reads do not require a request to the UART core
                state_d = LCRRespSt;
              end else begin
                state_d = LCRReqSt;
              end
            end
            'h10: begin
              req_reg_d = MCR;
              req_skip_tl_req_d = (host_tl_i.a_opcode == tlul_pkg::Get); // Reads do not require a request to the UART core
              if (host_tl_i.a_opcode == tlul_pkg::Get) begin
                // MCR reads do not require a request to the UART core
                state_d = MCRRespSt;
              end else begin
                state_d = MCRReqSt;
              end
            end
            'h14: begin
              req_reg_d = LSR;
              req_skip_tl_req_d = (host_tl_i.a_opcode != tlul_pkg::Get); // Writes are ignored
              if (host_tl_i.a_opcode == tlul_pkg::Get) begin
                state_d = LSRReqSt;
              end else begin
                // LSR writes are ignored
                state_d = LSRRespSt;
              end
            end
            'h18: begin
              req_reg_d = MSR;
              req_skip_tl_req_d = 1'b1; // MSR accesses do not require a request to the UART core
              // MSR accesses do not require a request to the UART core
              state_d = MSRRespSt;
            end
            'h1C: begin
              req_reg_d = SCR;
              req_skip_tl_req_d = 1'b1; // SCR accesses do not require a request to the UART core
              // SCR accesses do not require a request to the UART core
              state_d = SCRRespSt;
            end
            default: state_d = ErrorRespSt; // Unsupported address
          endcase
        end
      end


      // Send TL-UL request to UART
      TLReqSt: begin
        uart_tl_o.a_valid = !req_skip_tl_req_q; // Only send a request is it is not skipped
        unique case ({req_reg_q, req_step_q})
          {RBR, 2'h0}: uart_tl_o.a_opcode = tlul_pkg::Get;
          {THR, 2'h0}: uart_tl_o.a_opcode = tlul_pkg::PutFullData;
          {IER, 2'h0}: uart_tl_o.a_opcode = (req_opcode_q == tlul_pkg::Get) ? tlul_pkg::Get : tlul_pkg::PutFullData;
          {IIR, 2'h0}: uart_tl_o.a_opcode = tlul_pkg::Get;
          {IIR, 2'h1}: uart_tl_o.a_opcode = tlul_pkg::Get;
          {DLL, 2'h0}: uart_tl_o.a_opcode = (req_opcode_q == tlul_pkg::Get) ? tlul_pkg::Get : tlul_pkg::PutFullData;
          {DLM, 2'h0}: uart_tl_o.a_opcode = (req_opcode_q == tlul_pkg::Get) ? tlul_pkg::Get : tlul_pkg::PutFullData;
          default: ; // TODO default
        endcase
        unique case ({req_reg_q, req_step_q})
          {RBR, 2'h0}: uart_tl_o.a_address = 'h18; // RDATA reg
          {THR, 2'h0}: uart_tl_o.a_address = 'h1c; // WDATA reg
          {IER, 2'h0}: uart_tl_o.a_address = 'h4; // INTR_ENABLE reg
          {IIR, 2'h0}: uart_tl_o.a_address = 'h0; // INTR_STATE reg
          {IIR, 2'h1}: uart_tl_o.a_address = 'h4; // INTR_ENABLE reg
          {DLL, 2'h0}: uart_tl_o.a_address = 'h10; // CTRL reg
          {DLM, 2'h0}: uart_tl_o.a_address = 'h10; // CTRL reg
          default: ;
        endcase
        unique case ({req_reg_q, req_step_q})
          {RBR, 2'h0}: uart_tl_o.a_data = '1; // This will be ignored
          {THR, 2'h0}: uart_tl_o.a_data = req_data_q;
          {IER, 2'h0}: begin
            // Write action
            if (req_opcode_q != tlul_pkg::Get) begin
              // EDSSI write
              // This register has no effect but the value is kept
              edssi_d = req_data_q[3];
            end

            uart_tl_o.a_data = '0;
            uart_tl_o.a_data[1] = req_data_q[0]; // rx_watermark = ERBFI
            uart_tl_o.a_data[8] = req_data_q[1]; // tx_empty = ETBEI
            uart_tl_o.a_data[3] = req_data_q[2]; // rx_overflow = ELSI
            uart_tl_o.a_data[4] = req_data_q[2]; // rx_frame_err = ELSI
            uart_tl_o.a_data[5] = req_data_q[2]; // rx_break_err = ELSI
            uart_tl_o.a_data[7] = req_data_q[2]; // rx_parity_err = ELSI
          end
          {IIR, 2'h0}: uart_tl_o.a_data = '1; // This will be ignored
          {IIR, 2'h1}: uart_tl_o.a_data = '1; // This will be ignored
          {DLL, 2'h0}: begin
            // Write action
            if (req_opcode_q != tlul_pkg::Get) begin
              // Enable Tx and Rx
              txrx_en_d = 1'b1;
              // DLL write
              dll_d = req_data_q[7:0];
            end

            uart_tl_o.a_data = '0;
            uart_tl_o.a_data[0] = txrx_en_d; // TX = new txrx_en
            uart_tl_o.a_data[1] = txrx_en_d; // RX = new txrx_en
            uart_tl_o.a_data[4] = loop_q; // SLPBK = loop
            uart_tl_o.a_data[6] = pen_q; // PARITY_EN = PEN
            uart_tl_o.a_data[7] = ~eps_q; // PARITY_ODD = !EPS
            uart_tl_o.a_data[31:16] = 16'd20972; // NCO default value
          end
          {DLM, 2'h0}: begin
            // Write action
            if (req_opcode_q != tlul_pkg::Get) begin
              // Enable Tx and Rx
              txrx_en_d = 1'b1;
              // DLL write
              dlm_d = req_data_q[7:0];
            end

            uart_tl_o.a_data = '0;
            uart_tl_o.a_data[0] = txrx_en_d; // TX = new txrx_en
            uart_tl_o.a_data[1] = txrx_en_d; // RX = new txrx_en
            uart_tl_o.a_data[4] = loop_q; // SLPBK = loop
            uart_tl_o.a_data[6] = pen_q; // PARITY_EN = PEN
            uart_tl_o.a_data[7] = ~eps_q; // PARITY_ODD = !EPS
            uart_tl_o.a_data[31:16] = 16'd20972; // NCO default value
          end
          default: ;
        endcase

        // Move to next state if the request is accepted by the UART core or
        // request is skipped
        if (uart_tl_i.a_ready || req_skip_tl_req_q) begin
          state_d = TLReqWaitSt;
        end
      end
      // Wait for TL-UL response from UART and update response data
      TLReqWaitSt: begin
        if (uart_tl_i.d_valid || req_skip_tl_req_q) begin
          // Update response data
          unique case ({req_reg_q, req_step_q})
            {RBR, 2'h0}: resp_data_d = uart_tl_i.d_data;
            {THR, 2'h0}: resp_data_d = '1;
            {IER, 2'h0}: begin
              if (req_opcode_q == tlul_pkg::Get) begin
                resp_data_d = '0;
                resp_data_d[0] = uart_tl_i.d_data[1]; // ERBFI = rx_watermark
                resp_data_d[1] = uart_tl_i.d_data[8]; // ETBEI = tx_empty
                resp_data_d[2] = (uart_tl_i.d_data[3] & // ELSI = rx_overflow &
                                  uart_tl_i.d_data[4] & //        rx_frame_err &
                                  uart_tl_i.d_data[5] & //        rx_break_err &
                                  uart_tl_i.d_data[7]); //        rx_parity_err
                resp_data_d[3] = edssi_q;        // EDSSI read back
              end else begin
                resp_data_d = '1;
              end
            end
            {IIR, 2'h0}: resp_data_d = uart_tl_i.d_data;
            {IIR, 2'h1}: begin
              req_data_d = resp_data_q & uart_tl_i.d_data; // Temporary store

              resp_data_d = '0;
              // Interrupt pending, active low
              resp_data_d[0] = ~(req_data_d[1] |
                                 req_data_d[3] |
                                 req_data_d[4] |
                                 req_data_d[5] |
                                 req_data_d[7] |
                                 req_data_d[8]);
              if (req_data_d[3] || req_data_d[4] || req_data_d[5] || req_data_d[7]) begin
                // Receiver line status has highest priority
                resp_data_d[2:1] = 2'b11;
              end else if (req_data_d[1]) begin
                // Received data available has highest priority
                resp_data_d[2:1] = 2'b10;
              end else if (req_data_d[8]) begin
                // Transmitter holding register empty has highest priority
                resp_data_d[2:1] = 2'b01;
              end else begin
                // MODEM status has highest priority or no pending interrupt
                resp_data_d[2:1] = 2'b00;
              end
              // Bit 3 = FIFO enable AND timeout error
              resp_data_d[3] = fifo_en_q & req_data_d[3];
              // Bit 6,7 = FIFO enable
              resp_data_d[6] = fifo_en_q;
              resp_data_d[7] = fifo_en_q;
            end
            {DLL, 2'h0}: resp_data_d = (req_opcode_q == tlul_pkg::Get) ? (top_pkg::TL_DW)'(dll_q) : '1;
            {DLM, 2'h0}: resp_data_d = (req_opcode_q == tlul_pkg::Get) ? (top_pkg::TL_DW)'(dlm_q) : '1;
            default:     resp_data_d = '1;
          endcase

          // Catch errors if a request is made
          resp_error_d = resp_error_q | (uart_tl_i.d_error & ~req_skip_tl_req_q);

          // Evaluate next state
          unique case ({req_reg_q, req_step_q})
            {RBR, 2'h0}: state_d = TLRespSt;
            {THR, 2'h0}: state_d = TLRespSt;
            {IER, 2'h0}: state_d = TLRespSt;
            {IIR, 2'h0}: begin
              state_d = TLReqSt;
              req_step_d = req_step_q + 1;
            end
            {IIR, 2'h1}: state_d = TLRespSt;
            {DLL, 2'h0}: state_d = TLRespSt;
            {DLM, 2'h0}: state_d = TLRespSt;
            default: state_d = TLRespSt;
          endcase
        end
      end
      // Send TL-UL response to the host
      TLRespSt: begin
        host_tl_o.d_valid = 1'b1;

        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = tlul_pkg::AccessAck;
        end

        host_tl_o.d_data = resp_data_q;
        host_tl_o.d_error = resp_error_q;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end



      // IIR read: send request to UART
      IIRReqSt: begin
        // Read INTR_STATE / INTR_ENABLE
        uart_tl_o.a_valid = 1;
        uart_tl_o.a_opcode = tlul_pkg::Get;
        if (req_step_q == 0) begin
          uart_tl_o.a_address = 'h0; // INTR_STATE reg
        end else begin
          uart_tl_o.a_address = 'h4; // INTR_ENABLE reg
        end
        uart_tl_o.a_data = '0;

        if (uart_tl_i.a_ready) begin
          state_d = IIRReqWaitSt;
        end
      end
      // IIR read: wait for response from UART
      IIRReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          resp_opcode_d = uart_tl_i.d_opcode;
          if (req_step_q == 0) begin
            resp_data_d = uart_tl_i.d_data;
            resp_error_d = uart_tl_i.d_error;
          end else begin
            resp_data_d = resp_data_q & uart_tl_i.d_data;
            resp_error_d = resp_error_q | uart_tl_i.d_error;
          end

          if (req_step_q == 0) begin
            // Next step, read another register
            req_step_d = 1;
            state_d = IIRReqSt;
          end else begin
            // UART reads done
            state_d = IIRRespSt;
          end
        end
      end
      // IIR read: send response to host
      IIRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        host_tl_o.d_opcode = resp_opcode_q;
        // OT to 16550 mapping
        host_tl_o.d_data = '0;
        // Interrupt pending, active low
        host_tl_o.d_data[0] = ~(resp_data_q[1] |
                                resp_data_q[3] |
                                resp_data_q[4] |
                                resp_data_q[5] |
                                resp_data_q[7] |
                                resp_data_q[8]);
        if (resp_data_q[3] || resp_data_q[4] || resp_data_q[5] || resp_data_q[7]) begin
          // Receiver line status has highest priority
          host_tl_o.d_data[2:1] = 2'b11;
        end else if (resp_data_q[1]) begin
          // Received data available has highest priority
          host_tl_o.d_data[2:1] = 2'b10;
        end else if (resp_data_q[8]) begin
          // Transmitter holding register empty has highest priority
          host_tl_o.d_data[2:1] = 2'b01;
        end else begin
          // MODEM status has highest priority or no pending interrupt
          host_tl_o.d_data[2:1] = 2'b00;
        end
        // Bit 3 = FIFO enable AND timeout error
        host_tl_o.d_data[3] = fifo_en_q & resp_data_q[3];
        // Bit 6,7 = FIFO enable
        host_tl_o.d_data[6] = fifo_en_q;
        host_tl_o.d_data[7] = fifo_en_q;
        host_tl_o.d_error = resp_error_q;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // FCR write: send request to UART
      FCRReqSt: begin
        // Write FIFO_CTRL
        uart_tl_o.a_valid = 1;
        uart_tl_o.a_opcode = tlul_pkg::PutFullData;
        uart_tl_o.a_address = 'h20; // FIFO_CTRL reg
        // 16550 to OT mapping
        uart_tl_o.a_data = '0;
        uart_tl_o.a_data[0] = req_data_q[1]; // RXRST = RCVR FIFO reset
        uart_tl_o.a_data[1] = req_data_q[2]; // TXRST = XMIT FIFO reset
        // RXILVL mapped from RCVR trigger
        unique case (req_data_q[7:6])
          2'b00: uart_tl_o.a_data[4:2] = 3'h0; // 1 char == 1 byte
          2'b01: uart_tl_o.a_data[4:2] = 3'h2; // 4 char == 4 bytes
          2'b10: uart_tl_o.a_data[4:2] = 3'h3; // 8 char == 8 bytes
          2'b11: uart_tl_o.a_data[4:2] = 3'h4; // 16 char ~= 14 bytes
          default: ;
        endcase

        // FIFO enable write
        fifo_en_d = req_data_q[0];

        // DMA mode write
        dma_mode_d = req_data_q[3];

        if (uart_tl_i.a_ready) begin
          state_d = FCRReqWaitSt;
        end
      end
      // FCR write: wait for response from UART
      FCRReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          resp_opcode_d = uart_tl_i.d_opcode;
          resp_data_d = uart_tl_i.d_data;
          resp_error_d = uart_tl_i.d_error;

          state_d = FCRRespSt;
        end
      end
      // FCR write: send response to host
      FCRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        host_tl_o.d_opcode = resp_opcode_q;
        host_tl_o.d_data = '1;
        host_tl_o.d_error = resp_error_q;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // LCR write: send request to UART
      LCRReqSt: begin
        // Write CTRL / OVRD
        uart_tl_o.a_valid = 1;
        uart_tl_o.a_opcode = tlul_pkg::PutFullData;
        if (req_step_q == 0) begin
          uart_tl_o.a_address = 'h10; // CTRL reg
        end else begin
          uart_tl_o.a_address = 'h28; // OVRD reg
        end
        // 16550 to OT mapping
        if (req_step_q == 0) begin
          pen_d = req_data_q[3];
          eps_d = req_data_q[4];
          uart_tl_o.a_data = '0;
          uart_tl_o.a_data[0] = txrx_en_q; // TX = txrx_en
          uart_tl_o.a_data[1] = txrx_en_q; // RX = txrx_en
          uart_tl_o.a_data[4] = loop_q; // SLPBK = loop
          uart_tl_o.a_data[6] = pen_d; // PARITY_EN = PEN
          uart_tl_o.a_data[7] = ~eps_d; // PARITY_ODD = !EPS
          uart_tl_o.a_data[31:16] = 16'd20972; // NCO default value
        end else begin
          break_d = req_data_q[6];
          uart_tl_o.a_data = '0;
          uart_tl_o.a_data[0] = break_d; // TXEN = break
          uart_tl_o.a_data[1] = 1'b0; // TXVAL = 0
        end

        // DLAB write
        dlab_d = req_data_q[7];

        if (uart_tl_i.a_ready) begin
          state_d = LCRReqWaitSt;
        end
      end
      // LCR write: wait for response from UART
      LCRReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          resp_opcode_d = uart_tl_i.d_opcode;
          // No need to latch response data
          if (req_step_q == 0) begin
            resp_error_d = uart_tl_i.d_error;
          end else begin
            resp_error_d = resp_error_q | uart_tl_i.d_error;
          end

          if (req_step_q == 0) begin
            // Next step, write another register
            req_step_d = 1;
            state_d = LCRReqSt;
          end else begin
            // UART writes done
            state_d = LCRRespSt;
          end
        end
      end
      // LCR access: send response to host
      LCRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = resp_opcode_q;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          // OT to 16550 mapping
          host_tl_o.d_data = '0;
          host_tl_o.d_data[1:0] = 2'b11; // WLS = 8 bits (non-adjustable)
          host_tl_o.d_data[2] = 1'b0; // STB = 1 stop bit (non-adjustable)
          host_tl_o.d_data[3] = pen_q; // PEN
          host_tl_o.d_data[4] = eps_q; // EPS
          host_tl_o.d_data[5] = 1'b0; // Stick parity not supported
          host_tl_o.d_data[6] = break_q; // Set break
          host_tl_o.d_data[7] = dlab_q; // DLAB
        end else begin
          host_tl_o.d_data = '1;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_error = 1'b0;
        end else begin
          host_tl_o.d_error = resp_error_q;
        end

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // MCR write: send request to UART
      MCRReqSt: begin
        // Write CTRL
        uart_tl_o.a_valid = 1;
        uart_tl_o.a_opcode = tlul_pkg::PutFullData;
        uart_tl_o.a_address = 'h10; // CTRL reg
        // 16550 to OT mapping
        loop_d = req_data_q[4]; // loop
        uart_tl_o.a_data = '0;
        uart_tl_o.a_data[0] = txrx_en_q; // TX = txrx_en
        uart_tl_o.a_data[1] = txrx_en_q; // RX = txrx_en
        uart_tl_o.a_data[4] = loop_d; // SLPBK = loop
        uart_tl_o.a_data[6] = pen_q; // PARITY_EN = PEN
        uart_tl_o.a_data[7] = ~eps_q; // PARITY_ODD = !EPS
        uart_tl_o.a_data[31:16] = 16'd20972; // NCO default value

        // MODEM control reg writes
        dtr_d = req_data_q[0];
        rts_d = req_data_q[1];
        out1_d = req_data_q[2];
        out2_d = req_data_q[3];

        if (uart_tl_i.a_ready) begin
          state_d = MCRReqWaitSt;
        end
      end
      // MCR write: wait for response from UART
      MCRReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          resp_opcode_d = uart_tl_i.d_opcode;
          resp_data_d = uart_tl_i.d_data;
          resp_error_d = uart_tl_i.d_error;

          state_d = MCRRespSt;
        end
      end
      // MCR access: send response to host
      MCRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = resp_opcode_q;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          // OT to 16550 mapping
          host_tl_o.d_data = '0;
          host_tl_o.d_data[0] = dtr_q; // DTR
          host_tl_o.d_data[1] = rts_q; // RTS
          host_tl_o.d_data[2] = out1_q; // OUT1
          host_tl_o.d_data[3] = out2_q; // OUT2
          host_tl_o.d_data[4] = loop_q; // loop
        end else begin
          host_tl_o.d_data = '1;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_error = 1'b0;
        end else begin
          host_tl_o.d_error = resp_error_q;
        end

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // LSR read: send request to UART
      LSRReqSt: begin
        // Read STATUS / INTR_STATE / write INTR_STATE
        uart_tl_o.a_valid = 1;
        if (req_step_q != 2) begin
          uart_tl_o.a_opcode = tlul_pkg::Get;
        end else begin
          uart_tl_o.a_opcode = tlul_pkg::PutFullData;
        end
        if (req_step_q == 0) begin
          uart_tl_o.a_address = 'h14; // STATUS reg
        end else begin
          uart_tl_o.a_address = 'h0; // INTR_STATE reg
        end
        // Clear interrupts if this is a write to INTR_STATE
        uart_tl_o.a_data = '0;
        uart_tl_o.a_data[3] = 1'b1; // Clear rx_overflow
        uart_tl_o.a_data[4] = 1'b1; // Clear rx_frame_err
        uart_tl_o.a_data[5] = 1'b1; // Clear rx_break_err
        uart_tl_o.a_data[7] = 1'b1; // Clear rx_parity_err

        if (uart_tl_i.a_ready) begin
          state_d = LSRReqWaitSt;
        end
      end
      // LSR read: wait for response from UART
      LSRReqWaitSt: begin
        if (uart_tl_i.d_valid) begin
          resp_opcode_d = uart_tl_i.d_opcode;
          // Latch specific bits
          if (req_step_q == 0) begin
            resp_data_d[0] = ~uart_tl_i.d_data[5]; // DR = !STATUS.RXEMPTY
            resp_data_d[5] = uart_tl_i.d_data[2]; // THRE = STATUS.TXEMPTY
            resp_data_d[6] = uart_tl_i.d_data[3]; // TEMT = STATUS.TXIDLE
            resp_error_d = uart_tl_i.d_error;
          end else if (req_step_q == 1) begin
            resp_data_d[1] = uart_tl_i.d_data[3]; // OE = INTR_STATE.rx_overflow
            resp_data_d[2] = uart_tl_i.d_data[7]; // PE = INTR_STATE.rx_parity_err
            resp_data_d[3] = uart_tl_i.d_data[4]; // FE = INTR_STATE.rx_frame_err
            resp_data_d[4] = uart_tl_i.d_data[5]; // BI = INTR_STATE.rx_break_err
            resp_data_d[7] = |resp_data_d[4:2]; // Error in RCVR FIFO = INTR_STATE.(rx_parity_err | rx_frame_err | rx_break_err)
            resp_error_d = resp_error_q | uart_tl_i.d_error;
          end else begin
            resp_error_d = resp_error_q | uart_tl_i.d_error;
          end

          if (req_step_q != 2) begin
            // Next step, read/write another register
            req_step_d = req_step_q + 1;
            state_d = LSRReqSt;
          end else begin
            // UART accesses done
            state_d = LSRRespSt;
          end
        end
      end
      // LSR access: send response to host
      LSRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = tlul_pkg::AccessAck;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_data = resp_data_d;
        end else begin
          host_tl_o.d_data = '1;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_error = resp_error_q;
        end else begin
          host_tl_o.d_error = 1'b0;
        end

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // MSR access: send response to host
      MSRRespSt: begin
        host_tl_o.d_valid = 1'b1;
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = tlul_pkg::AccessAck;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_data = '0;
          // OT to 16550 mapping
          host_tl_o.d_data[0] = 1'b0; // DCTS = 0
          host_tl_o.d_data[1] = 1'b0; // DDSR = 0
          host_tl_o.d_data[2] = 1'b0; // TERI = 0
          host_tl_o.d_data[3] = 1'b0; // DDCD = 0
          host_tl_o.d_data[4] = loop_q & rts_q; // CTS = if loop RTS else 0
          host_tl_o.d_data[5] = loop_q & dtr_q; // DSR = if loop DTR else 0
          host_tl_o.d_data[6] = loop_q & out1_q; // RI = if loop OUT1 else 0
          host_tl_o.d_data[7] = loop_q & out2_q; // DCD = if loop OUT2 else 0
        end else begin
          host_tl_o.d_data = '1;
        end
        host_tl_o.d_error = 1'b0;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // MSR access: send response to host
      SCRRespSt: begin
        // SCR write logic
        if (req_opcode_q != tlul_pkg::Get) begin
          scr_d = req_data_q[7:0];
        end

        // Send host response
        host_tl_o.d_valid = 1'b1;
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_opcode = tlul_pkg::AccessAckData;
        end else begin
          host_tl_o.d_opcode = tlul_pkg::AccessAck;
        end
        if (req_opcode_q == tlul_pkg::Get) begin
          host_tl_o.d_data = '0;
          host_tl_o.d_data[7:0] = scr_q;
        end else begin
          host_tl_o.d_data = '1;
        end
        host_tl_o.d_error = 1'b0;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      // Send error response to host
      ErrorRespSt: begin
        host_tl_o.d_valid = 1'b1;
        host_tl_o.d_opcode = tlul_pkg::AccessAck;
        host_tl_o.d_data = '1;
        host_tl_o.d_error = 1'b1;

        if (host_tl_i.d_ready) begin
          state_d = IdleSt;
        end
      end
      default: begin
        state_d = IdleSt;
      end
    endcase

    // Calculate host TL-UL integrity
    host_tl_o.d_user = '{
      rsp_intg: tlul_pkg::get_rsp_intg(.tl(host_tl_o)),
      data_intg: tlul_pkg::get_data_intg(.data(host_tl_o.d_data))
    };

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
    .ResetValue(IdleSt),
    .EnableAlertTriggerSVA(0)
  ) u_state_regs (
    .clk_i   ( clk_i   ),
    .rst_ni  ( rst_ni  ),
    .state_i ( state_d ),
    .state_o ( state_q )
  );

  always_ff @(posedge clk_i) begin
    req_reg_q <= req_reg_d;
    req_opcode_q <= req_opcode_d;
    req_data_q <= req_data_d;
    req_mask_q <= req_mask_d;
    resp_opcode_q <= resp_opcode_d;
    resp_data_q <= resp_data_d;
    resp_error_q <= resp_error_d;
    req_skip_tl_req_q <= req_skip_tl_req_d;
    req_step_q <= req_step_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      edssi_q <= 1'b0;
      fifo_en_q <= 1'b0;
      dma_mode_q <= 1'b0;
      pen_q <= 1'b0;
      eps_q <= 1'b1; // Even parity on by default
      break_q <= 1'b0;
      dlab_q <= 1'b0;
      loop_q <= 1'b0;
      dtr_q <= 1'b0;
      rts_q <= 1'b0;
      out1_q <= 1'b0;
      out2_q <= 1'b0;
      scr_q <= '0;
      txrx_en_q <= 1'b0;
      dll_q <= '0;
      dlm_q <= '0;
      req_size_q <= '0;
      req_source_q <= '0;
    end else begin
      edssi_q <= edssi_d;
      fifo_en_q <= fifo_en_d;
      dma_mode_q <= dma_mode_d;
      pen_q <= pen_d;
      eps_q <= eps_d;
      break_q <= break_d;
      dlab_q <= dlab_d;
      loop_q <= loop_d;
      dtr_q <= dtr_d;
      rts_q <= rts_d;
      out1_q <= out1_d;
      out2_q <= out2_d;
      scr_q <= scr_d;
      txrx_en_q <= txrx_en_d;
      dll_q <= dll_d;
      dlm_q <= dlm_d;
      req_size_q <= req_size_d;
      req_source_q <= req_source_d;
    end
  end

endmodule
