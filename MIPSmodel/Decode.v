(* Copyright (c) 2011. Greg Morrisett, Gang Tan, Joseph Tassarotti, 
   Jean-Baptiste Tristan, and Edward Gan.

   This file is part of RockSalt.

   This file is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of
   the License, or (at your option) any later version.
*)

(* This file provides simple bit-level parsing combinators for disassembling
 * MIPS 32-bit binaries. *)
Require Coqlib.
Require Import Coq.Init.Logic.
Require Import Bool.
Require Import List.
Require Import String.
Require Import Maps.
Require Import Ascii.
Require Import ZArith.
Require Import Eqdep.
Require Import Parser.
Unset Automatic Introduction.
Set Implicit Arguments.
Local Open Scope Z_scope.


Require ExtrOcamlString.
Require ExtrOcamlNatBigInt.


(* a module for generating the parser for x86 instructions *)
Module MIPS_PARSER_ARG.
  Require Import MIPSSyntax.
  Require Import Bits.
  
  Definition char_p : Set := bool.
  Definition char_eq : forall (c1 c2:char_p), {c1=c2}+{c1<>c2} := bool_dec.
  Inductive type : Set := 
  | Int_t : type
  | Register_t : type
  | Shamt5_t : type
  | Imm16_t : type
  | Target26_t : type
  | Instruction_t : type
  | Pair_t (t1 t2: type) : type
  | Unit_t : type
.

  Definition tipe := type.
  Definition tipe_eq : forall (t1 t2:tipe), {t1=t2} + {t1<>t2}.
    intros ; decide equality.
  Defined.

  Definition int5 := Word.int 4.
  Definition int26 := Word.int 25.

  Fixpoint tipe_m (t:tipe) := 
    match t with 
      | Int_t => Z
      | Register_t => register
      | Shamt5_t => int5
      | Imm16_t => int16
      | Target26_t => int26
      | Instruction_t => instr
      | Pair_t t1 t2 => ((tipe_m t1) * (tipe_m t2))%type
      | Unit_t => unit
    end.
End MIPS_PARSER_ARG.


