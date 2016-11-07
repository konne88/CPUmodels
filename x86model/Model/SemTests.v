(* Tests on x86 semantics contributed by Konstantin Weitz and 
   Stefan Heule *)

Require Import X86Semantics.
Import X86_RTL.
Import X86_Compile.
Import X86_MACHINE.
Require Import Maps.
Require Import Bits.
Require Import List.
Require Import Coq.PArith.BinPos.
Require Import Bool.
Import ListNotations.
Import PTree.
Import Pos.
Import BinNums.
Import Word.

Arguments Word.mone {_}.

(* Notation "# n" := (mkint _ n _)(at level 45). *)

Section InitState.
Variable eax ebx ecx edx: int32.
Variable cf: int1.

Definition empty_mem : AddrMap.t int8 := (Word.zero, PTree.empty _).
Definition empty_seg : fmap segment_register int32 := (fun seg => Word.zero).
Definition empty_flags : fmap flag int1 := fun f => Word.zero.
Definition init_pc : int32 := Word.zero.
Definition init_reg : fmap register int32 := 
  fun reg => match reg with 
               EAX => eax
             | EBX => ebx
             | ECX => ecx
             | EDX => edx
             | _ => Word.zero end.

Definition empty_oracle : oracle.
  refine {|
    oracle_bits := (fun a b => Word.zero);
    oracle_offset := 0
  |}.
Defined.

Definition init_machine : core_state. 
  refine {|
    gp_regs := init_reg;
    seg_regs_starts := empty_seg;
    seg_regs_limits := (fun seg_reg => Word.mone);
    flags_reg := empty_flags;
    control_regs := (fun c => Word.zero);
    debug_regs :=  (fun d => Word.zero);
    pc_reg := init_pc
  |}.
Defined.

Definition empty_fpu_machine : fpu_state.
refine {|
  fpu_data_regs := (fun fpr => Word.zero);
  fpu_status := Word.zero;
  fpu_control := Word.zero;
  fpu_tags := (fun t => Word.zero);
  fpu_lastInstrPtr := Word.zero;
  fpu_lastDataPtr := Word.zero;
  fpu_lastOpcode := Word.zero
|}.
Defined.

Definition init_full_machine : mach_state.
  refine {|
   core := init_machine;
   fpu := empty_fpu_machine
  |}.
Defined.

Definition init_rtl_state : rtl_state.
  refine {|
    rtl_oracle := empty_oracle;
    rtl_env := empty_env;
    rtl_mach_state := init_full_machine;
    rtl_memory := empty_mem
  |}.
Defined.

Definition no_prefix : prefix := mkPrefix None None false false.

Definition flags_cf : fmap flag int1 := 
  fun f => if flag_eq_dec f CF then cf else Word.zero.

Definition init_machine_cf : core_state. 
  refine {|
    gp_regs := init_reg;
    seg_regs_starts := empty_seg;
    seg_regs_limits := (fun seg_reg => Word.mone);
    flags_reg := flags_cf;
    control_regs := (fun c => Word.zero);
    debug_regs :=  (fun d => Word.zero);
    pc_reg := init_pc
  |}.
Defined.

Definition init_full_machine_cf : mach_state.
  refine {|
   core := init_machine_cf;
   fpu := empty_fpu_machine
  |}.
Defined.

Definition init_rtl_state_cf : rtl_state.
  refine {|
    rtl_oracle := empty_oracle;
    rtl_env := empty_env;
    rtl_mach_state := init_full_machine_cf;
    rtl_memory := empty_mem
  |}.
Defined.

Definition gpr (s:@RTL_ans unit * rtl_state) :=
  gp_regs (core (rtl_mach_state (snd s))).

Definition flag (s:@RTL_ans unit * rtl_state) :=
  flags_reg (core (rtl_mach_state (snd s))).

Definition op_override_prefix : prefix := 
  mkPrefix None None true false.

End InitState.

Definition run (eax ebx: int32) (i:instr) :=
  RTL_step_list (instr_to_rtl no_prefix i) 
                (init_rtl_state eax ebx zero zero).

Definition runCX (eax ebx ecx: int32) (i:instr) :=
  RTL_step_list (instr_to_rtl no_prefix i) 
                (init_rtl_state eax ebx ecx zero).

Definition runCX_DX (eax ebx ecx edx: int32) (i:instr) :=
  RTL_step_list (instr_to_rtl no_prefix i) 
                (init_rtl_state eax ebx ecx edx).

Definition runCX_CF (eax ebx ecx: int32) (cf:int1) (i:instr) :=
  RTL_step_list (instr_to_rtl no_prefix i) 
                (init_rtl_state_cf eax ebx ecx zero cf).

Definition runCX_OP (eax ebx ecx: int32) (i:instr) :=
  RTL_step_list (instr_to_rtl op_override_prefix i) 
                (init_rtl_state eax ebx ecx zero).

