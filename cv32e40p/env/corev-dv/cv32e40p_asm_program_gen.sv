/*
 * Copyright 2018 Google LLC
 * Copyright 2020 Andes Technology Co., Ltd.
 * Copyright 2020 OpenHW Group
 * Copyright 2023 Dolphin Design
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//-----------------------------------------------------------------------------------------
// CV32E40P CORE-V assembly program generator - extension of the RISC-V assembly program generator.
// 
// Overrides:
//   - gen_interrupt_vector_table()
//   - gen_program_header()
//   - gen_test_done()
//   - get_directed_instr_stream()
//   - init_gpr()
//   - init_floating_point_gpr()
//-----------------------------------------------------------------------------------------

class cv32e40p_asm_program_gen extends corev_asm_program_gen;

  `uvm_object_utils(cv32e40p_asm_program_gen)

  function new (string name = "");
    super.new(name);
  endfunction

  virtual function void gen_interrupt_vector_table(int              hart,
                                                   string           mode,
                                                   privileged_reg_t status,
                                                   privileged_reg_t cause,
                                                   privileged_reg_t ie,
                                                   privileged_reg_t ip,
                                                   privileged_reg_t scratch,
                                                   ref string       instr[$]);
    // In vector mode, the BASE address is shared between interrupt 0 and exception handling.
    // When vectored interrupts are enabled, interrupt cause 0, which corresponds to user-mode
    // software interrupts, are vectored to the same location as synchronous exceptions. This
    // ambiguity does not arise in practice, since user-mode software interrupts are either
    // disabled or delegated
    cv32e40p_instr_gen_config corev_cfg;
    `DV_CHECK_FATAL($cast(corev_cfg, cfg), "Could not cast cfg into corev_cfg")

    instr = {instr, ".option norvc;",
                    $sformatf("j %0s%0smode_exception_handler", hart_prefix(hart), mode)};
    // Redirect the interrupt to the corresponding interrupt handler
    for (int i = 1; i < max_interrupt_vector_num; i++) begin
      instr.push_back($sformatf("j %0s%0smode_intr_vector_%0d", hart_prefix(hart), mode, i));      
    end
    if (!cfg.disable_compressed_instr) begin
      instr = {instr, ".option rvc;"};
    end
    for (int i = 1; i < max_interrupt_vector_num; i++) begin      
      string intr_handler[$];

      if (corev_cfg.use_fast_intr_handler[i]) begin
        // Emit fast interrupt handler since cv32e40p has hardware interrupt ack
        // If WFIs allow, randomly insert wfi as well
        if (!cfg.no_wfi) begin         
            randcase
                2:  intr_handler.push_back("wfi");
                4: begin /* insert nothing */ end
            endcase          
        end
        intr_handler.push_back("mret");
      end
      else begin
        // Standard full-stack-save interrupt handler
        push_gpr_to_kernel_stack(status, scratch, cfg.mstatus_mprv, cfg.sp, cfg.tp, intr_handler);
        gen_signature_handshake(.instr(intr_handler), .signature_type(CORE_STATUS),
                                .core_status(HANDLING_IRQ));
        intr_handler = {intr_handler,
                        $sformatf("csrr x%0d, 0x%0x # %0s", cfg.gpr[0], cause, cause.name()),
                        // Terminate the test if xCause[31] != 0 (indicating exception)
                        $sformatf("srli x%0d, x%0d, 0x%0x", cfg.gpr[0], cfg.gpr[0], XLEN-1),
                        $sformatf("beqz x%0d, 1f", cfg.gpr[0])};
        gen_signature_handshake(.instr(intr_handler), .signature_type(WRITE_CSR), .csr(status));
        gen_signature_handshake(.instr(intr_handler), .signature_type(WRITE_CSR), .csr(cause));
        gen_signature_handshake(.instr(intr_handler), .signature_type(WRITE_CSR), .csr(ie));
        gen_signature_handshake(.instr(intr_handler), .signature_type(WRITE_CSR), .csr(ip));
        // Jump to commmon interrupt handling routine
        intr_handler = {intr_handler,
                        $sformatf("j %0s%0smode_intr_handler", hart_prefix(hart), mode),
                        $sformatf("1: la x%0d, test_done", cfg.scratch_reg),
                        $sformatf("jalr x%0d, 0", cfg.scratch_reg)};
      end

      gen_section(get_label($sformatf("%0smode_intr_vector_%0d", mode, i), hart), intr_handler);
    end
  endfunction : gen_interrupt_vector_table

  // Setup EPC before entering target privileged mode
  virtual function void setup_epc(int hart);
    string instr[$];
    string mode_name;
    instr = {$sformatf("la x%0d, %0sinit", cfg.gpr[0], hart_prefix(hart))};
    if(cfg.virtual_addr_translation_on) begin
      // For supervisor and user mode, use virtual address instead of physical address.
      // Virtual address starts from address 0x0, here only the lower 12 bits are kept
      // as virtual address offset.
      instr = {instr,
               $sformatf("slli x%0d, x%0d, %0d", cfg.gpr[0], cfg.gpr[0], XLEN - 12),
               $sformatf("srli x%0d, x%0d, %0d", cfg.gpr[0], cfg.gpr[0], XLEN - 12)};
    end
    mode_name = cfg.init_privileged_mode.name();
    instr.push_back($sformatf("csrw mepc, x%0d", cfg.gpr[0]));
    gen_section(get_label("mepc_setup", hart), instr);
  endfunction

  // Interrupt handler routine
  // Override from risc-dv:
  // 1. Remove MIP read, since interrupts are auto-cleared, mip will not track through the ISS
  //    to GPR properly with autoclear
  virtual function void gen_interrupt_handler_section(privileged_mode_t mode, int hart);
    string mode_prefix;
    string ls_unit;
    privileged_reg_t status, ip, ie, scratch;
    string interrupt_handler_instr[$];

    ls_unit = (XLEN == 32) ? "w" : "d";
    if (mode < cfg.init_privileged_mode) return;
    if (mode == USER_MODE && !riscv_instr_pkg::support_umode_trap) return;
    case(mode)
      MACHINE_MODE: begin
        mode_prefix = "m";
        status = MSTATUS;
        ip = MIP;
        ie = MIE;
        scratch = MSCRATCH;
      end
      SUPERVISOR_MODE: begin
        mode_prefix = "s";
        status = SSTATUS;
        ip = SIP;
        ie = SIE;
        scratch = SSCRATCH;
      end
      USER_MODE: begin
        mode_prefix = "u";
        status = USTATUS;
        ip = UIP;
        ie = UIE;
        scratch = USCRATCH;
      end
      default: `uvm_fatal(get_full_name(), $sformatf("Unsupported mode: %0s", mode.name()))
    endcase

    // If nested interrupts are enabled, set xSTATUS.xIE in the interrupt handler
    // to re-enable interrupt handling capabilities
    if (cfg.enable_nested_interrupt) begin
      string store_instr = (XLEN == 32) ? "sw" : "sd";

      // kernel stack point is already in sp, mscratch already has stored stack pointer
      interrupt_handler_instr.push_back($sformatf("1: addi x%0d, x%0d, -%0d", cfg.sp, cfg.sp, 4 * (XLEN/8)));

      // Push MIE, MEPC and MSTATUS to stack
      interrupt_handler_instr.push_back($sformatf("csrr x%0d, mie", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", store_instr, cfg.gpr[0], 1 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrr x%0d, mepc", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", store_instr, cfg.gpr[0], 2 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrr x%0d, mstatus", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", store_instr, cfg.gpr[0], 3 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrr x%0d, mscratch", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", store_instr, cfg.gpr[0], 4 * (XLEN/8), cfg.sp));

      // Move SP to TP and restore TP
      interrupt_handler_instr.push_back($sformatf("add x%0d, x%0d, zero", cfg.tp, cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrrw x%0d, mscratch, x%0d", cfg.sp, cfg.sp));

      // Re-enable interrupts        
      case (status)
        MSTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrsi 0x%0x, 0x%0x", status, 8));
        end
        SSTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrsi 0x%0x, 0x%0x", status, 2));
        end
        USTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrsi 0x%0x, 0x%0x", status, 1));
        end
        default: `uvm_fatal(`gfn, $sformatf("Unsupported status %0s", status))
      endcase
    end

    // Read back interrupt related privileged CSR
    // The value of these CSR are checked by comparing with spike simulation result.
    interrupt_handler_instr = {
           interrupt_handler_instr,
           $sformatf("csrr  x%0d, 0x%0x # %0s;", cfg.gpr[0], status, status.name()),
           $sformatf("csrr  x%0d, 0x%0x # %0s;", cfg.gpr[0], ie, ie.name())
    };
    gen_plic_section(interrupt_handler_instr);

    if (cfg.enable_nested_interrupt) begin
      string load_instr = (XLEN == 32) ? "lw" : "ld";

      // If in nested interrupts, the restoration of all GPRs and interrupt registers from stack
      // are considered a critical section
      // Re-disable interrupts
      case (status)
        MSTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrci 0x%0x, 0x%0x", status, 8));
        end
        SSTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrci 0x%0x, 0x%0x", status, 2));
        end
        USTATUS: begin
          interrupt_handler_instr.push_back($sformatf("csrci 0x%0x, 0x%0x", status, 1));
        end
        default: `uvm_fatal(`gfn, $sformatf("Unsupported status %0s", status))
      endcase

      // Save SP to scratch and move TP to SP
      interrupt_handler_instr.push_back($sformatf("csrrw x%0d, mscratch, x%0d", cfg.sp, cfg.sp));
      interrupt_handler_instr.push_back($sformatf("add x%0d, x%0d, zero", cfg.sp, cfg.tp));

      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", load_instr, cfg.gpr[0], 1 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrw mie, x%0d", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", load_instr, cfg.gpr[0], 2 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrw mepc, x%0d", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", load_instr, cfg.gpr[0], 3 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrw mstatus, x%0d", cfg.gpr[0]));
      interrupt_handler_instr.push_back($sformatf("%0s  x%0d, %0d(x%0d)", load_instr, cfg.gpr[0], 4 * (XLEN/8), cfg.sp));
      interrupt_handler_instr.push_back($sformatf("csrw mscratch, x%0d", cfg.gpr[0]));

      interrupt_handler_instr.push_back($sformatf("addi x%0d, x%0d, %0d", cfg.sp, cfg.sp, 4 * (XLEN/8)));
    end

    // Restore user mode GPR value from kernel stack before return
    pop_gpr_from_kernel_stack(status, scratch, cfg.mstatus_mprv,
                              cfg.sp, cfg.tp, interrupt_handler_instr);
                                      // Emit fast interrupt handler since cv32e40p has hardware interrupt ack

    interrupt_handler_instr = {interrupt_handler_instr,
                               $sformatf("%0sret;", mode_prefix)
    };
    if (SATP_MODE != BARE) begin
      // The interrupt handler will use one 4KB page
      instr_stream.push_back(".align 12");
    end else begin
      instr_stream.push_back(".align 2");
    end
    gen_section(get_label($sformatf("%0smode_intr_handler", mode_prefix), hart),
                interrupt_handler_instr);
  endfunction : gen_interrupt_handler_section

  // Override gen_stack_section to add debugger stack generation section  
  // Implmeneted as a post-step to super.gen_stack_section()
  virtual function void gen_stack_section(int hart);  
    super.gen_stack_section(hart);

    if (SATP_MODE != BARE) begin
      instr_stream.push_back(".align 12");
    end else begin
      instr_stream.push_back(".align 2");
    end
    instr_stream.push_back(get_label("debugger_stack_start:", hart));
    instr_stream.push_back($sformatf(".rept %0d", cfg.stack_len - 1));
    instr_stream.push_back($sformatf(".%0dbyte 0x0", XLEN/8));
    instr_stream.push_back(".endr");
    instr_stream.push_back(get_label("debugger_stack_end:", hart));
    instr_stream.push_back($sformatf(".%0dbyte 0x0", XLEN/8));

  endfunction : gen_stack_section

  // Override of init_gpr to remove cfg.dp from initiailization if a debug section is generated
  virtual function void init_gpr();
    string str;
    string reg_name;
    bit [DATA_WIDTH-1:0] reg_val;
    cv32e40p_instr_gen_config cfg_corev;
    bit [31:0] imm;

    `DV_CHECK($cast(cfg_corev, cfg))    
    // Init general purpose registers with random values
    for(int i = 0; i < NUM_GPR; i++) begin
      if (i inside {cfg.sp, cfg.tp}) continue;
      if (cfg.gen_debug_section && (i inside {cfg_corev.dp})) continue;
      
      `DV_CHECK_STD_RANDOMIZE_WITH_FATAL(reg_val,
        reg_val dist {
          'h0                         :/ 1,
          'h8000_0000                 :/ 1,
          ['h1         : 'hF]         :/ 1,
          ['h10        : 'hEFFF_FFFF] :/ 1,
          ['hF000_0000 : 'hFFFF_FFFF] :/ 1
        };)
      str = $sformatf("%0sli%0s x%0d, 0x%0x", indent, indent, i, reg_val);
      instr_stream.push_back(str);
    end
    //after initializing all gprs, for zfinx extention tests again initialize
    //gprs for floating point instructions
    if(RV32ZFINX inside {supported_isa}) begin
      foreach(cfg_corev.zfinx_reserved_gpr[i]) begin
        if (cfg_corev.zfinx_reserved_gpr[i] inside {ZERO, RA, SP, GP, TP}) continue;
        imm = get_rand_spf_value();
        reg_name = cfg_corev.zfinx_reserved_gpr[i].name();
        str = $sformatf("%0sli%0s %0s, 0x%0x", indent, indent, reg_name.tolower(), imm);
        instr_stream.push_back(str);
      end
    end
  endfunction

  // Override get_directed_instr_stream for cfg "insert_rand_directed_instr_stream"
  // Use this plusarg cfg along with "test_rand_directed_instr_stream_num" and
  // "rand_directed_instr_*" to select 1 single directed_instr_stream randomly
  // and insert in the generated instruction stream.
  virtual function void get_directed_instr_stream();
    string args, val;
    string stream_name_opts, stream_freq_opts;
    string stream_name;
    int stream_freq;
    string opts[$];
    int dir_stream_id = 0;

    cv32e40p_instr_gen_config corev_cfg;
    `DV_CHECK_FATAL($cast(corev_cfg, cfg), "Could not cast cfg into corev_cfg")

    if(corev_cfg.insert_rand_directed_instr_stream) begin
      //test_rand_directed_instr_stream_num specify the total num of rand_* streams to select from
      dir_stream_id = $urandom_range(0,corev_cfg.test_rand_directed_instr_stream_num-1);
      //Specify rand_directed_instr_0="" to rand_directed_instr_n="" as streams to randomize
      args = $sformatf("rand_directed_instr_%0d=", dir_stream_id);
      stream_name_opts = $sformatf("rand_stream_name_%0d=", dir_stream_id);
      stream_freq_opts = $sformatf("rand_stream_freq_%0d=", dir_stream_id);
      `uvm_info("cv32e40p_asm_program_gen", $sformatf("Randomly selected dir_stream_id : %0d", dir_stream_id), UVM_NONE)
      if ($value$plusargs({args,"%0s"}, val)) begin
        uvm_split_string(val, ",", opts);
        if (opts.size() != 2) begin
          `uvm_fatal(`gfn, $sformatf(
            "Incorrect directed instruction format : %0s, expect: name,ratio", val))
        end else begin
          add_directed_instr_stream(opts[0], opts[1].atoi());
        end
      end else if ($value$plusargs({stream_name_opts,"%0s"}, stream_name) &&
                   $value$plusargs({stream_freq_opts,"%0d"}, stream_freq)) begin
        add_directed_instr_stream(stream_name, stream_freq);
      end
    end

    for (int i=0; i<cfg.max_directed_instr_stream_seq; i++) begin
      args = $sformatf("directed_instr_%0d=", i);
      stream_name_opts = $sformatf("stream_name_%0d=", i);
      stream_freq_opts = $sformatf("stream_freq_%0d=", i);
      if ($value$plusargs({args,"%0s"}, val)) begin
        uvm_split_string(val, ",", opts);
        if (opts.size() != 2) begin
          `uvm_fatal(`gfn, $sformatf(
            "Incorrect directed instruction format : %0s, expect: name,ratio", val))
        end else begin
          add_directed_instr_stream(opts[0], opts[1].atoi());
        end
      end else if ($value$plusargs({stream_name_opts,"%0s"}, stream_name) &&
                   $value$plusargs({stream_freq_opts,"%0d"}, stream_freq)) begin
        add_directed_instr_stream(stream_name, stream_freq);
      end
    end
  endfunction

  // Override init_floating_point_gpr
  virtual function void init_floating_point_gpr();
    int int_gpr;
    string str;
    for(int i = 0; i < NUM_FLOAT_GPR; i++) begin
      randcase
        RV32F inside {supported_isa}: init_floating_point_gpr_with_spf(i);
        RV64D inside {supported_isa}: init_floating_point_gpr_with_dpf(i);
      endcase
    end
    // Initialize rounding mode of FCSR
    str = $sformatf("%0sfsrmi%0s %0d", indent, indent, cfg.fcsr_rm);
    instr_stream.push_back(str);
  endfunction

endclass : cv32e40p_asm_program_gen