Module MIPS_PARSER.
  Module MIPS_BASE_PARSER := Parser.Parser(MIPS_PARSER_ARG).
  Require Import MIPSSyntax.
  Require Import Bits.
  Import MIPS_PARSER_ARG.
  Import MIPS_BASE_PARSER.

  Definition int_t := tipe_t Int_t.
  Definition register_t := tipe_t Register_t.
  Definition instruction_t := tipe_t Instruction_t.
  Definition shamt5_t := tipe_t Shamt5_t.
  Definition imm16_t := tipe_t Imm16_t.
  Definition target26_t := tipe_t Target26_t.
  Definition myunit_t := tipe_t Unit_t.

  (* combinators for building parsers *)
  Definition bit(x:bool) : parser char_t := Char_p x.
  Definition never t : parser t := Zero_p t.
  Definition always t (x:result_m t) : parser t := @Map_p unit_t t (fun (_:unit) => x) Eps_p.
  Definition alt t (p1 p2:parser t) : parser t := Alt_p p1 p2.
  Definition alts t (ps: list (parser t)) : parser t := List.fold_right (@alt t) (@never t) ps.
  Definition map t1 t2 (p:parser t1) (f:result_m t1 -> result_m t2) : parser t2 := 
    @Map_p t1 t2 f p.
  Implicit Arguments map [t1 t2].
  Definition seq t1 t2 (p1:parser t1) (p2:parser t2) : parser (pair_t t1 t2) := Cat_p p1 p2.
  Definition cons t (pair : result_m (pair_t t (list_t t))) : result_m (list_t t) := 
    (fst pair)::(snd pair).
  Definition seqs t (ps:list (parser t)) : parser (list_t t) := 
    List.fold_right (fun p1 p2 => map (seq p1 p2) (@cons t)) 
      (@always (list_t t) (@nil (result_m t))) ps.

  (*Useful bit and string manipulators*)
  Fixpoint string_to_bool_list (s:string) : list bool := 
    match s with
      | EmptyString => nil
      | String a s => 
        (if ascii_dec a "0"%char then false else true)::(string_to_bool_list s)
    end.

  Fixpoint bits_n (n:nat) : result := 
    match n with 
      | 0%nat => unit_t
      | S n => pair_t char_t (bits_n n)
    end.
  Fixpoint field'(n:nat) : parser (bits_n n) := 
    match n with 
      | 0%nat => Eps_p
      | S n => Cat_p Any_p (field' n)
    end.
  Fixpoint bits2Z(n:nat)(a:Z) : result_m (bits_n n) -> result_m int_t := 
    match n with 
      | 0%nat => fun _ => a
      | S n => fun p => bits2Z n (2*a + (if (fst p) then 1 else 0)) (snd p)
    end.
  Definition bits2int(n:nat)(bs:result_m (bits_n n)) : result_m int_t := bits2Z n 0 bs.
  Fixpoint bits (x:string) : parser (bits_n (String.length x)) := 
    match x with 
      | EmptyString => Eps_p
      | String c s => 
        (Cat_p (Char_p (if ascii_dec c "0"%char then false else true)) (bits s))
    end.
  Fixpoint string2int' (s:string) (a:Z) : Z :=
    match s with
      | EmptyString => a
      | String c s' => string2int' s' (2*a+ (if (ascii_dec c "0"%char) then 0 else 1))
    end
    .
  Definition string2int (s:string) : Z :=
    string2int' s 0.


  (* notation for building parsers *)
  Infix "|+|" := alt (right associativity, at level 80).
  Infix "$" := seq (right associativity, at level 70).
  Infix "@" := map (right associativity, at level 75).
  Notation "e %% t" := (e : result_m t) (at level 80).
  Definition bitsleft t (s:string)(p:parser t) : parser t := 
    bits s $ p @ (@snd _ _).
  Infix "$$" := bitsleft (right associativity, at level 70).

  Definition anybit : parser char_t := Any_p.
  Definition field(n:nat) := (field' n) @ (bits2int n).
  Definition reg := (field 5) @ ((fun z => Reg (Zabs_nat z)) : _ -> result_m register_t).
  Definition imm_p := (field 16) @ (@Word.repr 15 : _ -> result_m imm16_t).
  Definition target_p := (field 26) @ (@Word.repr 25 : _ -> result_m target26_t).
  Definition shamt_p := (field 5) @ (@Word.repr 4 : _ -> result_m shamt5_t).
 
  Definition creg_p (s:string) : parser register_t :=
    ((bits s)@(fun _ => Reg (Zabs_nat (string2int s)) %% register_t)).
  Definition reg0_p : parser register_t :=
    creg_p "00000".
  Definition cshamt_p (s:string) : parser shamt5_t :=
    let sfval := @Word.repr 4 (string2int s) in
    ((bits s)@(fun _ => sfval %% shamt5_t)).
  Definition shamt0_p : parser shamt5_t :=
    cshamt_p "00000".
  Definition cfcode_p (s:string) : parser myunit_t :=
    ((bits s)@(fun _ => tt %%myunit_t)).

  (*Generic Instruction Format Parsers*)
  Definition i_p_gen (opcode: string) (rs_p : parser register_t) (rt_p : parser register_t) 
    (immf_p : parser imm16_t) (InstCon : ioperand -> instr):=
    opcode $$ rs_p $ rt_p $ immf_p @
    (fun p =>
      match p with
        | (r1,(r2,immval)) => InstCon (Iop r1 r2 immval)
      end %% instruction_t).
  Definition i_p (opcode: string) (InstCon : ioperand -> instr) : parser instruction_t :=
    i_p_gen opcode reg reg imm_p InstCon.
  Definition j_p_gen (opcode: string) (targetf_p : parser target26_t) (InstCon : joperand -> instr) 
    : parser instruction_t :=
    opcode $$ targetf_p @
    (fun tval => InstCon (Jop tval) %% instruction_t).
  Definition j_p (opcode: string) (InstCon: joperand -> instr) : parser instruction_t :=
    j_p_gen opcode target_p InstCon.
  Definition r_p_gen (opcode: string) (rs_p: parser register_t) (rt_p: parser register_t)
    (rd_p: parser register_t) (shamtf_p: parser shamt5_t) (fcode_p: parser myunit_t) (InstCon: roperand ->instr):=
    opcode $$ rs_p $ rt_p $ rd_p $ shamtf_p $ fcode_p @
    (fun p =>
      match p with
        | (r1,(r2,(r3,(shval,_)))) => InstCon (Rop r1 r2 r3 shval) %% instruction_t
      end).
  Definition r_p (opcode: string) (fcode: string) (InstCon: roperand -> instr) : parser instruction_t :=
    r_p_gen opcode reg reg reg shamt_p ((bits fcode)@(fun _ => tt %%myunit_t)) InstCon. 
  Definition r_p_zsf (opcode: string) (fcode: string) (InstCon: roperand -> instr)
    : parser instruction_t :=
    r_p_gen opcode reg reg reg shamt0_p (cfcode_p fcode) InstCon.
  Definition shift_p (fcode: string) (InstCon: roperand -> instr) : parser instruction_t :=
    r_p_gen "000000" reg0_p reg reg shamt_p (cfcode_p fcode) InstCon.

  (*Specific Instruction Parsers*)
  Definition ADD_p := r_p_zsf "000000" "100000" ADD.
  Definition ADDI_p := i_p "001000" ADDI.
  Definition ADDIU_p := i_p "001001" ADDIU.
  Definition ADDU_p := r_p_zsf "000000" "100001" ADDU.
  Definition AND_p := r_p_zsf "000000" "100100" AND.
  Definition ANDI_p := i_p "001100" ANDI.
  Definition BEQ_p := i_p "000100" BEQ.
  Definition BGEZ_p := i_p_gen "000001" reg (creg_p "00001") imm_p BGEZ.
  Definition BGEZAL_p := i_p_gen "000001" reg (creg_p "10001") imm_p BGEZAL.
  Definition BGTZ_p := i_p_gen "000111" reg reg0_p imm_p BGTZ.
  Definition BLEZ_p := i_p_gen "000110" reg reg0_p imm_p BLEZ.
  Definition BLTZ_p := i_p_gen "000001" reg reg0_p imm_p BLTZ.
  Definition BLTZAL_p := i_p_gen "000001" reg (creg_p "10000") imm_p BLTZAL.
  Definition BNE_p := i_p "000101" BNE.
  Definition DIV_p := r_p_gen "000000" reg reg reg0_p shamt0_p (cfcode_p "011010") DIV.
  Definition DIVU_p := r_p_gen "000000" reg reg reg0_p shamt0_p (cfcode_p "011011") DIVU.
  Definition J_p := j_p "000010" J.
  Definition JAL_p := j_p "000011" JAL.
  Definition JALR_p := r_p_gen "000000" reg reg0_p reg shamt_p (cfcode_p "001001") JALR.
  Definition JR_p := r_p_gen "000000" reg reg0_p reg0_p shamt_p (cfcode_p "001000") JR.
  Definition LB_p := i_p "100000" LB.
  Definition LBU_p := i_p "100100" LBU.
  Definition LH_p := i_p "100001" LH.
  Definition LHU_p := i_p "100101" LHU.
  Definition LUI_p := i_p "001111" LUI.
  Definition LW_p := i_p "100101" LHU.
  Definition MFHI_p := r_p_gen "000000" reg0_p reg0_p reg shamt0_p (cfcode_p "010000") MFHI.
  Definition MFLO_p := r_p_gen "000000" reg0_p reg0_p reg shamt0_p (cfcode_p "010010") MFLO.
  Definition MUL_p := r_p_zsf "000000" "000010" MUL.
  Definition MULT_p := r_p_gen "000000" reg reg reg0_p shamt0_p (cfcode_p "011000") MULT.
  Definition MULTU_p := r_p_gen "000000" reg reg reg0_p shamt0_p (cfcode_p "011001") MULTU.
  Definition NOR_p := r_p_zsf "000000" "100111" NOR.
  Definition OR_p := r_p_zsf "000000" "100101" OR.
  Definition ORI_p := i_p "001101" ORI.
  Definition SB_p := i_p "101000" SB.
  Definition SEB_p := r_p_gen "011111" reg0_p reg reg (cshamt_p "10000") (cfcode_p "100000") SEB.
  Definition SEH_p := r_p_gen "011111" reg0_p reg reg (cshamt_p "11000") (cfcode_p "100000") SEH.
  Definition SH_p := i_p "101001" SH.
  Definition SLL_p := shift_p "000000" SLL.
  Definition SLLV_p := r_p_zsf "000000" "000100" SLLV.
  Definition SLT_p := r_p_zsf "000000" "101010" SLT.
  Definition SLTI_p := i_p "001010" SLTI.
  Definition SLTU_p := r_p_zsf "000000" "101011" SLTU.
  Definition SLTIU_p := i_p "001011" SLTIU.
  Definition SRA_p := shift_p "000011" SRA.
  Definition SRAV_p := r_p_zsf "000000" "000111" SRAV.
  Definition SRL_p := shift_p "000010" SRL.
  Definition SRLV_p := r_p_zsf "000000" "000110" SRLV.
  Definition SUB_p := r_p_zsf "000000" "100010" SUB.
  Definition SUBU_p := r_p_zsf "000000" "100011" SUBU.
  Definition SW_p := i_p "101011" SW.
  Definition XOR_p := r_p_zsf "000000" "100110" XOR.
  Definition XORI_p := i_p "001110" XORI.

  
  (*Large parser list*)
  Definition instr_parser_list : list (parser instruction_t) := 
    ADD_p :: ADDI_p :: ADDIU_p :: ADDU_p ::
    AND_p :: ANDI_p :: BEQ_p :: BGEZ_p :: BGEZAL_p ::
    BGTZ_p :: BLEZ_p :: BLTZ_p :: BLTZAL_p ::
    BNE_p :: DIV_p :: DIVU_p :: J_p :: JAL_p :: JALR_p :: JR_p :: LB_p ::
    LBU_p :: LH_p :: LHU_p :: LUI_p :: LW_p :: MFHI_p :: MFLO_p ::
    MUL_p :: MULT_p :: MULTU_p :: NOR_p :: OR_p ::
    ORI_p :: SB_p :: SEB_p :: SEH_p :: SH_p :: SLL_p :: 
    SLLV_p :: SLT_p :: SLTI_p :: SLTU_p :: SLTIU_p :: SRA_p ::
    SRL_p :: SRLV_p :: SUB_p :: SUBU_p :: SW_p :: XOR_p :: XORI_p ::
    nil.

  Definition instr_parser : parser instruction_t :=
    alts instr_parser_list.
  Definition instr_regexp_pair := parser2regexp instr_parser.
  Definition instr_regexp := fst instr_regexp_pair.
  Definition instr_regexp_ctxt := snd instr_regexp_pair.

  Definition word_explode (b:int32) : list bool :=
  let bs := Word.bits_of_Z 32 (Word.unsigned b) in
    (fix f (n:nat) : list bool := 
      match n with
      | S n' => (bs (Z_of_nat n'))::(f n')
      | O => nil
      end
    ) 32%nat.

  Definition parse_string (s: string) : list instr :=
    let cs := string_to_bool_list s in
    let r' := deriv_parse' instr_regexp cs in
    let wf' := wf_derivs instr_regexp_ctxt cs instr_regexp 
      (p2r_wf instr_parser _) in
    apply_null (instr_regexp_ctxt) r' wf'.

  Definition test1 := 
    match (parse_string "00001000000000000000000000000000") with
      | (J jop)::tl => 1
      | _ => 0
    end.

  Definition parse_word (w:int32) : list instr :=
    let cs := word_explode w in
    let r' := deriv_parse' instr_regexp cs in
    let wf' := wf_derivs instr_regexp_ctxt cs instr_regexp 
      (p2r_wf instr_parser _) in
    apply_null (instr_regexp_ctxt) r' wf'.
  
End MIPS_PARSER.
