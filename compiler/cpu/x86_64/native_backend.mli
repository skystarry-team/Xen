(* SPDX-License-Identifier: Apache-2.0 *)
type error = Backend_intf.error
module type Runtime = Runtime_intf.S
module Make(_ : Runtime) : sig
  val generate : Semantic_ir.checked_program -> (bytes, error) result
  val write : string -> bytes -> unit
end
