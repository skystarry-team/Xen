(* SPDX-License-Identifier: Apache-2.0 *)
module Native = Xen_x86_64.Native_backend.Make(Windows_runtime)
let description : Backend_intf.description = {
  target={architecture=Target.X86_64;operating_system=Target.Windows};
  calling_convention="Xen internal x86-64; Win64 scalar runtime bridges";
  runtime="Embedded Xen runtime; synchronous Win32 services; UTF-8 arguments and paths";
  executable_format="PE32+ AMD64 console executable";
}
type executable = bytes
let generate input =
  let open Semantic_ir in
  let rejected=List.find_map(fun(f:func)->Array.find_map(fun(b:block)->
    List.find_map(fun op->match op.node with
      |Eval(_,Foreign_call _)->Some({Backend_intf.span=Some op.span;
          message="extern_call is not implemented for x86_64-windows"}:Backend_intf.error)
      |Eval(_,Syscall _)->Some({Backend_intf.span=Some op.span;
          message="raw syscall is not supported for x86_64-windows; use platform services"}:Backend_intf.error)
      |_->None)b.operations)f.blocks)(program input).functions in
  match rejected with Some error->Error error|None->
  try Native.generate input with
  |Xen_windows.Pe_writer.Error message->Error {Backend_intf.span=None;message}
let write = Native.write
