(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Execute the CPU runtimes with long inline services and deterministic failures.
   In particular, alloc errors deliberately leave rdi nonzero: callers must
   follow Runtime_intf rather than depend on Linux mmap's incidental zero. *)
module M = Xen_x86_64.Machine_ir
let mode = Sys.argv.(1)
module Runtime = struct
  include Xen_linux_x86_64.Linux_runtime
  let pad output = for _=1 to 257 do M.u8 output 0x90 done
  let wrap service output = pad output;service output;pad output
  let alloc output =
    pad output;
    if String.starts_with ~prefix:"alloc:" mode then begin
      let nth=int_of_string(String.sub mode 6 (String.length mode-6)) in
      let counter="__test_runtime_allocations" in
      if not(Hashtbl.mem output.M.data_labels counter)then M.add_data_u64 output counter 0L;
      let normal="__test_alloc_normal_"^string_of_int(M.position output)
      and done_="__test_alloc_done_"^string_of_int(M.position output)in
      M.bytes output[0x48;0xff;0x05];M.rip_rel32 output M.Data counter;
      M.bytes output[0x4c;0x8b;0x15];M.rip_rel32 output M.Data counter;
      M.bytes output[0x49;0x81;0xfa];M.u32 output(Int64.of_int nth);
      M.branch output[0x0f;0x85]normal;
      M.bytes output[0x48;0xc7;0xc0;0xf4;0xff;0xff;0xff;0xbf;0x79;0x35;0x01;0x00];
      M.branch output[0xe9]done_;
      M.label output normal;Xen_linux_x86_64.Linux_runtime.alloc output;
      M.label output done_
    end else Xen_linux_x86_64.Linux_runtime.alloc output;
    pad output
  let unmap = wrap Xen_linux_x86_64.Linux_runtime.unmap
  let open_ = wrap Xen_linux_x86_64.Linux_runtime.open_
  let write = wrap Xen_linux_x86_64.Linux_runtime.write
  let read output =
    pad output;
    if mode="read_error" then M.bytes output[0x48;0xc7;0xc0;0xfb;0xff;0xff;0xff]
    else Xen_linux_x86_64.Linux_runtime.read output;
    pad output
  let close output =
    pad output;Xen_linux_x86_64.Linux_runtime.close output;
    if mode="close_error"then M.bytes output[0x48;0xc7;0xc0;0xfb;0xff;0xff;0xff];
    pad output
end
module Codegen = Xen_x86_64.Native_backend.Make(Runtime)
let () =
  let path=Sys.argv.(2)in
  let input=open_in_bin path in
  let source=Fun.protect ~finally:(fun()->close_in input)
    (fun()->really_input_string input(in_channel_length input))in
  let checked=match Checker.check(Parser.parse ~file:path source)with
    |Ok checked->checked|Error d->failwith d.message in
  let checked=Semantic_opt.apply (if Sys.argv.(4)="basic"then Semantic_opt.Basic else Semantic_opt.Off)checked in
  match Codegen.generate checked with
  |Ok executable->Codegen.write Sys.argv.(3)executable
  |Error error->failwith error.message