Definition runCX_DX_OP (eax ebx ecx edx: int32) (i:instr) :=
  RTL_step_list (instr_to_rtl op_override_prefix i) 
                (init_rtl_state eax ebx ecx edx).

Module Test_XOR.

  Definition i:instr := XOR true (Reg_op EAX) (Reg_op EBX).

  (* Compute (instr_to_rtl no_prefix i). *)
  (* Compute (gpr (run one zero zero i) EAX). *)

  (* PF should be zero since (gpr (run one zero zero i) EAX) is 1,
     which has an odd number of bits *)
  Goal (flag (run one zero i) PF) = zero.
  Proof. reflexivity. Qed.

End Test_XOR.

Module Test_Add.

  Definition i1:instr := ADD true (Reg_op EAX) (Reg_op EBX).

  (* ZF should be one, since (gpr  (run one mone zero i) EAX)
     returns zero *)
  Goal (flag (run one mone i1) ZF) = one.
  Proof. reflexivity. Qed.

  Goal (flag (run one mone i1) OF) = zero.
  Proof. reflexivity. Qed.

  Goal (flag (run (repr 2147483648) (repr 2147483648) i1) OF) = one.
  Proof. reflexivity. Qed.

End Test_Add.

Module Test_Adc.

  Definition i:instr := 
    ADC true (Reg_op (EBX)) (Reg_op (ECX)).

  Goal gpr (runCX zero (repr 2146959366) (repr 2148007937) i) EBX = repr 7.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 2146959366) (repr 2148007937) i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 2146959366) (repr 2148007937) i) CF = one.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 7) (repr 2148007937) one i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 67373084) (repr 3756307471) one i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 67373084) (repr 3756307471) one i) CF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 2036070270) (repr 111413377) one i) OF = one.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 2036070270) (repr 111413377) one i) CF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero zero zero one i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero zero zero one i) CF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 4294967295) (repr 4294967295) one i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero (repr 4294967295) (repr 4294967295) one i) CF = one.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero mone mone one i) CF = one.
  Proof. reflexivity. Qed.

End Test_Adc.

Module Test_Sbb.
  Definition i:instr := SBB true (Reg_op (EBX)) (Reg_op (ECX)).

  Goal gpr (runCX zero (repr 2147483712) (repr 2147483648) i) EBX = repr 64.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 2147483712) (repr 2147483648) i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 2147483712) (repr 2147483648) i) CF = zero.
  Proof. reflexivity. Qed.

  Goal (gpr (runCX zero (repr 3221249032) (repr 3221249032) i) EBX)
              = repr 0.
  Proof. reflexivity. Qed.

  Goal (flag (runCX zero (repr 3221249032) (repr 3221249032) i) ZF)
              = repr 1.
  Proof. reflexivity. Qed.

  Goal (flag (runCX zero (repr 3221249032) (repr 3221249032) i) PF)
              = repr 1.
  Proof. reflexivity. Qed.

  Goal (flag (runCX zero (repr 3221249032) (repr 3221249032) i) SF)
              = repr 0.
  Proof. reflexivity. Qed.

  Goal (flag (runCX zero (repr 3221249032) (repr 3221249032) i) CF)
              = repr 0.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 3221249032) (repr 3221249032) i) OF = zero.
  Proof. reflexivity. Qed.

  Goal gpr (runCX zero (repr 519538729) (repr 822083584) i) EBX = 
       repr 3992422441.     
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 519538729) (repr 822083584) i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 519538729) (repr 822083584) i) CF = one.
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 553647924) (repr 2147483648) i) OF = one.
  Proof. reflexivity. Qed.

  Goal gpr (runCX zero (repr 553647924) (repr 2147483648) i) EBX = 
       repr 2701131572.    
  Proof. reflexivity. Qed.

  Goal flag (runCX zero (repr 553647924) (repr 2147483648) i) CF = one.
  Proof. reflexivity. Qed.

  Goal gpr (runCX_CF zero zero (repr 4294967295) one i) EBX = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero zero (repr 4294967295) one i) OF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_CF zero zero (repr 4294967295) one i) CF = one.
  Proof. reflexivity. Qed.

End Test_Sbb.

Module Test_Xadd.
  Definition i:instr := XADD true (Reg_op (EBX)) (Reg_op (ECX)).

  Goal intval 31 (gpr (runCX zero (repr 1608135424) (repr 2759947009) i) EBX)
              = intval 31 (repr 73115137).
  Proof. reflexivity. Qed.

  Goal (flag (runCX zero (repr 1608135424) (repr 2759947009) i) OF)
              = repr 0.
  Proof. reflexivity. Qed.

End Test_Xadd.

Module Test_Mul.
  Definition i:instr := MUL true (Reg_op (EBX)).

  Goal gpr (run (repr 2233468006) (repr 1546826500) i) EDX
       =  (repr 804380396).
  Proof. reflexivity. Qed.

  Goal flag (run (repr 1242038273) (repr 3052929025) i) CF = one.
  Proof. reflexivity. Qed.

