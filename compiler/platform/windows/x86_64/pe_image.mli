(* SPDX-License-Identifier: Apache-2.0 *)
(* Compose x86-64 Machine IR with PE, resolving imports to the loader's IAT.
   This adapter does not register an executable Xen language backend. *)
val executable : ?stack_reserve:int64 -> ?stack_commit:int64 -> ?bss_size:int ->
  ?pointers:Xen_windows.Pe_writer.pointer list ->
  entry:string -> functions:Xen_x86_64.Win64.function_frame list ->
  Xen_x86_64.Machine_ir.t -> bytes
