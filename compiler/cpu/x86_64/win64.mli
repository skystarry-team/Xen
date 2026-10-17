(* SPDX-License-Identifier: Apache-2.0 *)
(* Machine-code bridges from Xen's internal register contract to Win64.
   Generated runtime code carries the additional permission in LICENSE. *)
type scalar = I64 | F32 | F64
type source = Gp of int | Fp of int | Stack of int | Immediate of int64
type argument = { scalar : scalar; source : source }
type unwind_operation = Push_nonvol of int | Alloc_stack of int | Set_frame of int * int
type unwind_code = { code_offset : int; operation : unwind_operation }
type function_frame = {
  begin_offset : int; end_offset : int; prolog_size : int; codes : unwind_code list;
}

(* Fixed-size allocation, probing each intervening 4 KiB page before proceeding.
   size must be a nonnegative multiple of eight, at most 2 GiB-1.
   Clobbers r11 and flags. Callers describe their own frame/unwind information. *)
val stack_allocate : Machine_ir.t -> int -> unit

(* Sources are snapshotted before assigning positional Win64 registers/stack
   slots. Stack offsets address the caller's RSP immediately before CALL.
   RSP/RBP cannot be GP sources; FP sources must match an FP scalar. Immediate
   and Stack contain raw scalar bits. Up to 32 non-variadic scalar arguments;
   aggregates, callbacks, varargs and language exceptions are not supported.

   The bridge accepts either incoming stack alignment and supplies aligned
   shadow space. All GP registers except rax/r11, all FP registers except xmm0
   for an FP result, and the caller's RSP are preserved. None is a void result.
   Runtime services returning integer status use Some I64, preserving ALL FP.
   The returned frame describes only this bridge, not arbitrary Xen code. *)
val emit_bridge : Machine_ir.t -> label:string -> library:string -> symbol:string ->
  arguments:argument list -> result:scalar option -> function_frame
