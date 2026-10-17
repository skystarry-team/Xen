(* SPDX-License-Identifier: Apache-2.0 *)
(* Standalone AMD64 PE32+ console image writer.
   Named imports only; no CRT, TLS, exports or language exception handlers.
   Callers supply Win64 code and accurate function/prolog descriptions. *)
exception Error of string

type section = Code | Rodata | Data
type address = { section : section; offset : int }
type pointer = { at : address; target : address }

type unwind_operation =
  | Push_nonvol of int
  | Alloc_stack of int
  | Set_frame of int * int (* register, byte displacement from fixed RSP *)
  | Save_nonvol of int * int (* register, byte displacement from fixed RSP *)
  | Save_xmm of int * int (* full 128-bit XMM6..15, byte displacement *)
type unwind_code = { code_offset : int; operation : unwind_operation }
type runtime_function = {
  begin_offset : int;
  end_offset : int; (* exclusive, offsets within code *)
  prolog_size : int;
  codes : unwind_code list;
}

(* Pointer locations must be backed by eight initialized bytes; targets may
   refer to the virtual zero-filled data tail. These locations get DIR64 base
   relocations. The encoder handles relative code/data/import references.
   Images without pointer fixups are explicitly fixed-base (no ASLR flags).
   import_address returns the VA of a loader-written IAT slot, not its contents.
   Function descriptions support push/allocate/frame-pointer and GP/XMM saves;
   stack probing and valid epilogs remain the code emitter's responsibility. *)
val executable :
  ?stack_reserve:int64 -> ?stack_commit:int64 ->
  entry:int -> code_size:int -> rodata:string -> data:string -> bss_size:int ->
  imports:(string * string) list -> pointers:pointer list ->
  functions:runtime_function list ->
  encode:(code_address:int64 -> rodata_address:int64 -> data_address:int64 ->
    import_address:(library:string -> symbol:string -> int64) -> bytes) ->
  unit -> bytes
