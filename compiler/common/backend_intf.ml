(* SPDX-License-Identifier: Apache-2.0 *)
type error = { span : Ast.span option; message : string }

(* Descriptions identify backend requirements; the driver never assigns registers,
   emits syscalls, links runtime routines, or chooses an executable format. *)
type description = {
  target : Target.t;
  calling_convention : string;
  runtime : string;
  executable_format : string;
}

module type S = sig
  val description : description
  type executable

  (* Input uses Xen's current 64-bit value layout. Each implementation owns ABI
     lowering, native code, runtime emission and executable construction.
     An unsupported requested feature must return Error, never silently fall back. *)
  val generate : Semantic_ir.checked_program ->
    (executable, error) result
  val write : string -> executable -> unit
end