End Test_Mul.

Module Test_IMUL.
  Definition i1:instr := IMUL true (Reg_op EBX) None None.

  Goal (gpr (run (repr 633430437) (repr 2147483231) i1) EDX)
               =  (repr 316715156).
  Proof. reflexivity. Qed.

  Goal (flag (run (repr 633430437) (repr 2147483231) i1) CF) = one.
  Proof. reflexivity. Qed.

  Goal flag (run (repr 4294967261) (repr 109051904) i1) CF = one.
  Proof. reflexivity. Qed.

  (* SF is undefined according to manual *)
  (* Goal (flag (run (repr 633430437) (repr 2147483231) zero i) SF) *)
  (*              =  (repr 1). *)
  (* Proof. reflexivity. Qed. *)

  Definition i2: instr := 
    IMUL true (Reg_op ECX) (Some (Reg_op EBX)) (Some (repr 65504)).

  Goal (flag (runCX_OP zero (repr 1024) zero i2) CF) = zero.
  Proof. reflexivity. Qed.
  
  Goal (flag (runCX_OP zero (repr 1024) zero i2) OF) = zero.
  Proof. reflexivity. Qed.

  Goal (gpr (runCX_OP zero (repr 1024) zero i2) ECX) = repr 32768.
  Proof. reflexivity. Qed.

End Test_IMUL.

Module Test_Sub.

  Definition i:instr := SUB true (Reg_op EAX) (Reg_op EBX).

  Goal (flag (run (repr 2147483645) (repr 2147483648) i) OF = one).
  Proof. reflexivity. Qed.

  Goal (flag (run (repr 2684354560) (repr 2147483648) i) OF = zero).
  Proof. reflexivity. Qed.

End Test_Sub.

Module Test_Cmp.

  Definition i:instr := CMP true (Reg_op EBX) (Reg_op ECX).

  Goal (flag (runCX zero zero (repr 2147483648) i) OF = one).
  Proof. reflexivity. Qed.

End Test_Cmp.

Module Test_Neg.

  Definition i:instr := NEG true (Reg_op EBX).

  Goal flag (run zero (repr 2147483648) i) OF = one.
  Proof. reflexivity. Qed.

End Test_Neg.

Module Test_BSF.

  Definition i:instr := BSF (Reg_op EBX) (Reg_op ECX).

  Goal gpr (runCX_OP zero (repr 4294901760) (repr 2164260896) i) EBX = 
       repr 4294901765.
  Proof. reflexivity. Qed.

  Goal flag (runCX_OP zero (repr 4294901760) (repr 2164260896) i) ZF = zero.
  Proof. reflexivity. Qed.

  Goal flag (runCX_OP zero zero (repr 4294901760) i) ZF = one.
  Proof. reflexivity. Qed.

End Test_BSF.

Module Test_MOVSX.

  Definition i1:instr := MOVSX false (Reg_op EBX) (Reg_op ECX).

  Goal gpr (runCX_OP zero zero (repr 128) i1) EBX = repr 65408.
  Proof. reflexivity. Qed.

  Definition i2:instr := MOVSX false (Reg_op EBX) (Reg_op ECX).

  Goal intval 31 (gpr (runCX zero zero (repr 128) i1) EBX) = 
       intval 31 (repr 4294967168).
  Proof. reflexivity. Qed.

  (* with op_override on: movsbw %bl, %bx is 8 bit to 16 bit move *)
  Definition i3:instr := MOVSX false (Reg_op EBX) (Reg_op EBX).

  (* Compute (instr_to_rtl op_override_prefix i3). *)

  (* Compute (gpr (run one zero zero i) EAX). *)
  Goal (gpr (runCX_OP zero (repr 128) zero i3) EBX) = repr 65408.
  Proof. reflexivity. Qed.
      
End Test_MOVSX.

Module Test_SHLD.

  Definition i1:instr := SHLD (Reg_op EBX) EDX (Reg_ri ECX).

  Goal gpr (runCX_DX_OP zero (repr 384) (repr 72) (repr 33282) i1) EBX = 
       repr 32898.
  Proof. reflexivity. Qed.

  Goal gpr (runCX zero (repr 2147483648) (repr 32) i1) EBX = 
       repr 2147483648.
  Proof. reflexivity. Qed.

  Definition i2:instr := SHLD (Reg_op EBX) ECX (Imm_ri (repr 42)).

  Goal gpr (runCX_OP zero (repr 63) (repr 57344) i2) EBX = 
       repr 65408.
  Proof. reflexivity. Qed.

End Test_SHLD.

Module Test_SHRD.

  Definition i1:instr := SHRD (Reg_op EBX) EDX (Reg_ri ECX).

  Goal gpr (runCX_DX_OP zero (repr 33152) (repr 8) (repr 40961) i1) EBX = 
       repr 385.
  Proof. reflexivity. Qed.

End Test_SHRD.
