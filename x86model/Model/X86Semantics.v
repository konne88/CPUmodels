(* Copyright (c) 2011. Greg Morrisett, Gang Tan, Joseph Tassarotti, 
   Jean-Baptiste Tristan, and Edward Gan.

   This file is part of RockSalt.

   This file is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of
   the License, or (at your option) any later version.
*)

Require Import Coq.Strings.String.
Require Import Coq.Program.Program.
Require Import X86Model.Parser.
Require X86Model.Decode.
Require Import X86Model.Monad.
Require Import X86Model.Maps.
Require Export X86Syntax.
Require Export RTL.

Set Implicit Arguments.
Unset Automatic Introduction.

Module X86_MACHINE.
  Local Open Scope Z_scope.
  Local Open Scope string_scope.

  Definition size_addr := size32.  
  Inductive flag : Set := ID | VIP | VIF | AC | VM | RF | NT | IOPL | OF | DF 
  | IF_flag | TF | SF | ZF | AF | PF | CF.

  Definition flag_eq_dec : forall(f1 f2:flag), {f1=f2}+{f1<>f2}.
    intros ; decide equality. Defined.

  Inductive fpu_flag : Set := F_Busy | F_C3 | F_C2 | F_C1 | F_C0
  | F_ES | F_SF | F_PE | F_UE | F_OE | F_ZE | F_DE | F_IE.

  Inductive fpu_ctrl_flag : Set :=
    F_Res15 | F_Res14 | F_Res13 | F_Res7 | F_Res6
  | F_IC | F_PM | F_UM | F_OM | F_ZM | F_DM | F_IM.

  Definition size11 := 10%nat.
  Definition size48 := 47%nat.
  Definition int48 := Word.int size48.

  Inductive loc : nat -> Set := 
  | reg_loc : register -> loc size32
  | seg_reg_start_loc : segment_register -> loc size32
  | seg_reg_limit_loc : segment_register -> loc size32
  | flag_loc : flag -> loc size1
  | control_register_loc : control_register -> loc size32
  | debug_register_loc : debug_register -> loc size32
  | pc_loc : loc size32
  (* Locations for FPU *)
  | fpu_stktop_loc : loc size3  (* the stack top location *)
  | fpu_flag_loc : fpu_flag -> loc size1 
  | fpu_rctrl_loc : loc size2 (* rounding control *)
  | fpu_pctrl_loc : loc size2 (* precision control *)
  | fpu_ctrl_flag_loc : fpu_ctrl_flag -> loc size1
  | fpu_lastInstrPtr_loc : loc size48
  | fpu_lastDataPtr_loc : loc size48
  | fpu_lastOpcode_loc : loc size11.

  Definition location := loc.

  Inductive arr : nat -> nat -> Set :=
  | fpu_datareg: arr size3 size80
  | fpu_tag : arr size3 size2.

  Definition array := arr.

  Definition fmap (A B:Type) := A -> B.
  Definition upd A (eq_dec:forall (x y:A),{x=y}+{x<>y}) B (f:fmap A B) (x:A) (v:B) : 
    fmap A B := fun y => if eq_dec x y then v else f y.
  Definition look A B (f:fmap A B) (x:A) : B := f x.

  Record core_state := {
    gp_regs : fmap register int32 ;
    seg_regs_starts : fmap segment_register int32 ; 
    seg_regs_limits : fmap segment_register int32 ; 
    flags_reg : fmap flag int1 ; 
    control_regs : fmap control_register int32 ; 
    debug_regs : fmap debug_register int32 ; 
    pc_reg : int size32 
  }.

  (* FPU status word format:
     bits  15   14   13   12   11   10   9   8   7   6   5   4   3   2   1   0
           Busy C3   Top  Top  Top  C2   C1  C0  ES  SF  PE  UE  OE  ZE  DE IE       
      
           C0-C3: condition codes
           ES: error summary
           SF: stack fault
           PE-IE: exception flags
     *)

  (* FPU contorl word format:
     bits  15   14   13   12   11   10   9   8   7   6   5   4   3   2   1   0
           Res  Res  Res  IC   RC   RC   PC  PC  Res Res PM  UM  OM  ZM  DM  IM
      
           IC: infinity control 
           RC: round control
           PC: Precision control
     *)

  Record fpu_state := {
    fpu_data_regs : fmap int3 int80 ; (* 8 80-bit registers shared between FPU and MMX *)
    fpu_status : int16 ; (* 16-bit status word; contains stack top and other flag bits *)
    fpu_control : int16 ; (* 16-bit control word; contrains rounding control, precision
                             control and other control flags*)
    fpu_tags : fmap int3 int2;
    fpu_lastInstrPtr : int48;
    fpu_lastDataPtr : int48;
    fpu_lastOpcode : int size11  (* 11 bits for the last opcode *)
  }.

  Record mach := { 
    core : core_state;
    fpu : fpu_state
  }.

  Definition mach_state := mach.

  (* get the bits between n and m *)
  Definition get_bits_rng s (i: int s) (n m: nat) : int (m-n) :=
    Word.repr (Word.unsigned (Word.shru i (Word.repr (Z_of_nat n)))).

  (* set the bits between n and m *)
  Definition set_bits_rng s (i: int s) (n m: nat) (v:int (m-n)) : int s :=
    let highbits := Word.unsigned (Word.shru i (Word.repr (Z_of_nat m + 1))) in
    let lowbits := Zmod (Word.unsigned i) (two_power_nat n) in 
      Word.repr 
      (lowbits + (Word.unsigned v) * (two_power_nat n) + highbits * (two_power_nat (m + 1))).

  (* return the nth bit in bitvector i *)
  Definition get_bit s (i:int s) n : int1 := 
    let wordsize := S s in
    if Word.bits_of_Z wordsize (Word.unsigned i) n
      then Word.one
      else Word.zero.

  (* set the nth bit in a bitvector *)
  Definition set_bit s (i:int s) (n:nat) (v:bool) : int s :=
    set_bits_rng i n n (Word.bool_to_int v).

  (* some testing of get_bits_rng and set_bits_rng *)
  (* Definition x := (Zpos 1~1~1~1~1~1~0~1~0~1~0~0~0~1~0~1). *)
  (* Eval compute in (get_bits_rng (@Word.repr size16 x) 2 5). *)
  (* Eval compute in (set_bits_rng (@Word.repr size16 x) 1 1 (Word.repr 1)). *)

  Definition get_fpu_flag_reg (f:fpu_flag) (fs:fpu_state) : int1 :=
    match f with
      | F_Busy => get_bit (fpu_status fs) 15
      | F_C3 => get_bit (fpu_status fs) 14
      | F_C2 => get_bit (fpu_status fs) 10
      | F_C1 => get_bit (fpu_status fs) 9
      | F_C0 => get_bit (fpu_status fs) 8
      | F_ES => get_bit (fpu_status fs) 7
      | F_SF => get_bit (fpu_status fs) 6
      | F_PE => get_bit (fpu_status fs) 5
      | F_UE => get_bit (fpu_status fs) 4
      | F_OE => get_bit (fpu_status fs) 3
      | F_ZE => get_bit (fpu_status fs) 2
      | F_DE => get_bit (fpu_status fs) 1
      | F_IE => get_bit (fpu_status fs) 0
    end.

  (* stack top is bits 11 to 13 in the 16-bit status register *)
  Definition get_stktop_reg (fs:fpu_state) : int3 :=
    get_bits_rng (fpu_status fs) 11 13.

  Definition get_fpu_ctrl_flag_reg (f:fpu_ctrl_flag) (fs:fpu_state) : int1 := 
    match f with
      | F_Res15 => get_bit (fpu_control fs) 15
      | F_Res14 => get_bit (fpu_control fs) 14
      | F_Res13 => get_bit (fpu_control fs) 13
      | F_IC => get_bit (fpu_control fs) 12
      | F_Res7 => get_bit (fpu_control fs) 7
      | F_Res6 => get_bit (fpu_control fs) 6
      | F_PM => get_bit (fpu_control fs) 5
      | F_UM => get_bit (fpu_control fs) 4
      | F_OM => get_bit (fpu_control fs) 3
      | F_ZM => get_bit (fpu_control fs) 2
      | F_DM => get_bit (fpu_control fs) 1
      | F_IM => get_bit (fpu_control fs) 0
    end.

  (* rounding control is bits 10 to 11 in the control register *)
  Definition get_rctrl_reg (fs:fpu_state) : int2 :=
    get_bits_rng (fpu_control fs) 10 11.

  (* precision control is bits 8 to 9 in the control register *)
  Definition get_pctrl_reg (fs:fpu_state) : int2 :=
    get_bits_rng (fpu_control fs) 8 9.

  Definition get_location s (l:loc s) (m:mach_state) : int s := 
    match l in loc s' return int s' with 
      | reg_loc r => look (gp_regs (core m)) r
      | seg_reg_start_loc r => look (seg_regs_starts (core m)) r
      | seg_reg_limit_loc r => look (seg_regs_limits (core m)) r
      | flag_loc f => look (flags_reg (core m)) f
      | control_register_loc r => look (control_regs (core m)) r
      | debug_register_loc r => look (debug_regs (core m)) r
      | pc_loc => pc_reg (core m)
      | fpu_stktop_loc => get_stktop_reg (fpu m)
      | fpu_flag_loc f => get_fpu_flag_reg f (fpu m)
      | fpu_rctrl_loc => get_rctrl_reg (fpu m)
      | fpu_pctrl_loc => get_rctrl_reg (fpu m)
      | fpu_ctrl_flag_loc f => get_fpu_ctrl_flag_reg f (fpu m)
      | fpu_lastInstrPtr_loc => fpu_lastInstrPtr (fpu m)
      | fpu_lastDataPtr_loc => fpu_lastDataPtr (fpu m)
      | fpu_lastOpcode_loc => fpu_lastOpcode (fpu m)
    end.

  Definition set_gp_reg r v m := 
    {| core := 
       {| gp_regs := upd register_eq_dec (gp_regs (core m)) r v ; 
         seg_regs_starts := seg_regs_starts (core m) ; 
         seg_regs_limits := seg_regs_limits (core m) ;
         flags_reg := flags_reg (core m) ;
         control_regs := control_regs (core m); 
         debug_regs := debug_regs (core m); 
         pc_reg := pc_reg (core m)
       |};
       fpu := fpu m
    |}.

  Definition set_seg_reg_start r v m := 
    {| core := 
       {| gp_regs := gp_regs (core m) ;
         seg_regs_starts := upd segment_register_eq_dec (seg_regs_starts (core m)) r v ; 
         seg_regs_limits := seg_regs_limits (core m) ;
         flags_reg := flags_reg (core m) ;
         control_regs := control_regs (core m); 
         debug_regs := debug_regs (core m); 
         pc_reg := pc_reg (core m) 
       |};
       fpu := fpu m
    |}.

  Definition set_seg_reg_limit r v m := 
    {| core := 
       {| gp_regs := gp_regs (core m) ;
         seg_regs_starts := seg_regs_starts (core m) ;
         seg_regs_limits := upd segment_register_eq_dec (seg_regs_limits (core m)) r v ; 
         flags_reg := flags_reg (core m) ;
         control_regs := control_regs (core m); 
         debug_regs := debug_regs (core m); 
         pc_reg := pc_reg (core m) 
       |};
       fpu := fpu m
    |}.

  Definition set_flags_reg r v m := 
    {| core := 
      {| gp_regs := gp_regs (core m) ;
        seg_regs_starts := seg_regs_starts (core m) ;
        seg_regs_limits := seg_regs_limits (core m) ;
        flags_reg := upd flag_eq_dec (flags_reg (core m)) r v ;
        control_regs := control_regs (core m); 
        debug_regs := debug_regs (core m); 
        pc_reg := pc_reg (core m)
      |};
      fpu := fpu m
    |}.

  Definition set_control_reg r v m := 
    {| core := 
      {| gp_regs := gp_regs (core m) ;
        seg_regs_starts := seg_regs_starts (core m) ;
        seg_regs_limits := seg_regs_limits (core m) ;
        flags_reg := flags_reg (core m) ; 
        control_regs := upd control_register_eq_dec (control_regs (core m)) r v ;
        debug_regs := debug_regs (core m); 
        pc_reg := pc_reg (core m)
      |};
      fpu := fpu m
    |}.

  Definition set_debug_reg r v m := 
    {| core := 
      {| gp_regs := gp_regs (core m) ;
        seg_regs_starts := seg_regs_starts (core m) ;
        seg_regs_limits := seg_regs_limits (core m) ;
        flags_reg := flags_reg (core m) ; 
        control_regs := control_regs (core m) ;
        debug_regs := upd debug_register_eq_dec (debug_regs (core m)) r v ;
        pc_reg := pc_reg (core m) 
      |};
      fpu := fpu m
    |}.

  Definition set_pc v m := 
    {| core := 
      {| gp_regs := gp_regs (core m) ;
        seg_regs_starts := seg_regs_starts (core m) ;
        seg_regs_limits := seg_regs_limits (core m) ;
        flags_reg := flags_reg (core m) ; 
        control_regs := control_regs (core m) ;
        debug_regs := debug_regs (core m) ; 
        pc_reg := v
      |};
      fpu := fpu m
    |}.

  Definition set_fpu_stktop_reg (v:int3) m := 
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := set_bits_rng (fpu_status (fpu m)) 11 13 v ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.

  Definition set_fpu_flags_reg (f:fpu_flag) (v:int1) m := 
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := 
           let old_status := fpu_status (fpu m) in
           let b : bool := negb (Word.eq v Word.zero) in
             match f with
               | F_Busy => set_bit old_status 15 b
               | F_C3 => set_bit old_status 14 b
               | F_C2 => set_bit old_status 10 b
               | F_C1 => set_bit old_status 9 b
               | F_C0 => set_bit old_status 8 b
               | F_ES => set_bit old_status 7 b
               | F_SF => set_bit old_status 6 b
               | F_PE => set_bit old_status 5 b
               | F_UE => set_bit old_status 4 b
               | F_OE => set_bit old_status 3 b
               | F_ZE => set_bit old_status 2 b
               | F_DE => set_bit old_status 1 b
               | F_IE => set_bit old_status 0 b
             end;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.

  Definition set_fpu_rctrl_reg (v:int2) m := 
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := set_bits_rng (fpu_control (fpu m)) 10 11 v ;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.
  
  Definition set_fpu_pctrl_reg (v:int2) m := 
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := set_bits_rng (fpu_control (fpu m)) 8 9 v ;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.

  Definition set_fpu_ctrl_reg (f:fpu_ctrl_flag) (v:int1) m :=
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := 
           let old_ctrl := fpu_control (fpu m) in
           let b : bool := negb (Word.eq v Word.zero) in
             match f with
               | F_Res15 => set_bit old_ctrl 15 b
               | F_Res14 => set_bit old_ctrl 14 b
               | F_Res13 => set_bit old_ctrl 13 b
               | F_IC => set_bit old_ctrl 12 b
               | F_Res7 => set_bit old_ctrl 7 b
               | F_Res6 => set_bit old_ctrl 6 b
               | F_PM => set_bit old_ctrl 5 b
               | F_UM => set_bit old_ctrl 4 b
               | F_OM => set_bit old_ctrl 3 b
               | F_ZM => set_bit old_ctrl 2 b
               | F_DM => set_bit old_ctrl 1 b
               | F_IM => set_bit old_ctrl 0 b
             end;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.

  Definition set_fpu_lastInstrPtr_reg v m :=
   {|  core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m);
         fpu_lastInstrPtr := v;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
    |}.

  Definition set_fpu_lastDataPtr_reg v m :=
   {|  core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m);
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m);
         fpu_lastDataPtr := v ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
    |}.

  Definition set_lastOpcode_reg v m:=
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m);
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m);
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := v
       |}
  |}.

  Definition set_location s (l:loc s) (v:int s) m := 
    match l in loc s' return int s' -> mach_state with 
      | reg_loc r => fun v => set_gp_reg r v m
      | seg_reg_start_loc r => fun v => set_seg_reg_start r v m
      | seg_reg_limit_loc r => fun v => set_seg_reg_limit r v m
      | flag_loc f => fun v => set_flags_reg f v m
      | control_register_loc r => fun v => set_control_reg r v m
      | debug_register_loc r => fun v => set_debug_reg r v m
      | pc_loc => fun v => set_pc v m
      | fpu_stktop_loc => fun v => set_fpu_stktop_reg v m
      | fpu_flag_loc f => fun v => set_fpu_flags_reg f v m
      | fpu_rctrl_loc => fun v => set_fpu_rctrl_reg v m
      | fpu_pctrl_loc => fun v => set_fpu_pctrl_reg v m
      | fpu_ctrl_flag_loc f => fun v => set_fpu_ctrl_reg f v m
      | fpu_lastInstrPtr_loc => fun v => set_fpu_lastInstrPtr_reg v m 
      | fpu_lastDataPtr_loc => fun v => set_fpu_lastDataPtr_reg v m 
      | fpu_lastOpcode => fun v => set_lastOpcode_reg v m
    end v.


  Definition array_sub l s (a:array l s) :=
    match a in arr l' s' return int l' -> mach_state -> int s' with
      | fpu_datareg => fun i m => look (fpu_data_regs (fpu m)) i
      | fpu_tag => fun i m => look (fpu_tags (fpu m)) i
    end.


  Definition set_fpu_datareg (r:int3) (v:int80) m := 
    {| core := core m ;
       fpu := {|
         fpu_data_regs := upd (@Word.eq_dec size3) (fpu_data_regs (fpu m)) r v ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := fpu_tags (fpu m) ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
    |}.

  Definition set_fpu_tags_reg r v m:=
  {|   core := core m ;
       fpu := {|
         fpu_data_regs := fpu_data_regs (fpu m) ;
         fpu_status := fpu_status (fpu m) ;
         fpu_control := fpu_control (fpu m) ;
         fpu_tags := upd (@Word.eq_dec size3) (fpu_tags (fpu m)) r v ;
         fpu_lastInstrPtr := fpu_lastInstrPtr (fpu m) ;
         fpu_lastDataPtr := fpu_lastDataPtr (fpu m) ;
         fpu_lastOpcode := fpu_lastOpcode (fpu m)
       |}
  |}.

  Definition array_upd l s (a:array l s) (i:int l) (v:int s) m :=
    match a in arr l' s' return int l' -> int s' -> mach_state with
      | fpu_datareg => fun i v => set_fpu_datareg i v m
      | fpu_tag => fun i v => set_fpu_tags_reg i v m
    end i v.

End X86_MACHINE.

Module X86_RTL := RTL.RTL(X86_MACHINE).

(* compilation from x86 instructions to RTL instructions *)
Module X86_Compile.
  Import X86_MACHINE.
  Import X86_RTL.
  Local Open Scope monad_scope.

  (** c_rev_i is the list of rtl instructions generated in reverse;
      c_next is the index of the next pseudo reg. *)
  Record conv_state := { c_rev_i : list rtl_instr ; c_next : Z }.
  Definition Conv(T:Type) := conv_state -> T * conv_state.
  Instance Conv_monad : Monad Conv := {
    Return := fun A (x:A) (s:conv_state) => (x,s) ; 
    Bind := fun A B (c:Conv A) (f:A -> Conv B) (s:conv_state) => 
      let (v,s') := c s in f v s'
  }.
  intros ; apply Coqlib.extensionality ; auto.
  intros ; apply Coqlib.extensionality ; intros. destruct (c x). auto.
  intros ; apply Coqlib.extensionality ; intros. destruct (f x) ; auto. 
  Defined.
  Definition runConv (c:Conv unit) : (list rtl_instr) :=
    match c {|c_rev_i := nil ; c_next:=0|} with
      | (_, c') => (List.rev (c_rev_i c'))
    end.
  Definition EMIT(i:rtl_instr) : Conv unit :=
    fun s => (tt,{|c_rev_i := i::(c_rev_i s) ; c_next := c_next s|}).
  Notation "'emit' i" := (EMIT i) (at level 75) : monad_scope.
  
  (* Begin: a set of basic conversion constructs *)
  Definition raise_error := emit error_rtl.
  Definition raise_trap := emit trap_rtl.
  Definition no_op := ret tt.
  (* Definition ret_exp s (e:rtl_exp s) := ret e. *)
  Definition load_int s (i:int s) := ret (imm_rtl_exp i).
  Definition arith s b (e1 e2:rtl_exp s) := ret (arith_rtl_exp b e1 e2).
  Definition test s t (e1 e2:rtl_exp s) := ret (test_rtl_exp t e1 e2).
  Definition cast_u s1 s2 (e:rtl_exp s1) := ret (@cast_u_rtl_exp s1 s2 e).
  Definition cast_s s1 s2 (e:rtl_exp s1) := ret (@cast_s_rtl_exp s1 s2 e).
  Definition read_loc s (l:loc s) := ret (get_loc_rtl_exp l).
  Definition write_loc s (e:rtl_exp s) (l:loc s)  := emit set_loc_rtl e l.

  (* Definition write_current_ps s (e: rtl_exp s) : Conv unit := *)
  (*   fun ts =>  *)
  (*     let r := c_next ts in *)
  (*     let ts' := {|c_rev_i := (set_ps_reg_rtl e (ps_reg s r))::c_rev_i ts; *)
  (*                  c_next := r|} in *)
  (*     ((), ts'). *)

  (* store the value of e into the current pseudo reg and advance the
     index of the pseudo reg; it returns an rtl_exp that retrives the
     value from the storage; *)
  Definition write_ps_and_fresh s (e: rtl_exp s) : Conv (rtl_exp s) :=
    fun ts => 
      let r := c_next ts in
      let ts' := {|c_rev_i := (set_ps_reg_rtl e (ps_reg s r))::c_rev_i ts;
                   c_next := r + 1|} in
      (get_ps_reg_rtl_exp (ps_reg s r), ts').

  (* Definition read_ps s (ps:pseudo_reg s): Conv (rtl_exp s) :=  *)
  (*   ret (get_ps_reg_rtl_exp ps). *)

  Definition read_array l s (a:array l s) (idx:rtl_exp l) := 
    ret (get_array_rtl_exp a idx).
  Definition write_array l s (a:array l s) (idx:rtl_exp l) (v:rtl_exp s) :=
    emit set_array_rtl a idx v.

  Definition read_byte (a:rtl_exp size32) := ret (get_byte_rtl_exp a).
  Definition write_byte (v:rtl_exp size8) (a:rtl_exp size32) := 
    emit set_byte_rtl v a.
  Definition if_exp s g (e1 e2:rtl_exp s) : Conv (rtl_exp s) :=
    ret (if_rtl_exp g e1 e2).
  Definition if_trap g : Conv unit := emit (if_rtl g trap_rtl).
  Definition if_set_loc cond s (e:rtl_exp s) (l:location s) :=
    emit (if_rtl cond (set_loc_rtl e l)).
  Definition choose s : Conv (rtl_exp s) := 
    emit (advance_oracle_rtl);;
    ret (@get_random_rtl_exp s).

  Definition fcast ew1 mw1 ew2 mw2
    (hyp1: valid_float ew1 mw1)
    (hyp2: valid_float ew2 mw2)
    (rm: rtl_exp size2)
    (e : rtl_exp (nat_of_P ew1 + nat_of_P mw1))
    : Conv (rtl_exp  (nat_of_P ew2 + nat_of_P mw2)) :=
    ret (@fcast_rtl_exp ew1 mw1 ew2 mw2 hyp1 hyp2 rm e).

  Lemma fw_hyp_float32 : valid_float 8 23.
  Proof. unfold valid_float. split; reflexivity. Qed.
  Lemma fw_hyp_float64 : valid_float 11 52.
  Proof. unfold valid_float. split; reflexivity. Qed.
  Lemma fw_hyp_float79 : valid_float 15 63.
  Proof. unfold valid_float. split; reflexivity. Qed.
  
  Definition farith_float79 (op: float_arith_op) (rm:rtl_exp size2)
    (e1 e2: rtl_exp size79) := 
    ret (farith_rtl_exp fw_hyp_float79 op rm e1 e2).
  (* End: a set of basic conversion constructs.
     All conversions afterwards should be defined based on the constructs
     provided above. *)

  Definition load_Z s (z:Z) := load_int (@Word.repr s z).

  Definition load_reg (r:register) := read_loc (reg_loc r).
  Definition set_reg (p:rtl_exp size32) (r:register) := 
    write_loc p (reg_loc r).

  Definition get_seg_start (s:segment_register) := 
    read_loc (seg_reg_start_loc s).
  Definition get_seg_limit (s:segment_register) := 
    read_loc (seg_reg_limit_loc s).

  Definition get_flag fl := read_loc (flag_loc fl).
  Definition set_flag fl (r: rtl_exp size1) := 
    write_loc r (flag_loc fl).

  Definition get_pc := read_loc pc_loc.
  Definition set_pc v := write_loc v pc_loc.

  Definition not {s} (p: rtl_exp s) : Conv (rtl_exp s) :=
    mask <- load_Z s (Word.max_unsigned s);
    arith xor_op p mask.

  Definition test_lte s (e1 e2: rtl_exp s): Conv (rtl_exp size1) :=
    test1 <- test ltu_op e1 e2;
    test2 <- test eq_op e1 e2;
    arith or_op test1 test2.

  Definition test_neq s (e1 e2: rtl_exp s): Conv (rtl_exp size1) :=
    test_eq <- test eq_op e1 e2;
    not test_eq.

  Definition undef_flag (f: flag) :=
    v <- @choose size1; set_flag f v.

  (* get the first s1+1 bits from a bitvector of length s2+1;
     note the length of bits in "rtl_exp s1" is really s1+1. *)
  Definition first_bits s1 s2 (x: rtl_exp s2) : Conv (rtl_exp s1) :=
    c <- load_Z _ (Z_of_nat (s2 - s1));
    r <- arith shru_op x c;
    cast_u s1 r.

  (* get the last s2+1 bits from a bitvector of length s2+1 *)
  Definition last_bits s1 s2 (x: rtl_exp s2) : Conv (rtl_exp s1) :=
    c <- load_Z _ (two_power_nat (s1 + 1));
    r <- arith modu_op x c;
    cast_u s1 r.

  (* concatenate a bitvector of length s1+1 and a bitvector of
     length s2+1 to a bit vector of length s1+s2+2. *)
  Definition concat_bits s1 s2 (x: rtl_exp s1) (y: rtl_exp s2) :
    Conv (rtl_exp (s1 + s2 + 1)) := 
    x' <- cast_u (s1+s2+1) x;
    c <- load_Z _ (Z_of_nat (s2+1));
    raised_x <- arith shl_op x' c;
    y' <- cast_u (s1+s2+1) y;
    arith add_op raised_x y'.

  Definition scale_to_int32 (s:scale) : int32 :=
    Word.repr match s with | Scale1 => 1 | Scale2 => 2 | Scale4 => 4 | Scale8 => 8 end.

  (* compute an effective address *)
  Definition compute_addr(a:address) : Conv (rtl_exp size32) := 
    let disp := addrDisp a in 
      match addrBase a, addrIndex a with 
        | None, None => load_int disp 
        | Some r, None => 
          p1 <- load_reg r ; p2 <- load_int disp ; arith add_op p1 p2
        | Some r1, Some (s, r2) =>
          b <- load_reg r1;
          i <- load_reg r2;
          s <- load_int (scale_to_int32 s);
          p0 <- arith mul_op i s;
          p1 <- arith add_op b p0;
          disp <- load_int disp;
          arith add_op p1 disp
        | None, Some (s, r) => 
          i <- load_reg r;
          s <- load_int (scale_to_int32 s);
          disp <- load_int disp;
          p0 <- arith mul_op i s;
          arith add_op disp p0
      end.

  (* check that the addr is not greater the segment_limit, and then 
     add the specified segment base *)
  Definition add_and_check_segment (seg:segment_register) (a:rtl_exp size32) : 
    Conv (rtl_exp size32) := 
    start <- get_seg_start seg ; 
    limit <- get_seg_limit seg ;
    guard <- test ltu_op limit a;
    if_trap guard;;
    arith add_op start a.

  (* load a byte from memory, taking into account the specified segment *)
  Definition lmem (seg:segment_register) (a:rtl_exp size32) : Conv (rtl_exp size8):=
    p <- add_and_check_segment seg a ; 
    read_byte p.

  (* store a byte to memory, taking into account the specified segment *)
  Definition smem (seg:segment_register) (v:rtl_exp size8) (a:rtl_exp size32) :
    Conv unit := 
    p <- add_and_check_segment seg a ; 
    write_byte v p.

  (** load an n-byte vector from memory -- takes into account the segment;
     sz is the size of the final expression. *)
  Fixpoint load_mem_n (seg:segment_register) (addr:rtl_exp size32) (sz:nat)
    (nbytes_minus_one:nat) : Conv (rtl_exp sz) :=
    match nbytes_minus_one with
      | 0 => 
        b <- lmem seg addr;
        cast_u sz b
      | S n =>
        b0 <- lmem seg addr;
        b0' <- cast_u sz b0;
        one <- load_Z size32 1;
        newaddr <- arith add_op addr one;
        rec <- load_mem_n seg newaddr sz n;
        eight <- load_Z sz 8;
        rec' <- arith shl_op rec eight;
        arith or_op b0' rec'
    end.

  (* Definition load_mem32 (seg: segment_register) (addr: rtl_exp size32) := *)
  (*   b0 <- lmem seg addr; *)
  (*   one <- load_Z size32 1; *)
  (*   addr1 <- arith add_op addr one; *)
  (*   b1 <- lmem seg addr1; *)
  (*   addr2 <- arith add_op addr1 one; *)
  (*   b2 <- lmem seg addr2; *)
  (*   addr3 <- arith add_op addr2 one; *)
  (*   b3 <- lmem seg addr3; *)

  (*   w0 <- cast_u size32 b0; *)
  (*   w1 <- cast_u size32 b1; *)
  (*   w2 <- cast_u size32 b2; *)
  (*   w3 <- cast_u size32 b3; *)
  (*   eight <- load_Z size32 8; *)
  (*   r0 <- arith shl_op w3 eight; *)
  (*   r1 <- arith or_op r0 w2; *)
  (*   r2 <- arith shl_op r1 eight; *)
  (*   r3 <- arith or_op r2 w1; *)
  (*   r4 <- arith shl_op r3 eight; *)
  (*   arith or_op r4 w0. *)

  Definition load_mem80 (seg : segment_register)(addr:rtl_exp size32) := 
    load_mem_n seg addr size80 9.

  Definition load_mem64 (seg : segment_register) (addr: rtl_exp size32) := 
    load_mem_n seg addr size64 7.

  Definition load_mem32 (seg:segment_register) (addr:rtl_exp size32) := 
    load_mem_n seg addr size32 3.

  Definition load_mem16 (seg:segment_register) (addr:rtl_exp size32) := 
    load_mem_n seg addr size16 1.

  Definition load_mem8 (seg:segment_register) (addr:rtl_exp size32) := 
    load_mem_n seg addr size8 0.

  (* given a prefix and w bit, return the size of the operand *)
  Definition opsize override w :=
    match override, w with
      | _, false => size8
      | true, _ => size16
      | _,_ => size32
    end.

  Definition load_mem p w (seg:segment_register) (op:rtl_exp size32) : 
    Conv (rtl_exp (opsize (op_override p) w)) :=
    match (op_override p) as b,w return
      Conv (rtl_exp (opsize b w)) with
      | true, true => load_mem16 seg op
      | true, false => load_mem8 seg op
      | false, true => load_mem32 seg op
      | false, false => load_mem8 seg op
    end.

  Definition iload_op32 (seg:segment_register) (op:operand) : Conv (rtl_exp size32) :=
    match op with 
      | Imm_op i => load_int i
      | Reg_op r => load_reg r
      | Address_op a => p1 <- compute_addr a ; load_mem32 seg p1
      | Offset_op off => p1 <- load_int off;
                          load_mem32 seg p1
    end.

  Definition iload_op16 (seg:segment_register) (op:operand) : Conv (rtl_exp size16) :=
    match op with 
      | Imm_op i => tmp <- load_int i;
                    cast_u size16 tmp
      | Reg_op r => tmp <- load_reg r;
                    cast_u size16 tmp
      | Address_op a => p1 <- compute_addr a ; load_mem16 seg p1
      | Offset_op off => p1 <- load_int off;
                          load_mem16 seg p1
    end.

  (* This is a little strange because actually for example, ESP here should refer
     to AH, EBP to CH, ESI to DH, and EDI to BH *) 

  Definition iload_op8 (seg:segment_register) (op:operand) : Conv (rtl_exp size8) :=
    match op with 
      | Imm_op i => tmp <- load_int i;
                    cast_u size8 tmp
      | Reg_op r =>
         tmp <- load_reg (match r with
                            | EAX => EAX
                            | ECX => ECX
                            | EDX => EDX
                            | EBX => EBX
                            | ESP => EAX
                            | EBP => ECX
                            | ESI => EDX
                            | EDI => EBX
                          end);
         (match r with
            | EAX | ECX | EDX | EBX => cast_u size8 tmp
            | _ =>  eight <- load_Z size32 8;
                    tmp2 <- arith shru_op tmp eight;
                    cast_u size8 tmp2
          end)
      | Address_op a => p1 <- compute_addr a ; load_mem8 seg p1
      | Offset_op off =>  p1 <- load_int off;
                          load_mem8 seg p1
    end.

  (* set memory with an n-byte vector *)
  Fixpoint set_mem_n (seg:segment_register) (addr:rtl_exp size32)
    sz (v: rtl_exp sz) (nbytes_minus_one:nat) : Conv unit := 
    match nbytes_minus_one with 
      | 0 => 
        b0 <- cast_u size8 v;
        smem seg b0 addr
      | S n => 
        b0 <- cast_u size8 v;
        smem seg b0 addr;;
        one <- load_Z size32 1;
        newaddr <- arith add_op addr one;
        eight <- load_Z sz 8;
        newv <- arith shru_op v eight;
        set_mem_n seg newaddr newv n
    end.

  Definition set_mem80 (seg: segment_register) (v: rtl_exp size80) (a: rtl_exp size32) :
    Conv unit :=
    @set_mem_n seg a size80 v 9. 

  Definition set_mem64 (seg : segment_register) (v: rtl_exp size64) (a: rtl_exp size32) :
    Conv unit := 
    @set_mem_n seg a size64 v 7.

  Definition set_mem32 (seg:segment_register) (v a:rtl_exp size32) : Conv unit :=
    @set_mem_n seg a size32 v 3.

  Definition set_mem16 (seg:segment_register) (v: rtl_exp size16)
    (a:rtl_exp size32) : Conv unit :=
      @set_mem_n seg a size16 v 1.

  Definition set_mem8 (seg:segment_register) (v: rtl_exp size8) 
    (a:rtl_exp size32) : Conv unit :=
      @set_mem_n seg a size8 v 0.

  (*Definition set_mem32 (seg: segment_register) (v a: pseudo_reg size32) : Conv unit := 
    b0 <- cast_u size8 v;
    smem seg b0 a;;
    eight <- load_Z size32 8;
    one <- load_Z size32 1;
    v1 <- arith shru_op v eight;
    b1 <- cast_u size8 v1;
    addr1 <- arith add_op a one;
    smem seg b1 addr1;;
    v2 <- arith shru_op v1 eight;
    b2 <- cast_u size8 v2;
    addr2 <- arith add_op addr1 one;
    smem seg b2 addr2;;
    v3 <- arith shru_op v2 eight;
    b3 <- cast_u size8 v3;
    addr3 <- arith add_op addr2 one;
    smem seg b3 addr3.*)
    
 Definition set_mem p w (seg:segment_register) : rtl_exp (opsize (op_override p) w) ->
    rtl_exp size32 -> 
    Conv unit :=
    match (op_override p) as b,w return
      rtl_exp (opsize b w) -> rtl_exp size32 -> Conv unit with
      | true, true => set_mem16 seg
      | true, false => set_mem8 seg
      | false, true => set_mem32 seg
      | false, false => set_mem8 seg
    end.
  (* update an operand *)
  Definition iset_op80 (seg:segment_register) (p:rtl_exp size80) (op:operand) :
    Conv unit := 
    match op with 
      | Imm_op _ => raise_error
      | Reg_op r => tmp <- cast_u size32 p;
                    set_reg tmp r
      | Address_op a => addr <- compute_addr a ; tmp <- cast_u size32 p;
                        set_mem32 seg tmp addr
      | Offset_op off => addr <- load_int off; tmp <- cast_u size32 p;
                        set_mem32 seg tmp addr
    end.

  Definition iset_op32 (seg:segment_register) (p:rtl_exp size32) (op:operand) :
    Conv unit := 
    match op with 
      | Imm_op _ => raise_error
      | Reg_op r => set_reg p r
      | Address_op a => addr <- compute_addr a ; set_mem32 seg p addr
      | Offset_op off => addr <- load_int off;
                           set_mem32 seg p addr
    end.

  Definition iset_op16 (seg:segment_register) (p:rtl_exp size16) (op:operand) :
    Conv unit := 
    match op with 
      | Imm_op _ => raise_error
      | Reg_op r => tmp <- load_reg r;
                    mask <- load_int (Word.mone size32);
                    sixteen <- load_Z size32 16;
                    mask2 <- arith shl_op mask sixteen ;
                    tmp2  <- arith and_op mask2 tmp;
                    p32 <- cast_u size32 p;
                    tmp3 <- arith or_op tmp2 p32;
                    set_reg tmp3 r
      | Address_op a => addr <- compute_addr a ; set_mem16 seg p addr
      | Offset_op off => addr <- load_int off;
                           set_mem16 seg p addr
    end.

  Definition iset_op8 (seg:segment_register) (p:rtl_exp size8) (op:operand) :
    Conv unit := 
    match op with 
      | Imm_op _ => raise_error
      | Reg_op r => tmp0 <- load_reg 
                         (match r with
                            | EAX => EAX
                            | ECX => ECX
                            | EDX => EDX
                            | EBX => EBX
                            | ESP => EAX
                            | EBP => ECX
                            | ESI => EDX
                            | EDI => EBX
                          end);
                    shift <- load_Z size32
                             (match r with
                                | EAX | ECX | EDX | EBX => 0
                                | _ => 8
                              end);
                    mone <- load_int (Word.mone size32);
                    mask0 <-load_Z size32 255;
                    mask1 <- arith shl_op mask0 shift;
                    mask2 <- arith xor_op mask1 mone;
                    tmp1 <- arith and_op tmp0 mask2;
                    pext <- cast_u size32 p;
                    pext_shift <- arith shl_op pext shift;
                    res <- arith or_op tmp1 pext_shift;
                    set_reg res
                         (match r with
                            | EAX => EAX
                            | ECX => ECX
                            | EDX => EDX
                            | EBX => EBX
                            | ESP => EAX
                            | EBP => ECX
                            | ESI => EDX
                            | EDI => EBX
                          end)
      | Address_op a => addr <- compute_addr a ; set_mem8 seg p addr
      | Offset_op off => addr <- load_int off;
                           set_mem8 seg p addr
    end.

  (* given a prefix and w bit, return the appropriate load function for the
     corresponding operand size *)
  Definition load_op p w (seg:segment_register) (op:operand)
    : Conv (rtl_exp (opsize (op_override p) w)) :=
    match op_override p as b, w return 
      Conv (rtl_exp (opsize b w)) with
      | true, true => iload_op16 seg op
      | true, false => iload_op8 seg op
      | false, true => iload_op32 seg op
      | false, false => iload_op8 seg op
    end.

  Definition set_op p w (seg:segment_register) :
     rtl_exp (opsize (op_override p) w) -> operand -> Conv unit :=
    match op_override p as b, w 
      return rtl_exp (opsize b w) -> operand -> Conv unit with
      | true, true => iset_op16 seg 
      | true, false => iset_op8 seg
      | false, true => iset_op32 seg 
      | false, false => iset_op8 seg
    end.
  
  (* given a prefix, get the override segment and if none is specified return def *)
  Definition get_segment (p:prefix) (def:segment_register) : segment_register := 
    match seg_override p with 
      | Some s => s 
      | None => def
    end.

  Definition op_contains_stack (op:operand) : bool :=
    match op with
      |Address_op a =>
        match (addrBase a) with
          |Some EBP => true
          |Some ESP => true
          | _ => false
        end
      | _ => false
    end.

  (*The default segment when an operand uses ESP or EBP as a base address
     is the SS segment*)
  Definition get_segment_op (p:prefix) (def:segment_register) (op:operand)
    : segment_register := 
    match seg_override p with 
      | Some s => s 
      | None => 
        match (op_contains_stack op) with
          | true => SS
          | false => def
        end
    end.

  Definition get_segment_op2 (p:prefix) (def:segment_register) (op1:operand)
    (op2: operand) : segment_register := 
    match seg_override p with 
      | Some s => s 
      | None => 
        match (op_contains_stack op1,op_contains_stack op2) with
          | (true,_) => SS
          | (_,true) => SS
          | (false,false) => def
        end
    end.

  Definition compute_cc (ct: condition_type) : Conv (rtl_exp size1) :=
    match ct with
      | O_ct => get_flag OF
      | NO_ct => p <- get_flag OF;
        not p
      | B_ct => get_flag CF
      | NB_ct => p <- get_flag CF;
        not p
      | E_ct => get_flag ZF
      | NE_ct => p <- get_flag ZF;
        not p
      | BE_ct => cf <- get_flag CF;
        zf <- get_flag ZF;
        arith or_op cf zf
      | NBE_ct => cf <- get_flag CF;
        zf <- get_flag ZF;
        p <- arith or_op cf zf;
        not p
      | S_ct => get_flag SF
      | NS_ct => p <- get_flag SF;
        not p
      | P_ct => get_flag PF
      | NP_ct => p <- get_flag PF;
        not p
      | L_ct => sf <- get_flag SF;
        of <- get_flag OF;
        arith xor_op sf of
      | NL_ct => sf <- get_flag SF;
        of <- get_flag OF;
        p <- arith xor_op sf of;
        not p
      | LE_ct => zf <- get_flag ZF;
        of <- get_flag OF;
        sf <- get_flag SF;
        p <- arith xor_op of sf;
        arith or_op zf p
      | NLE_ct => zf <- get_flag ZF;
        of <- get_flag OF;
        sf <- get_flag SF;
        p0 <- arith xor_op of sf;
        p1 <- arith or_op zf p0;
        not p1
    end.

  Fixpoint compute_parity_aux {s} op1 (op2 : rtl_exp size1) (n: nat) :
    Conv (rtl_exp size1) :=
    match n with
      | O => @load_Z size1 0
      | S m =>
        op2 <- compute_parity_aux op1 op2 m;
        sf <- load_Z s (Z.of_nat m);
        op1 <- arith shru_op op1 sf;
        r <- cast_u size1 op1;
        @arith size1 xor_op r op2
    end.
  
  Definition compute_parity {s} op : Conv (rtl_exp size1) := 
    r1 <- load_Z size1 0;
    one <- load_Z size1 1;
    p <- @compute_parity_aux s op r1 8; (* ACHTUNG *)
    arith xor_op p one.

  (**********************************************)
  (*   Conversion functions for instructions    *)
  (**********************************************)

  (************************)
  (* Arith ops            *)
  (************************)
  Definition conv_INC (pre:prefix) (w: bool) (op:operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op in 
        p0 <- load seg op ; 
        p1 <- load_Z _ 1 ; 
        p2 <- arith add_op p0 p1 ; 

        (* Note that CF is NOT changed by INC *)

        zero <- load_Z _ 0;
        ofp <- test lt_op p2 p0;

        zfp <- test eq_op p2 zero;

        sfp <- test lt_op p2 zero;

        pfp <- compute_parity p2;

        n0 <- cast_u size4 p0;
        n1 <- load_Z size4 1;
        n2 <- arith add_op n0 n1;
        afp <- test ltu_op n2 n0;

        set_flag OF ofp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        set seg p2 op.

  Definition conv_DEC (pre: prefix) (w: bool) (op: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op in
        p0 <- load seg op;
        p1 <- load_Z _ 1;
        p2 <- arith sub_op p0 p1;

        (* Note that CF is NOT changed by DEC *)

        zero <- load_Z _ 0;
        ofp <- test lt_op p0 p2; 

        zfp <- test eq_op p2 zero;
        
        sfp <- test lt_op p2 zero;

        pfp <- compute_parity p2;

        n0 <- cast_u size4 p0;
        n1 <- load_Z size4 1;
        n2 <- arith sub_op n0 n1;
        afp <- test ltu_op n0 n2;

        set_flag OF ofp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        set seg p2 op.

  Definition conv_ADC (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        (* RTL for useful constants *)
        zero <- load_Z _ 0;
        up <- load_Z _ 1;

        (* RTL for op1 *)
        p0 <- load seg op1;
        p1 <- load seg op2;
        cf0 <- get_flag CF;
        (* store the current CF flag in a pseudo reg *)
        old_cf <- write_ps_and_fresh cf0;
        cfext <- cast_u _ old_cf; 
        p2' <- arith add_op p0 p1;
        p2 <- arith add_op p2' cfext;

        (* RTL for OF *)
        b0 <- test lt_op p0 zero;
        b1 <- test lt_op p1 zero;
        b2 <- test lt_op p2 zero;
        b3 <- @arith size1 xor_op b0 b1;
        b3 <- @arith size1 xor_op up b3;
        b4 <- @arith size1 xor_op b0 b2;
        ofp <- @arith size1 and_op b3 b4;

        (* RTL for CF *)
        (* first test if p0+p1 has a carry; then check (p0+p1)+c *)
        b0 <- test ltu_op p2' p0;
        b1 <- test ltu_op p2' p1;
        b2 <- test ltu_op p2 p2';
        b3 <- test ltu_op p2 cfext;
        b4 <- @arith size1 or_op b0 b1;
        b5 <- @arith size1 or_op b2 b3;
        cfp <- @arith size1 or_op b4 b5;

        (* RTL for ZF *)
        zfp <- test eq_op p2 zero;

        (* RTL for SF *)
        sfp <- test lt_op p2 zero;

        (* RTL for PF *)
        pfp <- compute_parity p2;

        (* RTL for AF *)
        n0 <- cast_u size4 p0;
        n1 <- cast_u size4 p1;
        cf4 <- cast_u size4 old_cf;
        n2 <- @arith size4 add_op n0 n1;
        n2 <- @arith size4 add_op n2 cf4;
        b0 <- test ltu_op n2 n0;
        b1 <- test ltu_op n2 n1;
        afp <- @arith size1 or_op b0 b1;

        set_flag OF ofp;;
        set_flag CF cfp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        set seg p2 op1.

Definition conv_STC: Conv unit :=
  one <- load_Z size1 1;
  set_flag CF one.

Definition conv_STD: Conv unit :=
  one <- load_Z size1 1;
  set_flag DF one. 

Definition conv_CLC: Conv unit :=
  zero <- load_Z size1 0;
  set_flag CF zero.

Definition conv_CLD: Conv unit :=
  zero <- load_Z size1 0;
  set_flag DF zero.

Definition conv_CMC: Conv unit :=
  zero <- load_Z size1 0;
  p1 <- get_flag CF;
  p0 <- test eq_op zero p1;
  set_flag CF p0.

Definition conv_LAHF: Conv unit :=
  dst <- load_Z size8 0;

  fl <- get_flag SF;
  pos <- load_Z size8 7;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  fl <- get_flag ZF;
  pos <- load_Z size8 6;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  fl <- get_flag AF;
  pos <- load_Z size8 4;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  fl <- get_flag PF;
  pos <- load_Z size8 2;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  fl <- get_flag CF;
  pos <- load_Z size8 0;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  fl <- load_Z size8 1;
  pos <- load_Z size8 1;
  byt <- cast_u size8 fl;  
  tmp <- @arith size8 shl_op byt pos;  
  dst <- @arith size8 or_op dst tmp; 

  iset_op8 DS dst (Reg_op ESP).

Definition conv_SAHF: Conv unit :=
  one <- load_Z size8 1;
  ah <- iload_op8 DS (Reg_op ESP);

  pos <- load_Z size8 7;
  tmp <- @arith size8 shr_op ah pos;
  tmp <- @arith size8 and_op tmp one;
  sfp <- test eq_op one tmp;

  pos <- load_Z size8 6;
  tmp <- @arith size8 shr_op ah pos;
  tmp <- @arith size8 and_op tmp one;
  zfp <- test eq_op one tmp;

  pos <- load_Z size8 4;
  tmp <- @arith size8 shr_op ah pos;
  tmp <- @arith size8 and_op tmp one;
  afp <- test eq_op one tmp;

  pos <- load_Z size8 2;
  tmp <- @arith size8 shr_op ah pos;
  tmp <- @arith size8 and_op tmp one;
  pfp <- test eq_op one tmp;

  pos <- load_Z size8 0;
  tmp <- @arith size8 shr_op ah pos;
  tmp <- @arith size8 and_op tmp one;
  cfp <- test eq_op one tmp;

  set_flag SF sfp;;
  set_flag ZF zfp;;
  set_flag AF afp;;
  set_flag PF pfp;;
  set_flag CF cfp.


  Definition conv_ADD (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        (* RTL for useful constants *)
        zero <- load_Z _ 0;
        up <- load_Z size1 1;

        (* RTL for op1 *)
        p0 <- load seg op1;
        p1 <- load seg op2;
        p2 <- arith add_op p0 p1;

        (* RTL for OF *)
        (* b0, b1, b2 are the sign bits of p0, p1, p2, repsectively *)
        (* overflow bit is set if those three bits are (0,0,1) or (1,1,0) *)
        (* we compute "not (b0 xor b1) /\ (b0 xor b2)" *)
        b0 <- test lt_op p0 zero;
        b1 <- test lt_op p1 zero;
        b2 <- test lt_op p2 zero;
        b3 <- @arith size1 xor_op b0 b1;
        b3 <- @arith size1 xor_op up b3;
        b4 <- @arith size1 xor_op b0 b2;
        ofp <- @arith size1 and_op b3 b4;

        (* RTL for CF *)
        (* p0+p1 has a carry bit iff p2<p0 or p2<p1 *)
        b0 <- test ltu_op p2 p0;
        b1 <- test ltu_op p2 p1;
        cfp <- @arith size1 or_op b0 b1;

        (* RTL for ZF *)
        zfp <- test eq_op p2 zero;

        (* RTL for SF *)
        sfp <- test lt_op p2 zero;

        (* RTL for PF *)
        pfp <- compute_parity p2;

        (* RTL for AF *)
        n0 <- cast_u size4 p0;
        n1 <- cast_u size4 p1;
        n2 <- @arith size4 add_op n0 n1;
        b0 <- test ltu_op n2 n0;
        b1 <- test ltu_op n2 n1;
        afp <- @arith size1 or_op b0 b1;

        set_flag OF ofp;;
        set_flag CF cfp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        (* this has to go last as the computing of flags relies on the
           old op1 value *)
        set seg p2 op1.

  (* If e is true, then this is sub, otherwise it's cmp 
     Dest is equal to op1 for the case of SUB,
     but it's equal to op2 for the case of NEG
     
     We use segdest, seg1, seg2 to specify which segment
     registers to use for the destination, op1, and op2.
     This is because for CMPS, only the first operand's 
     segment can be overriden. 
  *) 

  Definition conv_SUB_CMP_generic (e: bool) (pre: prefix) (w: bool) (dest: operand) (op1 op2: operand) 
    (segdest seg1 seg2: segment_register) :=
    let load := load_op pre w in 
    let set := set_op pre w in 
        (* RTL for useful constants *)
        zero <- load_Z _ 0;
        one <- load_Z size1 1;

        (* RTL for op1 *)
        p0 <- load seg1 op1;
        p1 <- load seg2 op2;
        p2 <- arith sub_op p0 p1;

        (* RTL for OF *)
        b0 <- test lt_op p0 zero;
        b1' <- test lt_op p1 zero;
        (* b1 = not (p1 < 0) *)
        b1 <- arith xor_op b1' one;
        b2 <- test lt_op p2 zero;
        b3 <- @arith size1 xor_op b0 b1;
        b3 <- @arith size1 xor_op b3 one;
        b4 <- @arith size1 xor_op b0 b2;
        ofp <- @arith size1 and_op b3 b4;

        (* RTL for CF *)
        cfp <- test ltu_op p0 p1;

        (* RTL for ZF *)
        zfp <- test eq_op p2 zero;

        (* RTL for SF *)
        sfp <- test lt_op p2 zero;

        (* RTL for PF *)
        pfp <- compute_parity p2;

        (* RTL for AF *)
        n0 <- cast_u size4 p0;
        n1 <- cast_u size4 p1;
        afp <- test ltu_op p0 p1;

        set_flag OF ofp;;
        set_flag CF cfp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        if e then
          set segdest p2 dest
        else 
          no_op.

  Definition conv_CMP (pre: prefix) (w: bool) (op1 op2: operand) :=
    let seg := get_segment_op2 pre DS op1 op2 in
    conv_SUB_CMP_generic false pre w op1 op1 op2 seg seg seg.
  Definition conv_SUB (pre: prefix) (w: bool) (op1 op2: operand) :=
    let seg := get_segment_op2 pre DS op1 op2 in
    conv_SUB_CMP_generic true pre w op1 op1 op2 seg seg seg.
  Definition conv_NEG (pre: prefix) (w: bool) (op1: operand) :=
    let seg := get_segment_op pre DS op1 in
    conv_SUB_CMP_generic true pre w op1 (Imm_op Word.zero) op1 seg seg seg.

  Definition conv_SBB (pre: prefix) (w: bool) (op1 op2: operand) :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        (* RTL for useful constants *)
        zero <- load_Z _ 0;
        one <- load_Z size1 1;
        
        cf0 <- get_flag CF;
        (* store the current CF flag in a pseudo reg *)
        old_cf <- write_ps_and_fresh cf0;
        old_cf_ext <- cast_u _ old_cf;
        (* RTL for op1 *)
        p0 <- load seg op1;
        p1 <- load seg op2;
        p1' <- arith sub_op p0 p1;
        p2 <- arith sub_op p1' old_cf_ext;

        (* RTL for OF *)
        b0 <- test lt_op p0 zero;
        b1' <- test lt_op p1 zero;
        (* b1 = not (p1 < 0) *)
        b1 <- arith xor_op b1' one; 
        b2 <- test lt_op p2 zero;
        b3 <- @arith size1 xor_op b0 b1;
        b3 <- @arith size1 xor_op b3 one;
        b4 <- @arith size1 xor_op b0 b2;
        ofp <- @arith size1 and_op b3 b4;

        (* RTL for CF *)
        (* first test if p0 < p1 to see if there is a carry in p0 - p1;
           then test if p0-p1 < c to see if there is a carry in (p0-p1)- c;
           cannot just test if p0 < p1+c because p1+c may overflow; *)
        b0 <- test ltu_op p0 p1;
        b1 <- test ltu_op p1' old_cf_ext;
        cfp <- arith or_op b0 b1;

        (* RTL for ZF *)
        zfp <- test eq_op p2 zero;

        (* RTL for SF *)
        sfp <- test lt_op p2 zero;

        (* RTL for PF *)
        pfp <- compute_parity p2;

        (* RTL for AF *)
        n0 <- cast_u size4 p0;
        n1 <- cast_u size4 p1;
        b0' <- test ltu_op p0 p1;
        b0'' <- test eq_op p0 p1;
        afp <- arith or_op b0' b0'';

        set_flag OF ofp;;
        set_flag CF cfp;;
        set_flag ZF zfp;;
        set_flag SF sfp;;
        set_flag PF pfp;;
        set_flag AF afp;;
        set seg p2 op1.

  (* I tried refactoring this so that it was smaller, but the way I did
     it caused type-checking to seem to go on FOREVER - maybe someone more 
     clever can figure out how to clean this up *)

  Definition conv_DIV (pre: prefix) (w: bool) (op: operand) :=
    let seg := get_segment_op pre DS op in
      undef_flag CF;;
      undef_flag OF;;
      undef_flag SF;;
      undef_flag ZF;;
      undef_flag AF;;
      undef_flag PF;;
      match op_override pre, w with
        | _, false => 
          eax <- iload_op16 seg (Reg_op EAX);
          (* store the old eax since later on we may update both eax and op *)
          dividend <- write_ps_and_fresh eax;
          op_val <- iload_op8 seg op;
          (* store the old op value since the update on eax may change it 
             when op is eax *)
          divisor <- write_ps_and_fresh op_val;
          zero <- load_Z _ 0;
          divide_by_zero <- test eq_op zero divisor;
          if_trap divide_by_zero;;
          divisor_ext <- cast_u _ divisor;
          quotient <- arith divu_op dividend divisor_ext;
          max_quotient <- load_Z _ 255;
          div_error <- test ltu_op max_quotient quotient;
          if_trap div_error;;
          remainder <- arith modu_op dividend divisor_ext;
          quotient_trunc <- cast_u _ quotient;
          remainder_trunc <- cast_u _ remainder;
          iset_op8 seg quotient_trunc (Reg_op EAX);;
          iset_op8 seg remainder_trunc (Reg_op ESP) (* This is AH *)
        | true, true => 
          eax <- iload_op16 seg (Reg_op EAX);
          dividend_lower <- write_ps_and_fresh eax;
          dividend_upper <- iload_op16 seg (Reg_op EDX);
          dividend0 <- cast_u size32 dividend_upper;
          sixteen <- load_Z size32 16;
          dividend1 <- arith shl_op dividend0 sixteen;
          dividend_lower_ext <- cast_u size32 dividend_lower;
          dividend <- arith or_op dividend1 dividend_lower_ext;
          op_val <- iload_op16 seg op;
          divisor <- write_ps_and_fresh op_val;
          zero <- load_Z _ 0;
          divide_by_zero <- test eq_op zero divisor;
          if_trap divide_by_zero;;
          divisor_ext <- cast_u _ divisor;
          quotient <- arith divu_op dividend divisor_ext;
          max_quotient <- load_Z _ 65535;
          div_error <- test ltu_op max_quotient quotient;
          if_trap div_error;;
          remainder <- arith modu_op dividend divisor_ext;
          quotient_trunc <- cast_u _ quotient;
          remainder_trunc <- cast_u _ remainder;
          iset_op16 seg quotient_trunc (Reg_op EAX);;
          iset_op16 seg remainder_trunc (Reg_op EDX) 
        | false, true => 
          oe <- iload_op32 seg (Reg_op EAX);
          dividend_lower <- write_ps_and_fresh oe;
          dividend_upper <- iload_op32 seg (Reg_op EDX);
          dividend0 <- cast_u 63 dividend_upper;
          thirtytwo <- load_Z 63 32;
          dividend1 <- arith shl_op dividend0 thirtytwo;
          dividend_lower_ext <- cast_u _ dividend_lower;
          dividend <- arith or_op dividend1 dividend_lower_ext;
          op_val <- iload_op32 seg op;
          divisor <- write_ps_and_fresh op_val;
          zero <- load_Z _ 0;
          divide_by_zero <- test eq_op zero divisor;
          if_trap divide_by_zero;;
          divisor_ext <- cast_u _ divisor;
          quotient <- arith divu_op dividend divisor_ext;
          max_quotient <- load_Z _ 4294967295;
          div_error <- test ltu_op max_quotient quotient;
          if_trap div_error;;
          remainder <- arith modu_op dividend divisor_ext;
          quotient_trunc <- cast_u _ quotient;
          remainder_trunc <- cast_u _ remainder;
          iset_op32 seg quotient_trunc (Reg_op EAX);;
          iset_op32 seg remainder_trunc (Reg_op EDX) 
     end.

  Definition conv_IDIV (pre: prefix) (w: bool) (op: operand) :=
    let seg := get_segment_op pre DS op in
      undef_flag CF;;
      undef_flag OF;;
      undef_flag SF;;
      undef_flag ZF;;
      undef_flag AF;;
      undef_flag PF;;
      match op_override pre, w with
        | _, false => eax <- iload_op16 seg (Reg_op EAX);
                      dividend <- write_ps_and_fresh eax;
                      op_val <- iload_op8 seg op;
                      divisor <- write_ps_and_fresh op_val;
                      zero <- load_Z _ 0;
                      divide_by_zero <- test eq_op zero divisor;
                      if_trap divide_by_zero;;
                      divisor_ext <- cast_s _ divisor;
                      quotient <- arith divs_op dividend divisor_ext;
                      max_quotient <- load_Z _ 127;
                      min_quotient <- load_Z _ (-128);
                      div_error0 <- test lt_op max_quotient quotient;
                      div_error1 <- test lt_op quotient min_quotient;
                      div_error <- arith or_op div_error0 div_error1;
                      if_trap div_error;;
                      remainder <- arith mods_op dividend divisor_ext;
                      quotient_trunc <- cast_s _ quotient;
                      remainder_trunc <- cast_s _ remainder;
                      iset_op8 seg quotient_trunc (Reg_op EAX);;
                      iset_op8 seg remainder_trunc (Reg_op ESP) (* This is AH *)
       | true, true => eax <- iload_op16 seg (Reg_op EAX);
                       dividend_lower <- write_ps_and_fresh eax;
                       dividend_upper <- iload_op16 seg (Reg_op EDX);
                       dividend0 <- cast_s size32 dividend_upper;
                       sixteen <- load_Z size32 16;
                       dividend1 <- arith shl_op dividend0 sixteen;
                       dividend_lower_ext <- cast_s size32 dividend_lower;
                       dividend <- arith or_op dividend1 dividend_lower_ext;
                       op_val <- iload_op16 seg op;
                       divisor <- write_ps_and_fresh op_val;
                       zero <- load_Z _ 0;
                       divide_by_zero <- test eq_op zero divisor;
                       if_trap divide_by_zero;;
                       divisor_ext <- cast_s _ divisor;
                       quotient <- arith divs_op dividend divisor_ext;
                       max_quotient <- load_Z _ 32767;
                       min_quotient <- load_Z _ (-32768);
                       div_error0 <- test lt_op max_quotient quotient;
                       div_error1 <- test lt_op quotient min_quotient;
                       div_error <- arith or_op div_error0 div_error1;
                       if_trap div_error;;
                       remainder <- arith mods_op dividend divisor_ext;
                       quotient_trunc <- cast_s _ quotient;
                       remainder_trunc <- cast_s _ remainder;
                       iset_op16 seg quotient_trunc (Reg_op EAX);;
                       iset_op16 seg remainder_trunc (Reg_op EDX) 
       | false, true => eax <- iload_op32 seg (Reg_op EAX);
                       dividend_lower <- write_ps_and_fresh eax;
                       dividend_upper <- iload_op32 seg (Reg_op EDX);
                       dividend0 <- cast_s 63 dividend_upper;
                       thirtytwo <- load_Z 63 32;
                       dividend1 <- arith shl_op dividend0 thirtytwo;
                       dividend_lower_ext <- cast_s _ dividend_lower;
                       dividend <- arith or_op dividend1 dividend_lower_ext;
                       op_val <- iload_op32 seg op;
                       divisor <- write_ps_and_fresh op_val;
                       zero <- load_Z _ 0;
                       divide_by_zero <- test eq_op zero divisor;
                       if_trap divide_by_zero;;
                       divisor_ext <- cast_s _ divisor;
                       quotient <- arith divs_op dividend divisor_ext;
                       max_quotient <- load_Z _ 2147483647;
                       min_quotient <- load_Z _ (-2147483648);
                       div_error0 <- test lt_op max_quotient quotient;
                       div_error1 <- test lt_op quotient min_quotient;
                       div_error <- arith or_op div_error0 div_error1;
                       if_trap div_error;;
                       remainder <- arith mods_op dividend divisor_ext;
                       quotient_trunc <- cast_s _ quotient;
                       remainder_trunc <- cast_s _ remainder;
                       iset_op32 seg quotient_trunc (Reg_op EAX);;
                       iset_op32 seg remainder_trunc (Reg_op EDX) 
     end.

  Program Definition conv_IMUL (pre: prefix) (w: bool) (op1: operand) 
    (opopt2: option operand) (iopt: option int32) :=
    undef_flag SF;;
    undef_flag ZF;;
    undef_flag AF;;
    undef_flag PF;;
    match opopt2 with
     | None => let load := load_op pre w in
               let seg := get_segment_op pre DS op1 in
                 eax <- load seg (Reg_op EAX);
                 p1 <- write_ps_and_fresh eax;
                 op1_val <- load seg op1;
                 p2 <- write_ps_and_fresh op1_val;
                 p1ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p1;
                 p2ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p2;
                 res <- arith mul_op p1ext p2ext;
                 lowerhalf <- cast_s (opsize (op_override pre) w) res;
                 shift <- load_Z _ (Z_of_nat (opsize (op_override pre) w + 1));
                 res_shifted <- arith shr_op res shift;
                 upperhalf <- cast_s (opsize (op_override pre) w) res_shifted;
                 zero <- load_Z _  0;
                 max <- load_Z _ (Word.max_unsigned (opsize (op_override pre) w));
                 
                 (* CF and OF are set when siginificant bits, including the sign bit,
                    are carried to the upper half of the result; that is, when
                    (1) upperhalf is non-zero and non-max, or (2) upperhalf is zero,
                    but the significant bit of lower half is one, or (3) upperhalf
                    is max (all 1s) and the siginicant bit of lower half is zero *)
                 b0 <- test eq_op upperhalf zero;
                 b1 <- test eq_op upperhalf max;
                 b2 <- test lt_op lowerhalf zero;
                 (* b4 is condition (1) above *)
                 b3 <- arith or_op b0 b1;
                 b4 <- not b3;
                 (* b5 is condition (2) above *)
                 b5 <- arith and_op b0 b2;
                 (* b7 is condition (3) above *)
                 b6 <- not b2;
                 b7 <- arith and_op b1 b6;
                 b8 <- arith or_op b4 b5;
                 flag <- arith or_op b7 b8;
                 set_flag CF flag;;
                 set_flag OF flag;;

                 match (op_override pre), w with
                   | _, false => iset_op16 seg res (Reg_op EAX) 
                   | _, true =>  let set := set_op pre w in
                                    set seg lowerhalf (Reg_op EAX);;
                                    set seg upperhalf (Reg_op EDX)
                 end
      | Some op2 => 
        match iopt with
          | None => let load := load_op pre w in
                    let set := set_op pre w in
                    let seg := get_segment_op2 pre DS op1 op2 in
                      p1 <- load seg op1;
                      p2 <- load seg op2;
                      p1ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p1;
                      p2ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p2;
                      res <- arith mul_op p1ext p2ext;
                      lowerhalf <- cast_s (opsize (op_override pre) w) res;
                      reextend <- cast_s (2*((opsize (op_override pre) w)+1)-1) lowerhalf;
                      b0 <- test eq_op reextend res;
                      flag <- not b0;
                      set_flag CF flag;;
                      set_flag OF flag;;
                      set seg lowerhalf op1
          | Some imm3  =>
                    let load := load_op pre w in
                    let set := set_op pre w in
                    let seg := get_segment_op2 pre DS op1 op2 in
                      p1 <- load seg op2;
                      p2' <- load_int imm3;
                      p2 <-  cast_u (opsize (op_override pre) w) p2';
                      p1ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p1;
                      p2ext <- cast_s (2*((opsize (op_override pre) w)+1)-1) p2;
                      res <- arith mul_op p1ext p2ext;
                      lowerhalf <- cast_s (opsize (op_override pre) w) res;
                      reextend <- cast_s (2*((opsize (op_override pre) w)+1)-1) lowerhalf;
                      b0 <- test eq_op reextend res;
                      flag <- not b0;
                      set_flag CF flag;;
                      set_flag OF flag;;
                      set seg lowerhalf op1
        end
    end.
    Obligation 1. unfold opsize. 
      destruct (op_override pre); simpl; auto. Defined.

  Definition conv_MUL (pre: prefix) (w: bool) (op: operand) :=
    let seg := get_segment_op pre DS op in
    undef_flag SF;;
    undef_flag ZF;;
    undef_flag AF;;
    undef_flag PF;;
    match op_override pre, w with
      | _, false => p1 <- iload_op8 seg op;
                    p2 <- iload_op8 seg (Reg_op EAX);
                    p1ext <- cast_u size16 p1;
                    p2ext <- cast_u size16 p2;
                    res <- arith mul_op p1ext p2ext;
                    max <- load_Z _ 255;
                    cf_test <- test ltu_op max res;
                    set_flag CF cf_test;;
                    set_flag OF cf_test;;
                    iset_op16 seg res (Reg_op EAX)
      | true, true => 
                    op_val <- iload_op16 seg op;
                    p1 <- write_ps_and_fresh op_val;
                    eax <- iload_op16 seg (Reg_op EAX); 
                    p2 <- write_ps_and_fresh eax;
                    p1ext <- cast_u size32 p1;
                    p2ext <- cast_u size32 p2;
                    res <- arith mul_op p1ext p2ext;
                    res_lower <- cast_u size16 res;
                    sixteen <- load_Z size32 16;
                    res_shifted <- arith shru_op res sixteen;
                    res_upper <- cast_u size16 res_shifted;
                    zero <- load_Z size16 0;
                    cf_test <- test ltu_op zero res_upper;
                    set_flag CF cf_test;;
                    set_flag OF cf_test;;
                    iset_op16 seg res_lower (Reg_op EAX);;
                    iset_op16 seg res_upper (Reg_op EDX)
      | false, true => 
                    op_val <- iload_op32 seg op;
                    p1 <- write_ps_and_fresh op_val;
                    eax <- iload_op32 seg (Reg_op EAX);
                    p2 <- write_ps_and_fresh eax;
                    p1ext <- cast_u 63 p1;
                    p2ext <- cast_u 63 p2;
                    res <- arith mul_op p1ext p2ext;
                    res_lower <- cast_u size32 res;
                    thirtytwo <- load_Z 63 32;
                    res_shifted <- arith shru_op res thirtytwo;
                    res_upper <- cast_u size32 res_shifted;
                    zero <- load_Z size32 0;
                    cf_test <- test ltu_op zero res_upper;
                    set_flag CF cf_test;;
                    set_flag OF cf_test;;
                    iset_op32 seg res_lower (Reg_op EAX);;
                    iset_op32 seg res_upper (Reg_op EDX)
   end.

  Definition conv_shift shift (pre: prefix) (w: bool) (op1: operand) (op2: reg_or_immed) :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op1 in
      (* These aren't actually undef'd, but they're sqirrely
         so for now I'll just overapproximate *)
      undef_flag OF;;
      undef_flag CF;;
      undef_flag SF;;
      undef_flag ZF;;
      undef_flag PF;;
      undef_flag AF;;
      p1 <- load seg op1;
      p2 <- (match op2 with
              | Reg_ri r => iload_op8 seg (Reg_op r) 
              | Imm_ri i => load_int i
             end);
      mask <- load_Z _ 31;
      p2 <- arith and_op p2 mask;
      p2cast <- cast_u (opsize (op_override pre) w) p2;
      p3 <- arith shift p1 p2cast;
      set seg p3 op1.
               
  Definition conv_SHL pre w op1 op2 := conv_shift shl_op pre w op1 op2.
  Definition conv_SAR pre w op1 op2 := conv_shift shr_op pre w op1 op2.
  Definition conv_SHR pre w op1 op2 := conv_shift shru_op pre w op1 op2.

  Definition conv_ROR pre w op1 op2 := conv_shift ror_op pre w op1 op2. 
  Definition conv_ROL pre w op1 op2 := conv_shift rol_op pre w op1 op2.

  (* Need to be careful about op1 size. *)

  Definition conv_RCL pre w op1 op2 :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op1 in

    p1 <- load seg op1;
    p2 <- (match op2 with
              | Reg_ri r => iload_op8 seg (Reg_op r) 
              | Imm_ri i => load_int i
                   end);
    mask <- load_Z size8 31;
    p2 <- arith and_op p2 mask;
    (match opsize (op_override pre) w with
       | 7  => modmask <- load_Z _ 9;
               p2 <- arith modu_op p2 modmask;
               no_op
       | 15 => modmask <- load_Z _ 17;
               p2 <- arith modu_op p2 modmask;
               no_op
       | _  => no_op
     end);;
    p2cast <- cast_u ((opsize (op_override pre) w) + 1) p2;
    
    tmp <- cast_u ((opsize (op_override pre) w) + 1) p1;
    cf0 <- get_flag CF; 
    cf <- write_ps_and_fresh cf0;
    cf <- cast_u ((opsize (op_override pre) w) + 1) cf;
    tt <- load_Z _ (Z_of_nat ((opsize (op_override pre) w) + 1));
    cf <- arith shl_op cf tt;
    tmp <- arith or_op tmp cf;
    tmp <- arith rol_op tmp p2cast; 
    
    p3 <- cast_u (opsize (op_override pre) w) tmp;
    cf <- arith shr_op tmp tt;
    cf <- cast_u size1 cf;
    undef_flag OF;;
    set_flag CF cf;;
    set seg p3 op1.

  Definition conv_RCR pre w op1 op2 :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op1 in
    p1 <- load seg op1;
    p2 <- (match op2 with
              | Reg_ri r => iload_op8 seg (Reg_op r) 
              | Imm_ri i => load_int i
                   end);   
    mask <- load_Z size8 31;
    p2 <- arith and_op p2 mask;
    (match opsize (op_override pre) w with
       | 7  => modmask <- load_Z _ 9;
               p2 <- arith modu_op p2 modmask;
               no_op
       | 15 => modmask <- load_Z _ 17;
               p2 <- arith modu_op p2 modmask;
               no_op
       | _  => no_op
     end);;
   p2cast <- cast_u ((opsize (op_override pre) w) + 1) p2;

    oneshift <- load_Z _ 1;

    tmp <- cast_u ((opsize (op_override pre) w) + 1) p1;
    tmp <- arith shl_op tmp oneshift;
    cf0 <- get_flag CF;
    cf <- write_ps_and_fresh cf0;
    cf <- cast_u ((opsize (op_override pre) w) + 1) cf;
    tmp <- arith or_op tmp cf;
    tmp <- arith ror_op tmp p2cast;
    
    cf <- cast_u size1 tmp;
    p3 <- arith shr_op tmp oneshift;
    p3 <- cast_u ((opsize (op_override pre) w)) p3;
    undef_flag OF;;
    set_flag CF cf;;
    set seg p3 op1.

  Definition conv_SHLD pre (op1: operand) (r: register) ri :=
    let load := load_op pre true in
    let set := set_op pre true in
    let seg := get_segment_op pre DS op1 in
      count <- (match ri with
              | Reg_ri r => iload_op8 seg (Reg_op r) 
              | Imm_ri i => load_int i
             end);
      thirtytwo <- load_Z _ 32;
      count <- arith modu_op count thirtytwo;
      (* These aren't actually always undef'd, but they're sqirrely
         so for now I'll just overapproximate *)
      undef_flag CF;;
      undef_flag OF;;
      undef_flag SF;;
      undef_flag ZF;;
      undef_flag PF;;
      undef_flag AF;;
      p1 <- load seg op1;
      p2 <- load seg (Reg_op r);
      shiftup <- (match (op_override pre) with
                    | true => load_Z 63 16
                    | false => load_Z 63 32
                  end);
      wide_p1 <- cast_u 63 p1;
      wide_p1 <- arith shl_op wide_p1 shiftup;
      wide_p2 <- cast_u 63 p2;
      combined <- arith or_op wide_p1 wide_p2;
      wide_count <- cast_u 63 count;
      shifted <- arith shl_op combined wide_count;
      shifted <- arith shru_op shifted shiftup;
      newdest0 <- cast_u _ shifted;
      maxcount <- (match (op_override pre) with
                    | true => load_Z size8 16
                    | false => load_Z size8 32
                  end);
      guard1 <- test ltu_op maxcount count;
      guard2 <- test eq_op maxcount count;
      guard <- arith or_op guard1 guard2;
      newdest1 <- @choose _;
      newdest <- if_exp guard newdest1 newdest0;
      set seg newdest op1.

  Definition conv_SHRD pre (op1: operand) (r: register) ri :=
    let load := load_op pre true in
    let set := set_op pre true in
    let seg := get_segment_op pre DS op1 in
      count <- (match ri with
              | Reg_ri r => iload_op8 seg (Reg_op r) 
              | Imm_ri i => load_int i
             end);
      thirtytwo <- load_Z _ 32;
      count <- arith modu_op count thirtytwo;
      (* These aren't actually always undef'd, but they're sqirrely
         so for now I'll just overapproximate *)
      undef_flag CF;;
      undef_flag OF;;
      undef_flag SF;;
      undef_flag ZF;;
      undef_flag PF;;
      undef_flag AF;;
      p1 <- load seg op1;
      p2 <- load seg (Reg_op r);
      wide_p1 <- cast_u 63 p1;
      shiftup <- (match (op_override pre) with
                    | true => load_Z 63 16
                    | false => load_Z 63 32
                  end);
      wide_p2 <- cast_u 63 p2;
      wide_p2 <- arith shl_op wide_p2 shiftup;
      combined <- arith or_op wide_p1 wide_p2;
      wide_count <- cast_u 63 count;
      shifted <- arith shru_op combined wide_count;
      newdest0 <- cast_u _ shifted;
      maxcount <- (match (op_override pre) with
                    | true => load_Z size8 16
                    | false => load_Z size8 32
                  end);
      guard1 <- test ltu_op maxcount count;
      guard2 <- test eq_op maxcount count;
      guard <- arith or_op guard1 guard2;
      newdest1 <- @choose _;
      newdest <- if_exp guard newdest1 newdest0;
      set seg newdest op1.

  (* Definition size65 := 64. *)

  (* Definition conv_SHLD pre (op1: operand) (r: register) ri := *)
  (*   let load := load_op pre true in *)
  (*   let set := set_op pre true in *)
  (*   let seg := get_segment_op pre DS op1 in *)
  (*     count <- match ri with *)
  (*              | Reg_ri r => iload_op8 seg (Reg_op r)  *)
  (*              | Imm_ri i => load_int i *)
  (*              end; *)
  (*     thirtytwo <- load_Z _ 32; *)
  (*     count <- arith modu_op count thirtytwo; *)
  (*     opsize <- match (op_override pre) with *)
  (*               | true => load_Z size8 16 *)
  (*               | false => load_Z size8 32 *)
  (*               end; *)

  (*     (* Spec: If the count operand is 0, the flags are not *)
  (*        affected. Also, no registers are affected. *) *)
  (*     zero <- load_Z size8 0; *)
  (*     count_notzero <- test_neq count zero; *)

  (*     (* Spec: If the count is greater than the operand size, the *)
  (*        result in the destination operand is undefined. *) *)
  (*     count_gt_opsize <- test ltu_op opsize count; *)
  (*     undef_cf <- @choose size1; *)
  (*     undef_of <- @choose size1; *)
  (*     undef_sf <- @choose size1; *)
  (*     undef_zf <- @choose size1; *)
  (*     undef_pf <- @choose size1; *)
  (*     undef_af <- @choose size1; *)
  (*     undef_res <- @choose _; *)

  (*     p1 <- load seg op1; *)
  (*     p2 <- load seg (Reg_op r); *)
  (*     shiftup <- cast_u size65 opsize; *)
  (*     wide_p1 <- cast_u size65 p1; *)
  (*     wide_p1 <- arith shl_op wide_p1 shiftup; *)
  (*     wide_p2 <- cast_u size65 p2; *)
  (*     combined <- arith or_op wide_p1 wide_p2; *)
  (*     wide_count <- cast_u size65 count; *)
  (*     shifted <- arith shl_op combined wide_count; *)
  (*     shifted <- arith shru_op shifted shiftup; *)
  (*     res <- cast_u _ shifted; *)

  (*     shifted_out <- arith shru_op shifted shiftup; *)
  (*     cf <- cast_u _ shifted_out; *)
  (*     new_cf <- if_exp count_gt_opsize undef_cf cf; *)

  (*     (* Spec: For a 1-bit shift, the OF flag is set if a sign change *)
  (*        occurred; otherwise, it is cleared. For shifts greater than 1 *)
  (*        bit, the OF flag is undefined. *) *)
  (*     one <- load_Z size8 1; *)
  (*     count_isone <- test eq_op count one; *)
  (*     (* b0 and b1 are the sign bits of p1 and res, respectively *) *)
  (*     pzero <- load_Z _ 0; *)
  (*     b0 <- test lt_op p1 pzero; *)
  (*     b1 <- test lt_op res pzero; *)
  (*     of <- arith xor_op b0 b1; *)
  (*     new_of <- if_exp count_isone of undef_of; *)

  (*     new_sf <- if_exp count_gt_opsize undef_sf b1; *)
 
  (*     zf <- test eq_op res pzero; *)
  (*     new_zf <- if_exp count_gt_opsize undef_zf zf; *)

  (*     pf <- compute_parity res; *)
  (*     new_pf <- if_exp count_gt_opsize undef_pf pf; *)

  (*     newres <- if_exp count_gt_opsize undef_res res; *)
  (*     set seg newres op1;; *)
  (*     if_set_loc count_notzero new_cf (flag_loc CF);; *)
  (*     if_set_loc count_notzero new_of (flag_loc OF);; *)
  (*     if_set_loc count_notzero new_sf (flag_loc SF);; *)
  (*     if_set_loc count_notzero new_zf (flag_loc ZF);; *)
  (*     if_set_loc count_notzero new_pf (flag_loc PF);; *)
  (*     if_set_loc count_notzero undef_af (flag_loc AF). *)


  (* Definition conv_SHRD pre (op1: operand) (r: register) ri := *)
  (*   let load := load_op pre true in *)
  (*   let set := set_op pre true in *)
  (*   let seg := get_segment_op pre DS op1 in *)
  (*     count <- match ri with *)
  (*              | Reg_ri r => iload_op8 seg (Reg_op r)  *)
  (*              | Imm_ri i => load_int i *)
  (*              end; *)
  (*     thirtytwo <- load_Z _ 32; *)
  (*     count <- arith modu_op count thirtytwo; *)
  (*     opsize <- match (op_override pre) with *)
  (*               | true => load_Z size8 16 *)
  (*               | false => load_Z size8 32 *)
  (*               end; *)

  (*     (* Spec: If the count operand is 0, the flags are not *)
  (*        affected. Also, no registers are affected. *) *)
  (*     zero <- load_Z size8 0; *)
  (*     count_notzero <- test_neq count zero; *)

  (*     (* Spec: If the count is greater than the operand size, the *)
  (*        result in the destination operand is undefined. *) *)
  (*     count_gt_opsize <- test ltu_op opsize count; *)
  (*     undef_cf <- @choose size1; *)
  (*     undef_of <- @choose size1; *)
  (*     undef_sf <- @choose size1; *)
  (*     undef_zf <- @choose size1; *)
  (*     undef_pf <- @choose size1; *)
  (*     undef_af <- @choose size1; *)
  (*     undef_res <- @choose _; *)

  (*     p1 <- load seg op1; *)
  (*     p2 <- load seg (Reg_op r); *)
  (*     wide_p1 <- cast_u size65 p1; *)
  (*     shiftup <- cast_u size65 opsize; *)
  (*     wide_p2 <- cast_u size65 p2; *)
  (*     wide_p2 <- arith shl_op wide_p2 shiftup; *)
  (*     combined <- arith or_op wide_p1 wide_p2; *)
  (*     (* add one more bit at the end so that we can compute the cf bit *) *)
  (*     one <- load_Z size65 1; *)
  (*     combined' <- arith shl_op combined one; *)
  (*     wide_count <- cast_u size65 count; *)
  (*     shifted <- arith shru_op combined' wide_count; *)
  (*     cf <- cast_u size1 shifted; *)
  (*     res' <- arith shru_op shifted one; *)
  (*     res <- cast_u _ res'; *)

  (*     new_cf <- if_exp count_gt_opsize undef_cf cf; *)

  (*     (* Spec: For a 1-bit shift, the OF flag is set if a sign change *)
  (*        occurred; otherwise, it is cleared. For shifts greater than 1 *)
  (*        bit, the OF flag is undefined. *) *)
  (*     one_8 <- load_Z size8 1; *)
  (*     count_isone <- test eq_op count one_8; *)
  (*     (* b0 and b1 are the sign bits of p1 and res, respectively *) *)
  (*     pzero <- load_Z _ 0; *)
  (*     b0 <- test lt_op p1 pzero; *)
  (*     b1 <- test lt_op res pzero; *)
  (*     of <- arith xor_op b0 b1; *)
  (*     new_of <- if_exp count_isone of undef_of; *)

  (*     new_sf <- if_exp count_gt_opsize undef_sf b1; *)
 
  (*     zf <- test eq_op res pzero; *)
  (*     new_zf <- if_exp count_gt_opsize undef_zf zf; *)

  (*     pf <- compute_parity res; *)
  (*     new_pf <- if_exp count_gt_opsize undef_pf pf; *)

  (*     newres <- if_exp count_gt_opsize undef_res res; *)
  (*     set seg newres op1;; *)
  (*     if_set_loc count_notzero new_cf (flag_loc CF);; *)
  (*     if_set_loc count_notzero new_of (flag_loc OF);; *)
  (*     if_set_loc count_notzero new_sf (flag_loc SF);; *)
  (*     if_set_loc count_notzero new_zf (flag_loc ZF);; *)
  (*     if_set_loc count_notzero new_pf (flag_loc PF);; *)
  (*     if_set_loc count_notzero undef_af (flag_loc AF). *)

  (************************)
  (* Binary Coded Dec Ops *)
  (************************)

  (* The semantics for these operations are described using slightly different pseudocode in the
     old and new intel manuals, although they are operationally equivalent. These definitions
     are structured based on the new manual, so it may look strange when compared with the old
     manual *)

  Definition get_AH : Conv (rtl_exp size8) :=
    iload_op8 DS (Reg_op ESP)
  .
  Definition set_AH v: Conv unit :=
    iset_op8 DS v (Reg_op ESP) 
  .
  Definition get_AL : Conv (rtl_exp size8) :=
    iload_op8 DS (Reg_op EAX)
  .
  Definition set_AL v: Conv unit :=
    iset_op8 DS v (Reg_op EAX) 
  .

  Definition conv_AAA_AAS (op1: bit_vector_op) : Conv unit :=
    pnine <- load_Z size8 9;
    p0Fmask <- load_Z size8 15;
    af_val <- get_flag AF;
    paf <- write_ps_and_fresh af_val;
    al <- get_AL;
    pal <- write_ps_and_fresh al;
    digit1 <- arith and_op pal p0Fmask;
    cond1 <- test lt_op pnine digit1;
    cond <- arith or_op cond1 paf;

    ah <- get_AH;
    pah <- write_ps_and_fresh ah;
    (*Else branch*)
    pfalse <- load_Z size1 0;
    v_al0 <- arith and_op pal p0Fmask;
    
    (*If branch*)
    psix <- load_Z size8 6;
    pone <- load_Z size8 1;
    ptrue <- load_Z size1 1;
    pal_c <- arith op1 pal psix;
    pal_cmask <- arith and_op pal_c p0Fmask;
    v_al <- if_exp cond pal_cmask v_al0;
    
    pah_c <- arith op1 pah pone;
    v_ah <- if_exp cond pah_c pah;
    v_af <- if_exp cond ptrue pfalse;
    v_cf <- if_exp cond ptrue pfalse;

    (*Set final values*)
    set_flag AF v_af;;
    set_flag CF v_cf;;
    undef_flag OF;;
    undef_flag SF;;
    undef_flag ZF;;
    undef_flag PF;;
    set_AL v_al;;
    set_AH v_ah.

  Definition conv_AAD : Conv unit :=
    pal <- get_AL;
    pah <- get_AH;
    pten <- load_Z size8 10;
    pFF <- load_Z size8 255;
    pzero <- load_Z size8 0;

    tensval <- arith mul_op pah pten;
    pal_c <- arith add_op pal tensval;
    pal_cmask <- arith and_op pal_c pFF;

    zfp <- test eq_op pal_cmask pzero;
    set_flag ZF zfp;;
    sfp <- test lt_op pal_cmask pzero;
    set_flag SF sfp;;
    pfp <- compute_parity pal_cmask;
    set_flag PF pfp;;
    undef_flag OF;;
    undef_flag AF;;
    undef_flag CF;;

    (* ordering important *)
    set_AL pal_cmask;;
    set_AH pzero.

  Definition conv_AAM : Conv unit :=
    pal <- get_AL;
    pten <- load_Z size8 10;
    digit1 <- arith divu_op pal pten;
    digit2 <- arith modu_op pal pten;

    pzero <- load_Z size8 0;
    b0 <- test eq_op digit2 pzero;
    set_flag ZF b0;;
    b1 <- test lt_op digit2 pzero;
    set_flag SF b1;;
    b2 <- compute_parity digit2;
    set_flag PF b2;;
    undef_flag OF;;
    undef_flag AF;;
    undef_flag CF;;

    (* ordering important *)
    set_AH digit1;;
    set_AL digit2.

  Definition testcarryAdd s (p1:rtl_exp s) p2 p3 : Conv (rtl_exp size1) :=
    b0 <-test ltu_op p3 p1;
    b1 <-test ltu_op p3 p2;
    arith or_op b0 b1.

  Definition testcarrySub s (p1:rtl_exp s) p2 (p3:rtl_exp s) : Conv (rtl_exp size1) :=
    test ltu_op p1 p2.

  (*Use oracle for now*)
  Definition conv_DAA_DAS (op1: bit_vector_op) 
    (tester: (rtl_exp size8) -> (rtl_exp size8) -> (rtl_exp size8) ->
      Conv (rtl_exp size1)) : Conv unit :=
    undef_flag CF;;
    undef_flag AF;;
    undef_flag SF;;
    undef_flag ZF;;
    undef_flag PF;;
    undef_flag OF;;

    pal <- @choose size8;
    set_AL pal.

(*
  Definition conv_DAA_DAS (op1: bit_vector_op) tester: Conv unit :=
    pal <- get_AL;
    pcf <- get_flag CF;
    ptrue <- load_Z size1 1;
    pfalse <- load_Z size1 0;
    set_flag CF pfalse;;

    pnine <- load_Z size8 9;
    p0Fmask <- load_Z size8 15;
    palmask <- arith and_op pal p0Fmask;
    cond1 <- test lt_op pnine palmask;
    paf <- get_flag AF;
    cond <- arith or_op cond1 paf;

    v_cf <- load_Z size1 0;
    (*First outer if*)
      (*Else*)
      v_al <- copy_ps pal;
      v_af <- load_Z size1 0;
      (*If*)
      psix <- load_Z size8 6;
      pal_c <- arith op1 pal psix;
      ifset cond v_al pal_c;;
      ifset cond v_af ptrue;;

      (*Annoying test for carry flag*)
      b2 <- tester pal psix pal_c;
      newc <- arith or_op pcf b2;
      ifset cond v_cf newc;;
    (*End first outer if*)
      
    pninenine <- load_Z size8 153 (*0x99*);
    cond1' <- test lt_op pninenine pal;
    cond' <- arith or_op cond1' pcf;
    ncond' <- not cond';
    (*Second outer if*)
      (*Else*)
      ifset ncond' v_cf pfalse;;
      (*If*)
      psixty <- load_Z size8 96; (*0x60*)
      pal2_c <- arith op1 v_al psixty;
      ifset cond' v_al pal2_c;;
      ifset cond' v_cf ptrue;;
    (*End second outer if*)
    
    (*Set final values*)
    (*v_al, v_cf, v_af*)
    set_AL v_al;;
    set_flag CF v_cf;;
    set_flag AF v_af;;
    pzero <- load_Z size8 0;
    b0 <- test eq_op v_al pzero;
    set_flag ZF b0;;
    b1 <- test lt_op v_al pzero;
    set_flag SF b1;;
    b2 <- compute_parity v_al;
    set_flag PF b2;;
    undef_flag OF
.
    
*)
    
  (************************)
  (* Logical Ops          *)
  (************************)

  Definition conv_logical_op (do_effect: bool) (b: bit_vector_op) (pre: prefix) 
    (w: bool) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        p0 <- load seg op1;
        p1 <- load seg op2;
        p2 <- arith b p0 p1;
        zero <- load_Z _ 0;
        zfp <- test eq_op zero p2;
        sfp <- test lt_op p2 zero;
        pfp <- compute_parity p2;
        zero1 <- load_Z size1 0;
        set_flag OF zero1 ;;
        set_flag CF zero1 ;;
        set_flag ZF zfp   ;;
        set_flag SF sfp ;;
        set_flag PF pfp ;;
        undef_flag AF;;
        if do_effect then
          set seg p2 op1
        else
          no_op.
  
  Definition conv_AND p w op1 op2 := conv_logical_op true and_op p w op1 op2.
  Definition conv_OR p w op1 op2 := conv_logical_op true or_op p w op1 op2.
  Definition conv_XOR p w op1 op2 := conv_logical_op true xor_op p w op1 op2.

  (* This is like AND except you don't actually write the result in op1 *)
  Definition conv_TEST p w op1 op2 := conv_logical_op false and_op p w op1 op2.

  (* This is different than the others because it doesn't affect any
     flags *)

  Definition conv_NOT (pre: prefix) (w: bool) (op: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op pre DS op in
        p0 <- load seg op;
        max_unsigned <- load_Z _ (Word.max_unsigned size32);
        p1 <- arith xor_op p0 max_unsigned;
        set seg p1 op.

  (************************)
  (* Stack Ops            *)
  (************************)

  Definition conv_POP (pre: prefix) (op: operand) :=
    (*Segment cannot be overriden*)
    let seg := SS in 
    let set := set_op pre true seg in
    let loadmem := load_mem pre true seg in 
    let espoffset := match (op_override pre) with
                       | true => 2%Z
                       | false => 4%Z
                     end in
      oldesp <- load_reg ESP;
      value <- loadmem oldesp;
      offset <- load_Z size32 espoffset;
      newesp <- arith add_op oldesp offset;
      (* set op before changing esp *)
      set value op;;
      set_reg newesp ESP.

  Definition conv_POPA (pre:prefix) :=
    let espoffset := match (op_override pre) with
                       | true => 2%Z
                       | false => 4%Z
                     end in
    let poprtl r := conv_POP pre (Reg_op r) in
    poprtl EDI;;
    poprtl ESI;;
    poprtl EBP;;
    oldesp <- load_reg ESP;
    offset <- load_Z size32 espoffset;
    newesp <- arith add_op oldesp offset;
    set_reg newesp ESP;;
    poprtl EBX;;
    poprtl EDX;;
    poprtl ECX;;
    poprtl EAX.

  Definition conv_PUSH (pre: prefix) (w: bool) (op: operand) :=
    let seg := SS in
    let load := load_op pre true seg in
    let setmem := set_mem pre true seg in
    let espoffset := match op_override pre,w return Z with 
                       | true,_ => 2%Z
                       | false,_ => 4%Z
                     end in
    p0 <- load op;
    oldesp <- load_reg ESP;
    offset <- load_Z size32 espoffset;
    newesp <- arith sub_op oldesp offset;
    setmem p0 newesp;;
    set_reg newesp ESP.

  Definition conv_PUSH_pseudo (pre:prefix) (w:bool) 
    pr  := (* (pr: pseudo_reg (opsize (op_override pre) w)) *)
    let seg := SS in
    let setmem := set_mem pre w seg in
    let espoffset := match op_override pre,w return Z with 
                       | _,false => 1%Z
                       | true,true => 2%Z
                       | false,true => 4%Z
                     end in
    oldesp <- load_reg ESP;
    offset <- load_Z size32 espoffset;
    newesp <- arith sub_op oldesp offset;
    setmem pr newesp;;
    set_reg newesp ESP.

(*
    let seg := get_segment pre SS in
      if w then
        p0 <- iload_op32 seg op;
        oldesp <- load_reg ESP;
        four <- load_Z size32 4;
        newesp <- arith sub_op oldesp four;
        set_mem32 seg p0 newesp;;
        set_reg newesp ESP
      else
        b0 <- iload_op8 seg op;
        oldesp <- load_reg ESP;
        one <- load_Z size32 1;
        newesp <- arith sub_op oldesp one;
        set_mem8 seg b0 newesp;;
        set_reg newesp ESP.
*)

Definition conv_PUSHA (pre:prefix) :=
    let load := load_op pre true SS in
    let pushrtl r := conv_PUSH pre true (Reg_op r) in
    oldesp <- load (Reg_op ESP);
    pushrtl EAX;;
    pushrtl ECX;;
    pushrtl EDX;;
    pushrtl EBX;;
    conv_PUSH_pseudo pre true oldesp;;
    pushrtl EBP;;
    pushrtl ESI;;
    pushrtl EDI.

Definition get_and_place T dst pos fl: Conv (rtl_exp T) :=
  fl <- get_flag fl;
  pos <- load_Z _ pos;
  byt <- cast_u _ fl;  
  tmp <- arith shl_op byt pos;  
  arith or_op dst tmp.

(*
This is not quite right. Plus those more sketchy flags
are not being modeled yet since they're more systemszy.

Definition conv_PUSHF pre :=
  dst <- load_Z (opsize (op_override pre) true) 0;

  dst <- get_and_place dst 21 ID;
  dst <- get_and_place dst 20 VIP;
  dst <- get_and_place dst 19 VIF;  
  dst <- get_and_place dst 18 AC;
  dst <- get_and_place dst 17 VM;
  dst <- get_and_place dst 16 RF;
  dst <- get_and_place dst 14 NT;
(*  get_and_place dst 13 12 IOPL; *)
  dst <- get_and_place dst 11 OF;
  dst <- get_and_place dst 10 DF;
  dst <- get_and_place dst 9 IF_flag;
  dst <- get_and_place dst 8 TF;
  dst <- get_and_place dst 7 SF;
  dst <- get_and_place dst 6 ZF;
  dst <- get_and_place dst 4 AF;
  dst <- get_and_place dst 2 PF;
  dst <- get_and_place dst 0 CF;
  conv_PUSH_pseudo pre true dst.  
*)

Definition conv_POP_pseudo (pre: prefix) :=
(*Segment cannot be overriden*)
  let seg := SS in 
    let set := set_op pre true seg in
      let loadmem := load_mem pre true seg in 
        let espoffset := match (op_override pre) with
                           | true => 2%Z
                           | false => 4%Z
                         end in
        oldesp <- load_reg ESP;
        offset <- load_Z size32 espoffset;
        newesp <- arith add_op oldesp offset;
        loadmem oldesp;;
        set_reg newesp ESP.

Definition extract_and_set T value pos fl: Conv unit :=
  one <- load_Z T 1;
  pos <- load_Z _ pos;
  tmp <- @arith _ shr_op value pos;
  tmp <- @arith _ and_op tmp one;
  b <- test eq_op one tmp;
  set_flag fl b.

(*
This is not quite right.
Definition conv_POPF pre :=
  v <- conv_POP_pseudo pre;

  @extract_and_set ((opsize (op_override pre) true)) v 21 ID;;
  extract_and_set v 20 VIP;;
  extract_and_set v 19 VIF;; 
  extract_and_set v 18 AC;;
  extract_and_set v 17 VM;;
  extract_and_set v 16 RF;;
  extract_and_set v 14 NT;;
(*  extract_and_set dst 13 12 IOPL; *)
  extract_and_set v 11 OF;;
  extract_and_set v 10 DF;;
  extract_and_set v 9 IF_flag;;
  extract_and_set v 8 TF;;
  extract_and_set v 7 SF;;
  extract_and_set v 6 ZF;;
  extract_and_set v 4 AF;;
  extract_and_set v 2 PF;;
  extract_and_set v 0 CF.
*)

  (************************)
  (* Control-Flow Ops     *)
  (************************)

  Definition conv_JMP (pre: prefix) (near absolute: bool) (op: operand)
    (sel: option selector) :=
    let seg := get_segment_op pre DS op in
      if near then
        disp <- iload_op32 seg op;
        base <- (match absolute with
                   | true => load_Z size32 0
                   | false => get_pc
                 end);
        newpc <- arith add_op base disp;
        set_pc newpc
      else
        raise_error.

  Definition conv_Jcc (pre: prefix) (ct: condition_type) (disp: int32) : Conv unit :=
    guard <- compute_cc ct;
    oldpc <- get_pc;
    pdisp <- load_int disp;
    newpc <- arith add_op oldpc pdisp;
    if_set_loc guard newpc pc_loc.

  Definition conv_CALL (pre: prefix) (near absolute: bool) (op: operand)
    (sel: option selector) :=
      oldpc <- get_pc;
      oldesp <- load_reg ESP;
      four <- load_Z size32 4;
      newesp <- arith sub_op oldesp four;
      set_mem32 SS oldpc newesp;;
      set_reg newesp ESP;;
      conv_JMP pre near absolute op sel.
  
  Definition conv_RET (pre: prefix) (same_segment: bool) (disp: option int16) :=
      if same_segment then
        oldesp <- load_reg ESP;
        value <- load_mem32 SS oldesp;
        four <- load_Z size32 4;
        newesp <- arith add_op oldesp four;
        set_pc value;;
        (match disp with
           | None => set_reg newesp ESP
           | Some imm => imm0 <- load_int imm;
             imm <- cast_u size32 imm0;
             newesp2 <- arith add_op newesp imm;
             set_reg newesp2 ESP
         end)
      else
        raise_error.
  
  Definition conv_LEAVE pre := 
    ebp_val <- load_reg EBP;
    set_reg ebp_val ESP;;
    conv_POP pre (Reg_op EBP).

  Definition conv_LOOP pre (flagged:bool) (testz:bool) (disp:int8):=
    ptrue <- load_Z size1 1;
    p0 <- load_reg ECX;
    p1 <- load_Z _ 1;
    p2 <- arith sub_op p0 p1;
    pzero <- load_Z _ 0;
    pcz <- test eq_op p2 pzero;
    pcnz <- arith xor_op pcz ptrue;
    pzf <- get_flag ZF;
    pnzf <- arith xor_op pzf ptrue;
    bcond <- 
    (match flagged with
       | true =>
         (match testz with
            | true => (arith and_op pzf pcnz)
            | false => (arith and_op pnzf pcnz)
          end)
       | false => arith or_op pcnz pcnz
     end);
    eip0 <- get_pc;
    doffset0 <- load_int disp;
    doffset1 <- cast_s size32 doffset0;
    eip1 <- arith add_op eip0 doffset1;
    eipmask <-
    (match (op_override pre) with
       |true => load_Z size32 65536%Z (*0000FFFF*)
       |false => load_Z size32 (-1%Z)
     end);
    eip2 <- arith and_op eip1 eipmask;
    (* update pc before updating ecx as the new pc depends on old pc
       and old ECX and new ECX depends only on the old ECX *)
    if_set_loc bcond eip2 pc_loc;;
    set_reg p2 ECX.

  (************************)
  (* Misc Ops             *)
  (************************)

  (* Unfortunately this is kind of "dumb", because we can't short-circuit
     once we find the msb/lsb *)
  Fixpoint conv_BS_aux {s} (d: bool) (n: nat) (op: rtl_exp s) : Conv (rtl_exp s) :=
    let curr_int := (match d with
                       | true => @Word.repr s (BinInt.Z_of_nat (s-n)) 
                       | false => @Word.repr s (BinInt.Z_of_nat n) 
                     end) in
    fun st => match n with
      | O => load_int curr_int st
      | S n' =>
        let bcount := fst (load_int curr_int st) in
        let ps := fst (arith shru_op op bcount st) in
        let curr_bit := fst (cast_u size1 ps st) in
        let rec1 := fst (load_int curr_int st) in
        let rec0 := fst (conv_BS_aux d n' op st) in
          if_exp curr_bit rec1 rec0 st
    end.

  Definition conv_BS (d: bool) (pre: prefix) (op1 op2: operand) :=
    let seg := get_segment_op2 pre DS op1 op2 in
    let load := load_op pre true in
    let set := set_op pre true in
      undef_flag AF;;
      undef_flag CF;;
      undef_flag SF;;
      undef_flag OF;;
      undef_flag PF;;
      des <- load seg op1;
      src <- load seg op2;
      zero <- load_Z (opsize (op_override pre) true) 0;
      zf <- test eq_op src zero;
      res0 <- conv_BS_aux d (opsize (op_override pre) true) src;
      res1 <- @choose _;
      res <- if_exp zf res1 res0;

      set_flag ZF zf;;
      set seg res op1.

  Definition conv_BSF pre op1 op2 := conv_BS true pre op1 op2.
  Definition conv_BSR pre op1 op2 := conv_BS false pre op1 op2.
  
  Definition get_Bit {s: nat} (pb: rtl_exp s) (poff: rtl_exp s) : 
    Conv (rtl_exp size1) :=
    omask <- load_Z s 1;
    shr_pb <- arith shr_op pb poff;
    mask_pb <- arith and_op shr_pb omask;
    cast_u size1 mask_pb.

  Definition modify_Bit {s} (value: rtl_exp s) (poff: rtl_exp s)
    (bitval: rtl_exp size1): Conv (rtl_exp s) :=
    obit <- load_Z _ 1;
    one_shifted <- arith shl_op obit poff;
    inv_one_shifted <- not one_shifted;
    bitvalword <- cast_u _ bitval;
    bit_shifted <- arith shl_op bitvalword poff;
    newval <- arith and_op value inv_one_shifted;
    arith or_op newval bit_shifted.

  (*Set a bit given a word referenced by an operand*)
  Definition set_Bit (pre:prefix) (w:bool)
    (op:operand) (poff: rtl_exp (opsize (op_override pre) w)) 
    (bitval: rtl_exp size1):
    Conv unit :=
    let seg := get_segment_op pre DS op in
    let load := load_op pre w seg in
    let set := set_op pre w seg in
    value <- load op;
    newvalue <- modify_Bit value poff bitval;
    set newvalue op.

  (*Set a bit given a word referenced by a raw address*)
  Definition set_Bit_mem (pre:prefix) (w:bool)
    (op:operand) (addr:rtl_exp size32) (poff: rtl_exp (opsize (op_override pre) w)) 
    (bitval: rtl_exp size1):
    Conv unit :=
    let seg := get_segment_op pre DS op in
    let load := load_mem pre w seg in
    let set := set_mem pre w seg in
    value <- load addr;
    newvalue <- modify_Bit value poff bitval;
    set newvalue addr.

  (* id, comp, set, or reset on a single bit, depending on the params*)
  Definition fbit (param1: bool) (param2: bool) (v: rtl_exp size1):
    Conv (rtl_exp size1) :=
    match param1, param2 with
      | true, true => load_Z size1 1
      | true, false => load_Z size1 0
      | false, true => ret v
      | false, false => not v
    end.

  (*tt: set, tf: clear, ft: id, ff: complement*)
  Definition conv_BT (param1: bool) (param2: bool)
    (pre: prefix) (op1 : operand) (regimm: operand) :=
    let seg := get_segment_op pre DS op1 in
    let load := load_op pre true seg in
    let lmem := load_mem pre true seg in
    let opsz := opsize (op_override pre) true in
    undef_flag OF;;
    undef_flag SF;;
    undef_flag AF;;
    undef_flag PF;;
    pi <- load regimm;
    popsz <- load_Z opsz (BinInt.Z_of_nat opsz + 1);
    rawoffset <- 
      (match regimm with
         | Imm_op i =>
           arith modu_op pi popsz
         | _ => ret pi
       end
      );
    popsz_bytes <- load_Z size32 ((BinInt.Z_of_nat (opsz + 1))/8);
    pzero <- load_Z opsz 0;
    pneg1 <- load_Z size32 (-1)%Z;
    (*for factoring out what we do when we access mem*)
    (*psaddr is the base word address*)
    let btmem psaddr := 
        bitoffset <- arith mods_op rawoffset popsz;
        wordoffset' <- arith divs_op rawoffset popsz;
        (*Important to preserve sign here*)
        wordoffset <- cast_s size32 wordoffset';
        (*if the offset is negative, we need to the word offset needs to
           be shifted one more down, and the offset needs to be made positive *)
        isneg <- test lt_op bitoffset pzero;
        (*nbitoffset:size_opsz and nwordoffset:size32 are final signed values*)
        (*If the bitoffset was lt zero, we need to adjust values to make them positive*)
        negbitoffset <- arith add_op popsz bitoffset;
        negwordoffset <- arith add_op pneg1 wordoffset;
        nbitoffset1 <- cast_u _ negbitoffset;
        nbitoffset <- if_exp isneg nbitoffset1 bitoffset;

        nwordoffset1 <- cast_u _ negwordoffset;
        nwordoffset <- if_exp isneg nwordoffset1 wordoffset;

        newaddrdelta <- arith mul_op nwordoffset popsz_bytes;
        newaddr <- arith add_op newaddrdelta psaddr;
        
        value <- lmem newaddr;
        bt <- get_Bit value nbitoffset;
        newbt <- fbit param1 param2 bt;

        set_flag CF bt;;
        set_Bit_mem pre true op1 newaddr nbitoffset newbt in
    match op1 with
      | Imm_op _ => raise_error
      | Reg_op r1 =>
        value <- load (Reg_op r1);
        bitoffset <- arith modu_op rawoffset popsz;
        bt <- get_Bit value bitoffset;
        newbt <- fbit param1 param2 bt;
        set_flag CF bt;;
        set_Bit pre true op1 bitoffset newbt
      | Address_op a => 
        psaddr <- compute_addr a;
        btmem psaddr
      | Offset_op ioff => 
        psaddr <- load_int ioff;
        btmem psaddr
    end.

  Definition conv_BSWAP (pre: prefix) (r: register) :=
    let seg := get_segment pre DS in
      eight <- load_Z size32 8;
      ps0 <- load_reg r;
      b0 <- cast_u size8 ps0;

      ps1 <- arith shru_op ps0 eight;
      b1 <- cast_u size8 ps1;
      w1 <- cast_u size32 b1;

      ps2 <- arith shru_op ps1 eight;
      b2 <- cast_u size8 ps2;
      w2 <- cast_u size32 b2;

      ps3 <- arith shru_op ps2 eight;
      b3 <- cast_u size8 ps3;
      w3 <- cast_u size32 b3;

      res0 <- cast_u size32 b0;
      res1 <- arith shl_op res0 eight;
      res2 <- arith add_op res1 w1;
      res3 <- arith shl_op res2 eight;
      res4 <- arith add_op res3 w2;
      res5 <- arith shl_op res4 eight;
      res6 <- arith add_op res5 w3;
      set_reg res6 r.

  Definition conv_CWDE (pre: prefix) :=
    let seg := get_segment pre DS in
      match op_override pre with
        | true =>  p1 <- iload_op8 seg (Reg_op EAX);
                   p2 <- cast_s size16 p1;
                   iset_op16 seg p2 (Reg_op EAX)
        | false => p1 <- iload_op16 seg (Reg_op EAX);
                   p2 <- cast_s size32 p1;
                   iset_op32 seg p2 (Reg_op EAX)
      end.

  Definition conv_CDQ (pre: prefix) :=
    let seg := get_segment pre DS in
      match op_override pre with
        | true =>  p1 <- iload_op16 seg (Reg_op EAX);
                   p2 <- cast_s size32 p1;
                   p2_bottom <- cast_s size16 p2;
                   sixteen <- load_Z _ 16;
                   p2_top0 <- arith shr_op p2 sixteen;
                   p2_top <- cast_s size16 p2_top0;
                   iset_op16 seg p2_top (Reg_op EDX);;
                   iset_op16 seg p2_bottom (Reg_op EAX)
        | false =>  p1 <- iload_op32 seg (Reg_op EAX);
                   p2 <- cast_s 63 p1;
                   p2_bottom <- cast_s size32 p2;
                   thirtytwo <- load_Z _ 32;
                   p2_top0 <- arith shr_op p2 thirtytwo;
                   p2_top <- cast_s size32 p2_top0;
                   iset_op32 seg p2_top (Reg_op EDX);;
                   iset_op32 seg p2_bottom (Reg_op EAX)
      end.

  Definition conv_MOV (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        res <- load seg op2;
        set seg res op1.

  (* Note that cmov does not have a byte mode - however we use it as a pseudo-instruction
     to simplify some of the other instructions (e.g. CMPXCHG *)

  Definition conv_CMOV (pre: prefix) (w: bool) (cc: condition_type) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    let seg := get_segment_op2 pre DS op1 op2 in
        tmp0 <- load seg op1;
        src <- load seg op2;
        cc <- compute_cc cc;
        tmp1 <- cast_u _ src;
        tmp <- if_exp cc tmp1 tmp0;
        set seg tmp op1.

  Definition conv_MOV_extend (extend_op: forall s1 s2: nat, rtl_exp s1 
    -> Conv (rtl_exp s2)) (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    let seg := get_segment_op2 pre DS op1 op2 in
    match op_override pre, w with
      (* It's not really clear what should be done true, true here. It's not in the table,
         but it seems to be a valid instruction. It would correspond to sign/zero
         extending a 16 bit value to a 16 bit value... ie just moving *)
      | true, true =>  p1 <- iload_op16 seg op2;
                       iset_op16 seg p1 op1
      | false, true => p1 <- iload_op16 seg op2;
                       p2 <- extend_op _ _ p1;
                       iset_op32 seg p2 op1
      | true, false => p1 <- iload_op8 seg op2;
                       p2 <- extend_op _ _ p1;
                       iset_op16 seg p2 op1
      | false, false => p1 <- iload_op8 seg op2;
                        p2 <- extend_op _ _ p1;
                        iset_op32 seg p2 op1
    end.

  Definition conv_MOVZX pre w op1 op2 := conv_MOV_extend cast_u pre w op1 op2.
  Definition conv_MOVSX pre w op1 op2 := conv_MOV_extend cast_s pre w op1 op2.

  Definition conv_XCHG (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    let load := load_op pre w in
    let set := set_op pre w in
    let seg := get_segment_op2 pre DS op1 op2 in
        p1 <- load seg op1;
        sp1 <- write_ps_and_fresh p1;
        p2 <- load seg op2;
        set seg p2 op1;;
        set seg sp1 op2.

  Definition conv_XADD (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    conv_XCHG pre w op1 op2;;
    conv_ADD pre w op1 op2.

  (* This actually has some interesting properties for concurrency stuff
     but for us this doesn't matter yet *)
  Definition conv_CMPXCHG (pre: prefix) (w: bool) (op1 op2: operand) : Conv unit :=
    (* The ZF flag will be set by the CMP to be zero if EAX = op1 *)
    conv_CMP pre w (Reg_op EAX) op1;;
    conv_CMOV pre w (E_ct) op1 op2;;
    conv_CMOV pre w (NE_ct) (Reg_op EAX) op1.

  (* This handles shifting the ESI/EDI stuff by the correct offset
     and in the appopriate direction for the string ops *) 
 
  Definition string_op_reg_shift reg pre w : Conv unit :=
    offset <- load_Z _  
                   (match op_override pre, w with
                      | _, false => 1
                      | true, true => 2
                      | false, true => 4
                    end);
    df <- get_flag DF;
    tmp <- iload_op32 DS (Reg_op reg);
    old_reg <- write_ps_and_fresh tmp;
    new_reg1 <- arith add_op old_reg offset;
    new_reg2 <- arith sub_op old_reg offset;
    set_reg new_reg1 reg;;
    if_set_loc df new_reg2 (reg_loc reg).

  (*
  Definition string_op_reg_shift pre w : Conv unit :=
    offset <- load_Z _  
                   (match op_override pre, w with
                      | _, false => 1
                      | true, true => 2
                      | false, true => 4
                    end);
    df <- get_flag DF;
    old_esi <- iload_op32 DS (Reg_op ESI);
    old_edi <- iload_op32 DS (Reg_op EDI);

    new_esi1 <- arith add_op old_esi offset;
    new_esi2 <- arith sub_op old_esi offset;

    new_edi1 <- arith add_op old_edi offset;
    new_edi2 <- arith sub_op old_edi offset;
   
    set_reg new_esi1 ESI;;
    if_set_loc df new_esi2 (reg_loc ESI);;

    set_reg new_edi1 EDI;;
    if_set_loc df new_edi2 (reg_loc EDI).
  *)

  (* As usual we assume AddrSize = 32 bits *)
  Definition conv_MOVS pre w : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    (* The dest segment has to be ES, but the source can
       be overriden (DS by default)
    *)
    let seg_load := get_segment pre DS in 
    p1 <- load seg_load (Address_op (mkAddress Word.zero (Some ESI) None));
    set ES p1 (Address_op (mkAddress Word.zero (Some EDI) None));;
    string_op_reg_shift EDI pre w;;
    string_op_reg_shift ESI pre w.

  Definition conv_STOS pre w : Conv unit :=
    let load := load_op pre w in 
    let set := set_op pre w in 
    p1 <- load DS (Reg_op EAX);
    set ES p1 (Address_op (mkAddress Word.zero (Some EDI) None));;
    string_op_reg_shift EDI pre w.

  Definition conv_CMPS pre w : Conv unit :=
    let seg1 := get_segment pre DS in 
    let op1 := (Address_op (mkAddress Word.zero (Some ESI) None)) in
    let op2 := (Address_op (mkAddress Word.zero (Some EDI) None)) in
    conv_SUB_CMP_generic false pre w op1 op2 op2 
      seg1 seg1 ES;;
    string_op_reg_shift EDI pre w;;
    string_op_reg_shift ESI pre w.
 
  (* The decoder outputs only the case that op2 is Address_op. *)
  Definition conv_LEA (pre: prefix) (op1 op2: operand) :=
    let seg := get_segment_op pre DS op1 in
      match op2 with
        | Address_op a =>
          r <- compute_addr a;
          iset_op32 seg r op1
        | _ => raise_error
      end.

  Definition conv_HLT (pre:prefix) := raise_trap.

  Definition conv_SETcc (pre: prefix) (ct: condition_type) (op: operand) := 
    let seg := get_segment_op pre DS op in
      ccval <- compute_cc ct;
      ccext <- cast_u size8 ccval;
      iset_op8 seg ccext op.
      
  (* Just a filter for some prefix stuff we're not really handling yet.
     In the future this should go away. *)
  Definition check_prefix (p: prefix) := 
    (match addr_override p with
       | false => no_op
       | _ => raise_error
     end).

  (*
  Definition conv_REP_generic (zfval: option Z) (oldpc_val: Word.int size32) :=
    oldecx <- load_reg ECX;
    one <- load_Z _ 1;
    newecx <- arith sub_op oldecx one;
    set_reg newecx ECX;;
    zero <- load_Z _ 0;
    oldpc <- load_int oldpc_val;
    op_guard <- test eq_op newecx zero;
    guard <- not op_guard;
    if_set_loc guard oldpc pc_loc;;
    match zfval with
      | None => no_op
      | Some z => v <- load_Z _ z;
                  zf <- get_flag ZF;
                  op_guard2 <- test eq_op zf v;
                  guard2 <- not op_guard2;
                  if_set_loc guard2 oldpc pc_loc
    end.     

  Definition conv_REP := conv_REP_generic None.
  Definition conv_REPE := conv_REP_generic (Some 0%Z).
  Definition conv_REPNE := conv_REP_generic (Some 1%Z).

  Definition conv_lock_rep (pre: prefix) (i: instr) :=
      match lock_rep pre with 
        | Some lock | None => no_op
        | Some rep => match i with
                        | MOVS _ => conv_REP oldpc
                        | LODS _ => conv_REP oldpc
                        | CMPS _ => conv_REPE oldpc
                        | STOS _ => conv_REP oldpc
                        | _ => raise_error
                      end
        | _ => raise_error
      end.
  *)


(************************)
(* Floating-Point Ops   *)
(************************)

(*
   compilation from FPU instructions to RTL instructions

   Things to check : 
                      -DS segment register used for all memory-related conversions
                      -Values of floating-point constants may be off (had a hard time finding them)
                      -Will include more comprehensive handling of errors and exceptions in next update. For now, 
                       raise_error is used in most exception cases.

    By : Mark Kogan (mak215@lehigh.edu) and Gang Tan
*)
Section X86FloatSemantics.

    Require Import Flocq.Appli.Fappli_IEEE.
    Require Import Flocq.Appli.Fappli_IEEE_bits.
    Require Import Flocq.Core.Fcore.
    Require Import FloatingAux.

(*Start of floating-point conversion functions *)

(*  Definition int_to_bin16 (i : Word.int size16) : binary16 := b16_of_bits (Word.intval size16 i). *)
(*  Definition bin16_to_int (b : binary16) : Word.int size16 := Word.repr (bits_of_b16 b). *)

  Definition int_to_bin32 (i : Word.int size32) : binary32 := b32_of_bits (Word.intval size32 i).
  Definition bin32_to_int (b : binary32) : Word.int size32 := Word.repr (bits_of_b32 b).

  Definition int_to_bin64 (i : Word.int size64) : binary64 := b64_of_bits (Word.intval size64 i).
  Definition bin64_to_int (b : binary64) : Word.int size64 := Word.repr (bits_of_b64 b).

  Definition int_to_de_float (i : Word.int size80) : de_float := de_float_of_bits (Word.intval size80 i).
  Definition de_float_to_int (b : de_float) : Word.int size80 := Word.repr (bits_of_de_float b).

(*  Definition float32_to_int (b : size32) : Word.int size32 := Word.repr (bits_of_b32 b). *)
  Definition string_to_de_float (s : string) := let intval := Word.string_to_int size80 s in int_to_de_float intval.
  Definition s2bf (s : string) := string_to_de_float s.


  Definition s2int80 (s: string) : int size80 := 
    Word.string_to_int size80 s.

  (* Get normal de_float representation to determine sign, then make mantissa the val of i and subtract
     most significant 1 to denormalize, then make exponent the number of significant bits of i. Then combine everything *)
  Definition integer_to_de_float (i : Word.int size80) : de_float := 
     let bin := int_to_de_float i in
     match bin with 
     | B754_zero _ _ s => B754_zero _ _ s
     | B754_infinity _ _ s => B754_infinity _ _ s
     | B754_nan _ _ s pl => B754_nan _ _ s pl
     | B754_finite _ _ s m e _ => 
         let mant_val := Word.intval size80 i in
         let (rec, shifted_m) := shr (Build_shr_record mant_val false false) mant_val 1 in
         let exp_val := Z_of_nat size80 in  (*This probably needs to be replaced with the number of significant bits of i *)
         let joined := join_bits 64 16384 s (shifted_m - 1) exp_val in
         de_float_of_bits joined 
     end.

  Definition enc_rounding_mode (rm: rounding_mode) : Z := 
    (match rm with
       | mode_NE => 0   (* round to nearest even *)
       | mode_DN => 1   (* round down to negative infinity *)
       | mode_UP => 2   (* round up to positive infinity *)
       | mode_ZR => 3   (* round toward zero *)
       | mode_NA => 0   (* dummy, this rounding unused by x86 *)
     end)%Z.

  Inductive fpu_precision_control : Set := 
  | PC_single (* single precision *)
  | PC_reserved
  | PC_double (* double precision *)
  | PC_double_extended (* double extended precision *).

  Definition enc_fpu_precision_control (pc: fpu_precision_control) : Z := 
    (match pc with
      | PC_single => 0
      | PC_reserved => 1
      | PC_double => 2
      | PC_double_extended => 3
     end)%Z.

  Inductive fpu_tag_mode : Set :=
  | TM_valid (* a valid number *)
  | TM_zero (* number zero *)
  | TM_special
  | TM_empty.

  Definition enc_fpu_tag_mode (tm: fpu_tag_mode) : Z := 
    (match tm with
      | TM_valid => 0
      | TM_zero => 1
      | TM_special => 2
      | TM_empty => 3
     end)%Z.

  Definition get_stktop : Conv (rtl_exp size3) := 
    read_loc fpu_stktop_loc.
  Definition get_fpu_rctrl :=
    read_loc fpu_rctrl_loc.
  Definition get_fpu_reg (i: rtl_exp size3) : Conv (rtl_exp size80) := 
    read_array fpu_datareg i.
  Definition get_fpu_tag (i: rtl_exp size3) := 
    read_array fpu_tag i.
  Definition set_stktop (t:rtl_exp size3) := 
    write_loc t fpu_stktop_loc.
  Definition set_stktop_const (t:Z) := 
    r <- load_Z size3 t; set_stktop r.
  Definition set_fpu_flag (fl:fpu_flag) (r: rtl_exp size1) := 
    write_loc r (fpu_flag_loc fl).
  Definition set_fpu_flag_const (fl:fpu_flag) (bit:Z) := 
    r <- load_Z size1 bit; set_fpu_flag fl r.
  Definition set_fpu_ctrl (cf:fpu_ctrl_flag) (r:rtl_exp size1) := 
    write_loc r (fpu_ctrl_flag_loc cf).
  Definition set_fpu_ctrl_const (cf:fpu_ctrl_flag) (bit:Z) := 
    r <- load_Z size1 bit; set_fpu_ctrl cf r.

  Definition set_fpu_rctrl (r:rtl_exp size2) :=
    write_loc r fpu_rctrl_loc.
  Definition set_fpu_rctrl_const (rm: mode) :=
    r <- load_Z _ (enc_rounding_mode rm);
    set_fpu_rctrl r.

  Definition set_fpu_pctrl (r: rtl_exp size2) :=
    write_loc r fpu_pctrl_loc.
  Definition set_fpu_pctrl_const (pc:fpu_precision_control) :=
    r <- load_Z _ (enc_fpu_precision_control pc);
    set_fpu_pctrl r.

  Definition set_fpu_lastInstrPtr (r: rtl_exp size48) := 
    write_loc r fpu_lastInstrPtr_loc.
  Definition set_fpu_lastInstrPtr_const (v:Z) := 
    r <- load_Z size48 v; set_fpu_lastInstrPtr r.

  Definition set_fpu_lastDataPtr (r: rtl_exp size48) := 
    write_loc r fpu_lastDataPtr_loc.
  Definition set_fpu_lastDataPtr_const (v:Z) := 
    r <- load_Z size48 v; set_fpu_lastDataPtr r.

  Definition set_fpu_lastOpcode (r: rtl_exp size11) :=
    write_loc r fpu_lastOpcode_loc.
  Definition set_fpu_lastOpcode_const (v:Z) :=
    r <- load_Z size11 v; set_fpu_lastOpcode r.

  Definition set_fpu_reg (i: rtl_exp size3) (v: rtl_exp size80) :=
    write_array fpu_datareg i v.

  Definition set_fpu_tag (i: rtl_exp size3) (v: rtl_exp size2) := 
    write_array fpu_tag i v.
  Definition set_fpu_tag_const (loc:Z) (tm:fpu_tag_mode) := 
    i <- load_Z _ loc;
    v <- load_Z _ (enc_fpu_tag_mode tm);
    set_fpu_tag i v.

  (* increment the stack top; this is for popping the FPU stack grows downward *)
  Definition inc_stktop := 
    st <- get_stktop;
    one <- load_Z _ 1;
    newst <- arith add_op st one;
    set_stktop newst.

  (* decrement the stack top *)
  Definition dec_stktop := 
    st <- get_stktop;
    one <- load_Z _ 1;
    newst <- arith sub_op st one;
    set_stktop newst.

  (* push a float to the top of the stack *)
  Definition stk_push (f: rtl_exp size80) : Conv unit :=
    dec_stktop;;
    topp <- get_stktop;
    set_fpu_reg topp f.

  (* converting a stack offset to the index of an FPU reg *)
  Definition freg_of_offset (offset: int3) : Conv (rtl_exp size3) :=
    topp <- get_stktop;
    ri <- load_Z _ (Word.unsigned offset);
    arith add_op topp ri.

  Definition undef_fpu_flag (f: fpu_flag) := 
    v <- choose size1; 
    set_fpu_flag f v.

  (* return 1 iff the i-th tag is empty *)
  Definition is_empty_tag (i: rtl_exp size3) : Conv (rtl_exp size1) := 
    tag <- get_fpu_tag i;
    empty_tag <- load_Z _ 3;
    test eq_op tag empty_tag.

  Definition is_nonempty_tag (i: rtl_exp size3) : Conv (rtl_exp size1) := 
    isempty <- is_empty_tag i;
    not isempty.

  Section Float_Test.
    Variable ew mw: positive.
    Variable f : rtl_exp (nat_of_P ew + nat_of_P mw).
    
    Definition test_pos_zero : Conv (rtl_exp size1) :=
      poszero <- load_Z _ 0;
      test eq_op f poszero.

    (* return 1 iff the float is negative zero, which has the sign bit on
       followed by all zero bits. It is the number 2^(ew+mw). *)
    Definition test_neg_zero : Conv (rtl_exp size1) :=
      negzero <- load_Z _ (two_power_nat (nat_of_P mw + nat_of_P ew));
      test eq_op f negzero.

    Definition test_zero : Conv (rtl_exp size1) :=
      isposzero <- test_pos_zero;
      isnegzero <- test_neg_zero;
      arith or_op isposzero isnegzero.

    (* return 1 iff the float is positive infinity, which has the sign bit off,
       exponent bits on, and mantissa bits off. 
       It is the number 2^mw (2^ew - 1). *)
    Definition test_pos_inf : Conv (rtl_exp size1) :=
      posinf <- load_Z _ (two_power_nat (nat_of_P mw) * (two_power_nat (nat_of_P ew) - 1));
      test eq_op f posinf.

    (* return 1 iff the float is negative infinity, which has the sign bit on,
       exponent bits on, and mantissa bits off. 
       It is the number 2^mw (2^(ew+1) - 1). *)
    Definition test_neg_inf : Conv (rtl_exp size1) :=
      neginf <- load_Z _ (two_power_nat (nat_of_P mw) * (two_power_nat (nat_of_P ew + 1) - 1));
      test eq_op f neginf.

    (* return 1 iff the float is positive or negative infinity. *)
    Definition test_inf : Conv (rtl_exp size1) := 
      isposinf <- test_pos_inf;
      isneginf <- test_neg_inf;
      arith or_op isposinf isneginf.

    (* return 1 iff the float is a quite NAN, which has the sign bit unconstrained,
       exponent bits on, and mantissa bits being 1 followed by unconstrained bits.  *)
    Definition test_qnan : Conv (rtl_exp size1) :=
      (* the number with all exponents bits on and the first bit of mantissa on *)
      mask <- load_Z _ (two_power_nat (nat_of_P mw - 1) * (two_power_nat (nat_of_P ew + 1) - 1));
      maskRes <- arith and_op f mask; (* mask away those unconstrained bits *)
      test eq_op maskRes mask.

    (* return 1 iff the float is a signal NAN, which has the sign bit unconstrained,
       exponent bits on, and mantissa bits being 0 followed by unconstrained bits (with at
       least one bit on in those unconstrained bits). *)
    Definition test_snan : Conv (rtl_exp size1) :=
      isinf <- test_inf;
      isnotinf <- not isinf;

      (* the number with all exponents bits on and the first bit of mantissa on *)
      mask <- load_Z _ (two_power_nat (nat_of_P mw - 1) * (two_power_nat (nat_of_P ew + 1) - 1));
      maskRes <- arith and_op f mask; (* mask away those unconstrained bits *)
      expected <- load_Z _ (two_power_nat (nat_of_P mw) * (two_power_nat (nat_of_P ew) - 1));
      is_snan <- test eq_op maskRes expected;

      arith and_op isnotinf is_snan.

    (* return 1 iff the float is a NAN *)
    Definition test_nan : Conv (rtl_exp size1) := 
      isqnan <- test_qnan;
      issnan <- test_snan;
      arith or_op isqnan issnan.

    (* return 1 iff the float is a denomralized finite, which has the sign bit
       unconstrained, exponent bits off, and unconstrained mantissa bits
       (with at least one bit on). *)
    Definition test_denormal : Conv (rtl_exp size1) :=
      iszero <- test_zero;
      isnotzero <- not iszero;
      (* the number with all exponents bits on *)
      mask <- load_Z _ (two_power_nat (nat_of_P mw) * (two_power_nat (nat_of_P ew) - 1));
      maskRes <- arith and_op f mask;
      zero <- load_Z _ 0;
      expZero <- test eq_op maskRes zero;
      arith and_op isnotzero expZero.

    (* return 1 iff the float is a normalized finite, which has the sign bit
       unconstrained, exponent bits greater than 0 and less than 2^mw - 1, 
       and unconstrained mantissa bits. *)
    Definition test_normal_fin : Conv (rtl_exp size1) :=
      (* the number with all exponents bits on *)
      mask <- load_Z _ (two_power_nat (nat_of_P mw) * (two_power_nat (nat_of_P ew) - 1));
      maskRes <- arith and_op f mask;
      zero <- load_Z _ 0;
      iszero <- test eq_op maskRes zero;
      notzero <- not iszero;
      maxexpo <- test eq_op maskRes mask;
      notmaxexpo <- not maxexpo;
      arith and_op notzero notmaxexpo.
    
    (* return 1 iff the float is a finite. *)
    Definition test_fin : Conv (rtl_exp size1) :=
      isdefin <- test_denormal;
      isnorfin <- test_normal_fin;
      arith or_op isdefin isnorfin.

  End Float_Test.


  Definition size63 := 62.
    
  (* convert a 79-bit float to a double-extended float:
     * if the float is pos/neg zero or a denormal, add 0 as the integer significand;
     * if the float is a normal finite or infinity, add 1 as the integer signifcand.
     Note: In those 79 bits, 1 is for the sign, 15 for exponents and 63 for mantissa. *)
  Definition de_float_of_float79 (f: rtl_exp size79) : Conv (rtl_exp size80) :=
    signAndExpo <- first_bits size16 f;
    mantissa <- last_bits size63 f;
    isInf <- test_inf 63 15 f;
    isNorFin <- test_normal_fin 63 15 f;
    intSig <- arith or_op isInf isNorFin;
    r <- concat_bits intSig mantissa;
    concat_bits signAndExpo r.

  (* convert a double-extened float to a float of 79 bits by cutting down 
     integer significand before the floating point.
     Note: The integer siginficand should be consistent with the rules in de_float_of_float79;
         otherwise, the processor treats the numbers as an invalid operand; operating
         on it will generate an exception. *)
  Definition float79_of_de_float (f: rtl_exp size80) : Conv (rtl_exp size79) :=
    signAndExpo <- first_bits size16 f;
    mantissa <- last_bits size63 f;
    concat_bits signAndExpo mantissa.


(* Suman: Convert int to/from de_float *)




(*  Definition int64_of_de_float (f: rtl_exp size80) : Conv (rtl_exp size64) := *)
(*    mantissa <- last_bits size63 f; *)
(*    mantissa. *)

(*  Definition int32_of_de_float (f: rtl_exp size80) : Conv (rtl_exp size32) :=
   signAndExpo <- first_bits size16 f;
   sign <- last_bits size1 signAndExpo;
   mantissa <- last_bits size31 f;
   concat_bits sign mantissa.
*)
(*  Definition de_float_of_int (i: rtl_exp size64) : Conv (rtl_exp size80)
    expo <- int_to_bin16 16 ;
    sign <- first_bits size1 i;
    mantissa <- last_bits size63 i;
    isInf <- test_inf 63 0 i;
    isNorFin <- test_normal_fin 63 0 i;
    intSig <- arith or_op isInf isNorFin;
    r <- concat_bits intSig mantissa;
    concat_bits expo r. *)




  Definition de_float_of_float32 (f: rtl_exp size32) (rm: rtl_exp size2)
    : Conv (rtl_exp size80) := 
    f' <- fcast fw_hyp_float32 fw_hyp_float79 rm f;
    de_float_of_float79 f'.

  Definition de_float_of_float64 (f: rtl_exp size64) (rm: rtl_exp size2)
    : Conv (rtl_exp size80) := 
    f' <- fcast fw_hyp_float64 fw_hyp_float79 rm f;
    de_float_of_float79 f'.

  Definition float32_of_de_float (f: rtl_exp size80) (rm: rtl_exp size2)
    : Conv (rtl_exp size32) := 
    f' <- float79_of_de_float f;
    fcast fw_hyp_float79 fw_hyp_float32 rm f'.

  Definition float64_of_de_float (f: rtl_exp size80) (rm: rtl_exp size2)
    : Conv (rtl_exp size64) := 
    f' <- float79_of_de_float f;
    fcast fw_hyp_float79 fw_hyp_float64 rm f'.

  (* encode the tag bits according to the double-extended float *)
  Definition enc_tag (f: rtl_exp size80) : Conv (rtl_exp size2) := 
    nf <- float79_of_de_float f;
    iszero <- test_zero 15 63 nf;
    isnorfin <- test_normal_fin 15 63 nf;

    enc_valid <- load_Z _ (enc_fpu_tag_mode TM_valid);
    enc_zero <- load_Z _ (enc_fpu_tag_mode TM_zero);
    enc_special <- load_Z _ (enc_fpu_tag_mode TM_special);
    z_or_s <- if_exp iszero enc_zero enc_special;
    if_exp isnorfin enc_valid z_or_s.

  Definition load_ifp_op (pre: prefix) (seg: segment_register) (op: operand)
    : Conv (rtl_exp size32) :=

      match op with
      | Imm_op i => load_int i
      | Reg_op r => load_reg r
      | Address_op a => p1 <- compute_addr a ; load_mem32 seg p1
      | Offset_op off => p1 <- load_int off;
                               load_mem32 seg p1
      end.


  Definition load_fp_op (pre: prefix) (seg: segment_register) (op: fp_operand)
    : Conv (rtl_exp size80) :=
    let sr := get_segment pre seg in
      rm <- get_fpu_rctrl;
      match op with
        | FPS_op i =>
          fi <- freg_of_offset i;
          get_fpu_reg fi
        | FPM32_op a =>
          addr <- compute_addr a;
          val <- load_mem32 sr addr;
          de_float_of_float32 val rm
        | FPM64_op a =>
          addr <- compute_addr a;
          val <- load_mem64 sr addr;
          de_float_of_float64 val rm
        | FPM80_op a =>
          addr <- compute_addr a;
          load_mem80 sr addr
        | FPM16_op _ => 
        (* not possible if loading floats from 16-bit memory *)
          raise_error;; choose size80
      end.
  
  Definition conv_FNCLEX :=
    set_fpu_flag_const F_PE 0;;
    set_fpu_flag_const F_UE 0;;
    set_fpu_flag_const F_OE 0;;
    set_fpu_flag_const F_ZE 0;;
    set_fpu_flag_const F_DE 0;;
    set_fpu_flag_const F_IE 0;;
    set_fpu_flag_const F_ES 0;;
    set_fpu_flag_const F_Busy 0.

  (* In FNINIT, the FPUControlWord is set to 037FH *)
  Definition init_control_word := 
    set_fpu_ctrl_const F_Res15 0;;
    set_fpu_ctrl_const F_Res14 0;;
    set_fpu_ctrl_const F_Res13 0;;
    set_fpu_ctrl_const F_IC 0;;
    set_fpu_rctrl_const mode_NE;;
    set_fpu_pctrl_const PC_double_extended;;
    set_fpu_ctrl_const F_Res6 0;;
    set_fpu_ctrl_const F_Res7 1;;
    set_fpu_ctrl_const F_PM 1;;
    set_fpu_ctrl_const F_UM 1;;
    set_fpu_ctrl_const F_OM 1;;
    set_fpu_ctrl_const F_ZM 1;;
    set_fpu_ctrl_const F_DM 1;;
    set_fpu_ctrl_const F_IM 1.

  (* FNINIT sets the status word to zero *)
  Definition init_status_word := 
    set_fpu_flag_const F_Busy 0;;
    set_fpu_flag_const F_C3 0;;
    set_stktop_const 0;;
    set_fpu_flag_const F_C2 0;;
    set_fpu_flag_const F_C1 0;;
    set_fpu_flag_const F_C0 0;;
    set_fpu_flag_const F_ES 0;;
    set_fpu_flag_const F_SF 0;;
    set_fpu_flag_const F_PE 0;;
    set_fpu_flag_const F_UE 0;;
    set_fpu_flag_const F_OE 0;;
    set_fpu_flag_const F_ZE 0;;
    set_fpu_flag_const F_DE 0;;
    set_fpu_flag_const F_IE 0.

  (* FNINIT sets the tag word to be 0xFFFF *)
  Definition init_tag_word :=
    set_fpu_tag_const 0 TM_empty;;
    set_fpu_tag_const 1 TM_empty;;
    set_fpu_tag_const 2 TM_empty;;
    set_fpu_tag_const 3 TM_empty;;
    set_fpu_tag_const 4 TM_empty;;
    set_fpu_tag_const 5 TM_empty;;
    set_fpu_tag_const 6 TM_empty;;
    set_fpu_tag_const 7 TM_empty.

  (* FNINIT sets all three last pointers to be zero *)
  Definition init_last_ptrs :=
    set_fpu_lastInstrPtr_const 0;;
    set_fpu_lastDataPtr_const 0;;
    set_fpu_lastOpcode_const 0.

  Definition conv_FNINIT :=
    init_control_word;;
    init_status_word;;
    init_tag_word;;
    init_last_ptrs.

  Definition conv_FINCSTP := 
    inc_stktop;;
    (* The C1 flag is set to 0. The C0, C2, and C3 flags are undefined *)
    set_fpu_flag_const F_C1 0;;
    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3.

  Definition conv_FDECSTP := 
    dec_stktop;;
    (* The C1 flag is set to 0. The C0, C2, and C3 flags are undefined *)
    set_fpu_flag_const F_C1 0;;
    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3.

  (* push a float to the top of the stack; set up the corresponding
     tag; return 1 iff overflow *)
  Definition stk_push_and_set_tag (f: rtl_exp size80) 
    : Conv (rtl_exp size1) :=
    stk_push f;;
    topp <- get_stktop;
    tag <- enc_tag f;
    set_fpu_tag topp tag;;
    is_nonempty_tag topp.

  Definition conv_FLD (pre: prefix) (op: fp_operand) :=
     v <- load_fp_op pre DS op; 
     overflow <- stk_push_and_set_tag v;

     (* set up condition codes *)
     set_fpu_flag F_C1 overflow;;
     undef_fpu_flag F_C0;;
     undef_fpu_flag F_C2;;
     undef_fpu_flag F_C3.

  Definition conv_FILD (pre: prefix) (op: fp_operand) :=
     v <- load_fp_op pre DS op;
     overflow <- stk_push_and_set_tag v; (* Suman *)
     (* set up condition codes *)
     set_fpu_flag F_C1 overflow;;
     undef_fpu_flag F_C0;;
     undef_fpu_flag F_C2;;
     undef_fpu_flag F_C3.


  Definition load_stktop : Conv (rtl_exp size80) :=
    topp <- get_stktop;
    get_fpu_reg topp.

  Definition conv_FST (pre: prefix) (op: fp_operand) : Conv unit :=
    topp <- get_stktop;
    rv <- get_fpu_reg topp;

    underflow <- is_empty_tag topp;

    rm <- get_fpu_rctrl;
    let sr := get_segment pre DS in

    (* Imprecision: in the no-underflow case, C1 should be set
       if result was rounded up; cleared otherwise *)
    v <- choose size1;
    zero <- load_Z _ 0;
    c1 <- if_exp underflow zero v;
    set_fpu_flag F_C1 c1;;

    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3;;

    match op with
      | FPS_op i => (* Copy st(0) to st(i) *)
        fi <- freg_of_offset i;
        set_fpu_reg fi rv

      | FPM16_op a => raise_error

      | FPM32_op a =>  (* Copy st(0) to 32-bit memory *)
        addr <- compute_addr a;
        f32 <- float32_of_de_float rv rm;
        set_mem32 sr f32 addr

      | FPM64_op a =>  (* Copy st(0) to 64-bit memory *)
        addr <- compute_addr a;
        f64 <- float64_of_de_float rv rm;
        set_mem64 sr f64 addr

      | FPM80_op a =>  (* Copy st(0) to 80-bit memory *)
        addr <- compute_addr a;
        set_mem80 sr rv addr
    end.

  Definition conv_FIST (pre: prefix) (op: fp_operand) : Conv unit :=
    topp <- get_stktop;
    rv <- get_fpu_reg topp;

    underflow <- is_empty_tag topp;

    rm <- get_fpu_rctrl;
    let sr := get_segment pre DS in

    (* Imprecision: in the no-underflow case, C1 should be set
       if result was rounded up; cleared otherwise *)
    v <- choose size1;
    zero <- load_Z _ 0;
    c1 <- if_exp underflow zero v;
    set_fpu_flag F_C1 c1;;

    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3;;

    match op with
      | FPS_op i => (* Copy st(0) to st(i) *)
        fi <- freg_of_offset i;
        set_fpu_reg fi rv

      | FPM16_op a => raise_error

      | FPM32_op a =>  (* Copy st(0) to 32-bit memory *)
      addr <- compute_addr a;
      f32 <- float32_of_de_float rv rm;
      set_mem32 sr f32 addr

      | FPM64_op a =>  (* Copy st(0) to 64-bit memory *)
      addr <- compute_addr a;
        f64 <- float64_of_de_float rv rm;
        set_mem64 sr f64 addr

      | FPM80_op a =>  (* Copy st(0) to 80-bit memory *)
        addr <- compute_addr a;
	set_mem80 sr rv addr

    end.

  (* stack pop and set tag *)
  Definition stk_pop_and_set_tag := 
    topp <- get_stktop;
    tag_emp <- load_Z _ (enc_fpu_tag_mode TM_empty);
    set_fpu_tag topp tag_emp;;
    inc_stktop.

  Definition conv_FSTP (pre: prefix) (op: fp_operand) :=
    conv_FST pre op;;
    stk_pop_and_set_tag.

  Definition conv_FISTP (pre: prefix) (op: fp_operand) :=
    conv_FIST pre op;;
    stk_pop_and_set_tag.


  (* gtan: the following constants are gotten by executing 
     machine-code sequences like "finit; fld1; fstp mem" on a real machine *)
  (* pos1: 0x3F 0xFF 0x80 0x00 0x00 0x00 0x00 0x00 0x00 0x00 *)
  Definition pos1 := 
    s2int80 ("00111111" ++ "11111111" ++ "10000000" ++ "00000000" ++ "00000000" ++
             "00000000" ++ "00000000" ++ "00000000" ++ "00000000" ++ "00000000").

  (* log(2,10): 0x40 0x00 0xD4 0x9A 0x78 0x4B 0xCD 0x1B 0x8A 0xFE *)
  Definition log2_10 := 
    s2int80 ("01000000" ++ "00000000" ++ "11010100" ++ "10011010" ++ "01111000" ++
             "01001011" ++ "11001101" ++ "00011011" ++ "10001010" ++ "11111110").


  (* log(2,e): 0x3F 0xFF 0xB8 0xAA 0x3B 0x29 0x5C 0x17 0xF0 0xBC *)
  Definition log2_e := 
    s2int80 ("00111111" ++ "11111111" ++ "10111000" ++ "10101010" ++ "00111011" ++
             "00101001" ++ "01011100" ++ "00010111" ++ "11110000" ++ "10111100").

  (* pi: 0x40 0x00 0xC9 0x0F 0xDA 0xA2 0x21 0x68 0xC2 0x35 *)
  Definition pi :=
    s2int80 ("01000000" ++ "00000000" ++ "11001001" ++ "00001111" ++ "11011010" ++
             "10100010" ++ "00100001" ++ "01101000" ++ "11000010" ++ "00110101").

  (* log(10,2): 0x3F 0xFD 0x9A 0x20 0x9A 0x84 0xFB 0xCF 0xF7 0x99 *)
  Definition log10_2 := 
    s2int80 ("00111111" ++ "11111101" ++ "10011010" ++ "00100000" ++ "10011010" ++
             "10000100" ++ "11111011" ++ "11001111" ++ "11110111" ++ "10011001").

  (* log(e,2): 0x3F 0xFE 0xB1 0x72 0x17 0xF7 0xD1 0xCF 0x79 0xAC *)
  Definition loge_2 := 
    s2int80 ("00111111" ++ "11111110" ++ "10110001" ++ "01110010" ++  "00010111" ++
             "11110111" ++ "11010001" ++ "11001111" ++ "01111001" ++ "10101100").

  Definition conv_load_fpconstant (c: int size80) : Conv unit :=
    r <- load_int c;
    overflow <- stk_push_and_set_tag r;
    set_fpu_flag F_C1 overflow;;
    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3.
    
  Definition conv_FLDZ : Conv unit := conv_load_fpconstant (Word.repr 0).
  Definition conv_FLD1 : Conv unit := conv_load_fpconstant pos1.
  Definition conv_FLDPI : Conv unit := conv_load_fpconstant pi.
  Definition conv_FLDL2T : Conv unit := conv_load_fpconstant log2_10.
  Definition conv_FLDL2E : Conv unit := conv_load_fpconstant log2_e.
  Definition conv_FLDLG2 : Conv unit :=conv_load_fpconstant log10_2.
  Definition conv_FLDLN2 : Conv unit := conv_load_fpconstant loge_2.

  (* floating-point operations of double-extended precision *)
  Definition farith_de (op: float_arith_op) (rm:rtl_exp size2) 
    (e1 e2: rtl_exp size80) :=
         e1' <- float79_of_de_float e1;
         e2' <- float79_of_de_float e2;
         res <- farith_float79 op rm e1' e2';
         de_float_of_float79 res.


  Definition conv_ifarith (fop: float_arith_op) (noreverse: bool)
    (pre: prefix) (zerod: bool) (op: operand) : Conv unit :=
    iopv <- load_ifp_op pre DS op;
    rm <- get_fpu_rctrl;
    opv <- de_float_of_float32 iopv rm;
    topp <- get_stktop;
    st0 <- get_fpu_reg topp;
    underflow <- is_empty_tag topp;    

    res <- match zerod, noreverse with
             | true, true => farith_de fop rm st0 opv
             | false, true => farith_de fop rm opv st0
             | true, false => farith_de fop rm opv st0
             | false, false => farith_de fop rm st0 opv
           end;

    ires <- float32_of_de_float res rm;


    (* Imprecision: in the no-underflow case, C1 should be set
       if result was rounded up; cleared otherwise *)
    v <- choose size1;
    zero <- load_Z _ 0;
    c1 <- if_exp underflow zero v;
    set_fpu_flag F_C1 c1;;

    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3;;

    match op with
      | Imm_op _ => raise_error
      | Reg_op r => set_reg ires r
      | Address_op a => addr <- compute_addr a ; set_mem32 DS ires addr
      | Offset_op off => addr <- load_int off;
                                 set_mem32 DS ires addr
    end.

  Definition conv_farith (fop: float_arith_op) (noreverse: bool)
    (pre: prefix) (zerod: bool) (op: fp_operand) : Conv unit :=
    opv <- load_fp_op pre DS op; 
    topp <- get_stktop;
    st0 <- get_fpu_reg topp;
    underflow <- is_empty_tag topp;
    rm <- get_fpu_rctrl;

    res <- match zerod, noreverse with
             | true, true => farith_de fop rm st0 opv
             | false, true => farith_de fop rm opv st0
             | true, false => farith_de fop rm opv st0
             | false, false => farith_de fop rm st0 opv
           end;

    (* Imprecision: in the no-underflow case, C1 should be set
       if result was rounded up; cleared otherwise *)
    v <- choose size1;
    zero <- load_Z _ 0;
    c1 <- if_exp underflow zero v;
    set_fpu_flag F_C1 c1;;

    undef_fpu_flag F_C0;;
    undef_fpu_flag F_C2;;
    undef_fpu_flag F_C3;;

    match zerod, op with
      | true, FPS_op _ 
      | true, FPM32_op _ 
      | true, FPM64_op _ => (* ST(0) is the destination *)
        set_fpu_reg topp res

      | false, FPS_op i => (* ST(i) is the detination *)
        fi <- freg_of_offset i;
        set_fpu_reg fi res

      | _, _ => raise_error
    end.

  (* ST(i) <- ST(i) fop ST(0) and pop the stack top *)
   Definition conv_farith_and_pop (fop: float_arith_op) (noreverse: bool) 
    (pre: prefix) (op : fp_operand)
     : Conv unit :=
     match op with
       | FPS_op i => 
         conv_farith fop noreverse pre false op;;
         stk_pop_and_set_tag
       | _ => raise_error
   end.
  
  Definition conv_FADD := conv_farith fadd_op true.
  Definition conv_FSUB := conv_farith fsub_op true. 
  Definition conv_FMUL := conv_farith fmul_op true.
  Definition conv_FDIV := conv_farith fdiv_op true.

  Definition conv_FIADD := conv_ifarith fadd_op true.
  Definition conv_FISUB := conv_ifarith fsub_op true.
  Definition conv_FIMUL := conv_ifarith fmul_op true.
  Definition conv_FIDIV := conv_ifarith fdiv_op true.


  Definition conv_FADDP := conv_farith_and_pop fadd_op true.
  Definition conv_FSUBP := conv_farith_and_pop fsub_op true.
  Definition conv_FMULP := conv_farith_and_pop fmul_op true.
  Definition conv_FDIVP := conv_farith_and_pop fdiv_op true.

  Definition conv_FSUBR := conv_farith fsub_op false.
  Definition conv_FDIVR := conv_farith fdiv_op false.

  Definition conv_FISUBR := conv_ifarith fsub_op false.
  Definition conv_FIDIVR := conv_ifarith fdiv_op false.

  Definition conv_FSUBRP := conv_farith_and_pop fsub_op false.
  Definition conv_FDIVRP := conv_farith_and_pop fdiv_op false.


(*  Definition conv_FCMOV (pre: prefix) (cc: condition_type) (op: fp_operand) : Conv unit :=  (* Suman *)
    opv <- load_fp_op pre DS op;
    topp <- get_stktop;

    cc <- compute_cc cc;

    tmp1 <- fcast_rtl_exp _ opv;
    tmp <- if_exp cc opv topp;

    match op with
      | FPS_op _
      | FPM32_op _
      | FPM64_op _ => set_fpu_reg tmp opv
      | _ => raise_error

    end.
*)


(*  
  Definition conv_simple_integer_arith (st_i : operand) 
        (operation : pseudo_reg size80 -> Conv (pseudo_reg size80)) : Conv unit := 
     match st_i with 
     | Address_op addr =>
     (* let (d, b, i) := addr in  eventually going to have to figure out how to differentiate between size16 and size32 memory *)
       a <- compute_addr addr;
       loadaddr <- load_mem32 SS a;
       let (lval) := loadaddr in
       let intlval := Word.repr lval in
       let val := integer_to_bin80 intlval in
       int_operation (ps_reg size80 (bits_of_b80 val)) At 
     end.
*)

(* Floating-point Comparisons *)
(*   gtan: cannot use Rcompare here, no Ocaml code can be extracted *)
   Definition float_compare (a b : de_float) :=
      let aR := B2R 64 16384 a in
      let bR := B2R 64 16384 b in
      Rcompare aR bR.

(* Set appropriate CC flags that indicate the result of the comparison *)
   Definition set_CC_flags (comp : comparison) : Conv unit := 
       match comp with 
       | Lt => set_fpu_flag_const F_C3 0;; set_fpu_flag_const F_C2 0;; set_fpu_flag_const F_C0 1
       | Gt => set_fpu_flag_const F_C3 0;; set_fpu_flag_const F_C2 0;; set_fpu_flag_const F_C0 0 
       | Eq => set_fpu_flag_const F_C3 1;; set_fpu_flag_const F_C2 0;; set_fpu_flag_const F_C0 0
     (*  | Un => set_fpu_flag_const F_C3 1;; set_fpu_flag_const F_C2 1;; set_fpu_flag_const F_C0 1 *)
       end.


Definition conv_FCOM (op1: option fp_operand) :=
   topp <- get_stktop;
   st0  <- get_fpu_reg topp;
   rm <- get_fpu_rctrl;
     match op1 with 
      | None => undef_fpu_flag F_C3
      | Some op =>
          match op with
            | FPM32_op adr => 
                addr <- compute_addr adr;
                val <- load_mem32 DS addr;
                d_val <- de_float_of_float32 val rm;
                (*let compval := float_compare st0_f d_val_f in *)
               (* set_CC_flags _ *)
                  undef_fpu_flag F_C3

            | FPM64_op adr =>
                addr <- compute_addr adr;
                val <- load_mem64 DS addr;
                d_val <- de_float_of_float64 val rm;
                (*let compval := float_compare st0_f d_val_f in *)
                (* set_CC_flags _ *)
      	        undef_fpu_flag F_C3

            |_ => undef_fpu_flag F_C3
          end

      end.

Definition conv_FICOM (op1: option fp_operand) :=
   topp <- get_stktop;
   st0  <- get_fpu_reg topp;
   rm <- get_fpu_rctrl;
     match op1 with
      | None => undef_fpu_flag F_C3
      | Some op =>
          match op with
            | FPM32_op adr =>
                addr <- compute_addr adr;
                val <- load_mem32 DS addr;
                d_val <- de_float_of_float32 val rm;
                (*let compval := float_compare st0_f d_val_f in *)
               (* set_CC_flags _ *)
                  undef_fpu_flag F_C3

            | FPM64_op adr =>
                addr <- compute_addr adr;
                val <- load_mem64 DS addr;
                d_val <- de_float_of_float64 val rm;
                (*let compval := float_compare st0_f d_val_f in *)
                (* set_CC_flags _ *)
                undef_fpu_flag F_C3

            |_ => undef_fpu_flag F_C3
          end

      end.
   



(* Definition conv_FCOM (op1: option fp_operand) :=  *)
(*      topp <- get_stacktop; *)
(*      zero <- load_Z size3 0; *)
(*      onee <- load_Z size3 1; *)
(*      st0 <- load_from_stack_i topp zero; *)
(*      let (st0val) := st0 in *)
(*      let binst0 := b80_of_bits st0val in *)
(*      match op1 with  *)
(*      | None => (* Compare st(0) to st(1) *) *)
(* 	 st1 <- load_from_stack_i topp onee; *)
(*          let (st1val) := st1 in *)
(*          let compval := float_compare binst0 (b80_of_bits st1val) in *)
(*          set_CC_flags compval *)
         	 
(*      | Some op1 => *)
(* 	match op1 with *)
(* 	| FPS_op r => *)
(*             stI <- load_fpu_reg (fpu_from_int r topp); *)
(*             let (stIval) := stI in *)
(*             let compval := float_compare binst0 (b80_of_bits stIval) in *)
(*             set_CC_flags compval *)

(* 	| FPM32_op adr =>  *)
(*             addr <- compute_addr adr;  *)
(*             val <- load_mem32 DS addr; *)

(*             let int_val := psreg_to_int val in *)
(*             let b32_val := int_to_bin32 int_val in *)
(*             let conv_val := b32_to_b80 b32_val in *)
(*             let psreg_stI := int_to_psreg (bin80_to_int conv_val) in *)
(*             let (stIval) := psreg_stI in *)
(*             let compval := float_compare binst0 (b80_of_bits stIval) in *)
(*             set_CC_flags compval *)
(*         | FPM64_op adr => *)
(*             addr <- compute_addr adr;  *)
(*             val <- load_mem64 DS addr; *)

(*             let int_val := psreg_to_int val in *)
(*             let b64_val := int_to_bin64 int_val in *)
(*             let conv_val := b64_to_b80 b64_val in *)
(*             let psreg_stI := int_to_psreg (bin80_to_int conv_val) in *)
(*             let (stIval) := psreg_stI in *)
(*             let compval := float_compare binst0 (b80_of_bits stIval) in *)
(*             set_CC_flags compval *)
(* 	| _ => set_CC_unordered *)
(* 	end *)
(*      end. *)

Definition conv_FCOMP (op1 : option fp_operand) :=
         conv_FCOM op1;;
         stk_pop_and_set_tag.



Definition conv_FCOMPP :=
     conv_FCOMP (None);;
     stk_pop_and_set_tag.


Definition conv_FICOMP (op1 : option fp_operand) :=
         conv_FICOM op1;;
         stk_pop_and_set_tag.



Definition conv_FICOMPP :=
     conv_FICOMP (None);;
     stk_pop_and_set_tag.



(* Definition conv_FCOMPP :=  *)
(*     conv_FCOMP (None);; *)
   
(*     toploc <- get_stacktop; *)
(*     empty <- load_Z size2 3; *)
(*     update_tag toploc empty;; *)
(*     conv_FINCSTP. *)

End X86FloatSemantics.

  Definition instr_to_rtl (pre: prefix) (i: instr) :=
    runConv 
    (check_prefix pre;;
     match i with
         | AND w op1 op2 => conv_AND pre w op1 op2
         | OR w op1 op2 => conv_OR pre w op1 op2
         | XOR w op1 op2 => conv_XOR pre w op1 op2
         | TEST w op1 op2 => conv_TEST pre w op1 op2
         | NOT w op1 => conv_NOT pre w op1
         | INC w op1 => conv_INC pre w op1
         | DEC w op1 => conv_DEC pre w op1
         | ADD w op1 op2 => conv_ADD pre w op1 op2
         | ADC w op1 op2 => conv_ADC pre w op1 op2
         | CMP w op1 op2 => conv_CMP pre w op1 op2
         | SUB w op1 op2 => conv_SUB pre w op1 op2
         | SBB w op1 op2 => conv_SBB pre w op1 op2
         | NEG w op1 => conv_NEG pre w op1 
         | DIV w op => conv_DIV pre w op
         | AAA => conv_AAA_AAS add_op
         | AAS => conv_AAA_AAS sub_op
         | AAD => conv_AAD
         | AAM => conv_AAM
         | DAA => conv_DAA_DAS (add_op) (@testcarryAdd size8)
         | DAS => conv_DAA_DAS (sub_op) (@testcarrySub size8)
         | HLT => conv_HLT pre
         | IDIV w op => conv_IDIV pre w op
         | IMUL w op1 op2 i => conv_IMUL pre w op1 op2 i
         | MUL w op  => conv_MUL pre w op
         | SHL w op1 op2 => conv_SHL pre w op1 op2
         | SHR w op1 op2 => conv_SHR pre w op1 op2
         | SHLD op1 op2 ri => conv_SHLD pre op1 op2 ri
         | SHRD op1 op2 ri => conv_SHRD pre op1 op2 ri
         | SAR w op1 op2 => conv_SAR pre w op1 op2
         | BSR op1 op2 => conv_BSR pre op1 op2
         | BSF op1 op2 => conv_BSF pre op1 op2
         | BT op1 op2 => conv_BT false true pre op1 op2
         | BTC op1 op2 => conv_BT false false pre op1 op2
         | BTS op1 op2 => conv_BT true true pre op1 op2
         | BTR op1 op2 => conv_BT true false pre op1 op2
         | BSWAP r => conv_BSWAP pre r
         | CWDE => conv_CWDE pre
         | CDQ => conv_CDQ pre
         | MOV w op1 op2 => conv_MOV pre w op1 op2 
         | CMOVcc ct op1 op2 => conv_CMOV pre true ct op1 op2 
         | MOVZX w op1 op2 => conv_MOVZX pre w op1 op2 
         | MOVSX w op1 op2 => conv_MOVSX pre w op1 op2 
         | XCHG w op1 op2 => conv_XCHG pre w op1 op2 
         | XADD w op1 op2 => conv_XADD pre w op1 op2 
         | CLC => conv_CLC
         | CLD => conv_CLD
         | STD => conv_STD
         | STC => conv_STC
         | MOVS w => conv_MOVS pre w
         | CMPXCHG w op1 op2 => conv_CMPXCHG pre w op1 op2
         | CMPS w => conv_CMPS pre w
         | STOS w => conv_STOS pre w
         | LEA op1 op2 => conv_LEA pre op1 op2
         | SETcc ct op => conv_SETcc pre ct op
         | CALL near abs op1 sel => conv_CALL pre near abs op1 sel
         | LEAVE => conv_LEAVE pre
         | POP op => conv_POP pre op
         | POPA => conv_POPA pre
         | PUSH w op => conv_PUSH pre w op
         | PUSHA => conv_PUSHA pre
         | RET ss disp => conv_RET pre ss disp
         | ROL w op1 op2 => conv_ROL pre w op1 op2
         | ROR w op1 op2 => conv_ROR pre w op1 op2
         | RCL w op1 op2 => conv_RCL pre w op1 op2  
         | RCR w op1 op2 => conv_RCR pre w op1 op2  
         | LAHF => conv_LAHF
         | SAHF => conv_SAHF
         | CMC => conv_CMC
         | JMP near abs op1 sel => conv_JMP pre near abs op1 sel
         | Jcc ct disp => conv_Jcc pre ct disp 
         | LOOP disp => conv_LOOP pre false false disp
         | LOOPZ disp => conv_LOOP pre true true disp
         | LOOPNZ disp => conv_LOOP pre true false disp
         | NOP _ => ret tt

         (* the following instructions are not modeled at this point *)
         | SCAS _ | BOUND _ _ | CLI | CLTS | CPUID | LAR _ _ | LGS _ _ 
         | MOVCR _ _ _ | MOVDR _ _ _ | MOVSR _ _ _ | MOVBE _ _ 
         | POPF | PUSHSR _ | PUSHF
         | RDMSR | RDPMC | RDTSC | RDTSCP | RSM
         | SGDT _ | SIDT _ | SLDT _ | SMSW _ 
         | STI | STR _ | WBINVD 
           => raise_trap

         (*Floating-point conversions; comment out the semantics 
           of floating-point instruction as it has not been tested. *)
         (* | F2XM1 => conv_F2XM1 pre *)
         (* | FABS => conv_FABS *)
         (* | FADD d op1 => conv_FADD pre d op1 *)
         (* | FADDP op1 => conv_FADDP pre op1 *)
         (* | FBLD op1 => conv_FBLD pre op1 *)
         (* | FBSTP op1 => conv_FBSTP pre op1 *)
         (* | FCHS => conv_FCHS  *)
         (* | FCOM op1 => conv_FCOM op1 *)
         (* | FCOMP op1 => conv_FCOMP op1 *)
         (* | FCOMPP => conv_FCOMPP *)
         (* | FCOMIP op1 => conv_FCOMIP pre op1 *)
         (* | FCOS => conv_FCOS      *)
         (* | FDECSTP => conv_FDECSTP *)
         (* | FDIV d op => conv_FDIV pre d op *)
         (* | FDIVP op => conv_FDIVP pre op *)
         (* | FDIVR d op => conv_FDIVR pre d op *)
         (* | FDIVRP op => conv_FDIVRP pre op *)
         (* | FFREE : conv_FFREE pre op1 *)
(*         | FIADD d op1 => conv_FIADD pre op1 *)
         (* | FICOM : conv_FICOM pre op1 *)
         (* | FICOMP : conv_FICOMP pre op1 *)
         (* | FILD : conv_FILD pre op1 *)
         (* | FIMUL : conv_FIMUL pre op1 *)
         (* | FINCSTP => conv_FINCSTP *)
         (* | FIST : conv_FIST *)
         (* | FISTP : conv_FISTP *)
         (* | FISUB : conv_FISUB *)
         (* | FISUBR : conv_FISUBR *)
         (* | FLD op => conv_FLD pre op *)
         (* | FLD1 => conv_FLD1 *)
         (*  | FLDCW : conv_FLDCW
         | FLDENV : conv_FLDENV  *)
         (* | FLDL2E => conv_FLDL2E *)
         (* | FLDL2T => conv_FLDL2T *)
         (* | FLDLG2 => conv_FLDLG2 *)
         (* | FLDLN2 => conv_FLDLN2 *)
         (* | FLDPI => conv_FLDPI *)
         (* | FLDZ => conv_FLDZ *)
         (* | FMUL d op1 => conv_FMUL pre d op1 *)
         (* | FMULP op1 => conv_FMULP pre op1 *)
         (* | FNCLEX => conv_FNCLEX  *)
         (* | FNINIT => conv_FNINIT *)
       (*  | FNOP : conv_FNOP
         | FNSTCW => conv_FNSTCW
         | FPATAN : conv_FPATAN
         | FPREM : conv_FPREM
         | FPREM1 : conv_FPREM1
         | FPTAN : conv_FPTAN
         | FRNDINT : conv_FRNDINT
         | FRSTOR : conv_FRSTOR pre op1
         | FSAVE : conv_FSAVE pre op1
         | FSCALE : conv_FSCALE
         | FSIN : conv_FSIN
         | FSINCOS : conv_FSINCOS
         | FSQRT : conv_FSQRT *)
         (* | FST op1 => conv_FST pre op1 *)
        (* | FSTCW : conv_FSTCW pre op1
         | FSTENV : conv_FSTENV pre op1 *)
         (* | FSTP op1 => conv_FSTP pre op1 *)
       (* | FSTSW : conv_FSTSW pre op1     *)
         (* | FSUB d op1 => conv_FSUB pre d op1 *)
         (* | FSUBP op1 => conv_FSUBP pre op1 *)
         (* | FSUBR d op => conv_FSUBR pre d op *)
         (* | FSUBRP op => conv_FSUBRP pre op *)
(*         | FTST : conv_FTST
         | FUCOM : conv_FUCOM pre op1
         | FUCOMP : conv_FUCOMP pre op1
         | FUCOMPP : conv_FUCOMPP
         | FUCOMI : conv_FUCOMI pre op1
         | FUCOMIP : conv_FUCOMIP pre op1
         | FXAM : conv_FXAM
         | FXCH : conv_FXCH pre op1
         | FXTRACT : conv_FXTRACT
         | FYL2X : conv_FYL2X
         | FYL2XP1 : conv_FYL2XP1
         | FWAIT : conv_FWAIT     *)
         | _ => raise_error 
    end
    ).

End X86_Compile.

Local Open Scope Z_scope.
Local Open Scope monad_scope.
Import X86_Compile.
Import X86_RTL.
Import X86_MACHINE.

Definition in_seg_bounds (s: segment_register) (o1: int32) : RTL bool :=
  seg_limit <- get_loc (seg_reg_limit_loc s);
  ret (Word.lequ o1 seg_limit).

Definition in_seg_bounds_rng (s: segment_register) (o1: int32) 
  (offset: int32) : RTL bool :=
  seg_limit <- get_loc (seg_reg_limit_loc s);
  let o2 := Word.add o1 offset in
  ret (andb (Word.lequ o1 o2)
            (Word.lequ o2 seg_limit)).

(** fetch n bytes starting from the given location. *)
Fixpoint fetch_n (n:nat) (loc:int32) (r:rtl_state) : list int8 := 
  match n with 
    | 0%nat => nil
    | S m => 
      AddrMap.get loc (rtl_memory r) :: 
        fetch_n m (Word.add loc (Word.repr 1)) r
  end.

(** Go into a loop trying to parse an instruction.  We iterate at most [n] times,
    and at least once.  This returns the first successful match of the parser
    as well as the length (in bytes) of the matched instruction.  Right now, 
    [n] is set to 15 but it should probably be calculated as the longest possible
    match for the instruction parsers.  The advantage of this routine over the
    previous one is two-fold -- first, we are guaranteed that the parser only
    succeeds when we pass in bytes.  Second, we only fetch bytes that are
    needed, so we don't have to worry about running out side a segment just
    to support parsing.
*)
Fixpoint parse_instr_aux
  (n:nat) (loc:int32) (len:positive) (ps:Decode.ParseState_t) : 
  RTL ((prefix * instr) * positive) := 
  match n with 
    | 0%nat => Fail _ 
    | S m => b <- get_byte loc ; 
             match Decode.parse_byte ps b with 
               | (ps', nil) => 
                 parse_instr_aux m (Word.add loc (Word.repr 1)) (len + 1) ps'
               | (_, v::_) => ret (v,len)
             end
  end.

Definition parse_instr' (ps:Decode.ParseState_t) 
           (pc:int32) : RTL ((prefix * instr) * positive) :=
  seg_start <- get_loc (seg_reg_start_loc CS);
  (* add the PC to it *)
  let real_pc := Word.add seg_start pc in
  parse_instr_aux 15 real_pc 1 ps.

Import Decode.ABSTRACT_INI_DECODER_STATE.

Definition parse_instr := parse_instr' abs_ini_decoder_state.

(** Fetch an instruction at the location given by the program counter.  Return
    the abstract syntax for the instruction, along with a count in bytes for 
    how big the instruction is.  We fail if the bits do not parse, or have more
    than one parse.  We should fail if these locations aren't mapped, but we'll
    deal with that later. *)
Definition fetch_instruction (pc:int32) : RTL ((prefix * instr) * positive) :=
  [pi, len] <- parse_instr pc;
  in_bounds_rng <- in_seg_bounds_rng CS pc (Word.repr (Zpos len - 1));
  if (in_bounds_rng) then ret (pi,len)
  else Trap _.

Fixpoint RTL_step_list l :=
  match l with
    | nil => ret tt
    | i::l' => interp_rtl i;; RTL_step_list l'
  end.

Definition check_rep_instr (ins:instr) : RTL unit :=
  match ins with
    | MOVS _ | STOS _ | CMPS _ | SCAS _ => ret tt
    | _ => Fail _
  end.

Definition run_rep 
  (pre:prefix) (ins: instr) (default_new_pc : int32) : RTL unit := 
  check_rep_instr ins;;
  ecx <- get_loc (reg_loc ECX);
  if (Word.eq ecx Word.zero) then set_loc pc_loc default_new_pc
    else 
      set_loc (reg_loc ECX) (Word.sub ecx Word.one);;
      RTL_step_list (X86_Compile.instr_to_rtl pre ins);;
      ecx' <- get_loc (reg_loc ECX);
      (if (Word.eq ecx' Word.zero) then 
        set_loc pc_loc default_new_pc
        else ret tt);;
       (* For CMPS we also need to break from the loop if ZF = 0 *)
      match ins with
        | CMPS _ =>
          zf <- get_loc (flag_loc ZF);
          if (Word.eq zf Word.zero) then set_loc pc_loc default_new_pc
          else ret tt
        | _ => ret tt
      end.

Definition step : RTL unit := 
  pc <- get_loc pc_loc ; 
  (* check if pc is in the code region; 
     different from the range checks in fetch_instruction; 
     this check makes sure the machine safely traps when pc is 
     out of bounds so that there is no need to fetch an instruction *)
  pc_in_bounds <- in_seg_bounds CS pc;
  if (pc_in_bounds) then 
    [pi,length] <- fetch_instruction pc ; 
    let (pre, instr) := pi in
    let default_new_pc := Word.add pc (Word.repr (Zpos length)) in
      match lock_rep pre with
        | Some rep (* We'll only allow rep, not lock or repn *) =>
          run_rep pre instr default_new_pc
        | None => set_loc pc_loc default_new_pc;; 
                  RTL_step_list (X86_Compile.instr_to_rtl pre instr)
        | _ => Trap _ 
      end
  else Trap _.

Definition step_immed (m1 m2: rtl_state) : Prop := step m1 = (Okay_ans tt, m2).
Notation "m1 ==> m2" := (step_immed m1 m2) (at level 55, m2 at next level).
Require Import Relation_Operators.
Definition steps := clos_refl_trans rtl_state step_immed.
Notation "m1 '==>*' m2" := (steps m1 m2) (at level 55, m2 at next level).

(* Definition no_prefix : prefix := mkPrefix None None false false. *)
(* Compute (runConv (string_op_reg_shift EAX no_prefix false)). *)

