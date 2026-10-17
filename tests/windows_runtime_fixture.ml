(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Actual checked-program lowering, with an optional native stack observer.
   A label/frame manifest lets independent tests identify real emitted frames. *)
module M = Xen_x86_64.Machine_ir
module Base = Xen_windows_x86_64.Windows_runtime
module Runtime = struct
  include Base
  let start m =
    Base.start m;
    if Sys.argv.(1)="thread" then begin
      M.bytes m[0x48;0x8d;0x05];M.rel32 m "fn_main";
      M.branch m[0xe8]"__xen_test_small_stack";
      M.bytes m[0x48;0x85;0xc0];M.branch m[0x0f;0x85]"__xen_test_thread_failed";
      Base.exit m 0;M.label m "__xen_test_thread_failed";Base.exit m 91
    end
  let executable ~entry:_ m =
    M.end_helpers m;
    if Sys.argv.(1)="thread" then begin
      let frame=Xen_x86_64.Win64.emit_bridge m ~label:"__xen_test_small_stack"
        ~library:"xen-unwind-observer.dll" ~symbol:"RunOnSmallStack"
        ~arguments:[{scalar=I64;source=Gp 0}] ~result:(Some I64)in
      m.M.frames<-m.M.frames@[frame]
    end;
    let import library symbol =
      if Sys.argv.(1)="observe" && symbol="ReadFile" then "xen-unwind-observer.dll","InspectReadFile"
      else if Sys.argv.(1)="write-observe" && symbol="WriteFile" then "xen-unwind-observer.dll","InspectWriteFile"
      else if Sys.argv.(1)="write-observe" && symbol="ExitProcess" then "xen-unwind-observer.dll","CheckExitProcess"
      else library,symbol in
    let functions=Base.emit ~import m in
    m.M.frames<-m.M.frames@functions;
    let channel=open_out Sys.argv.(4)in
    Fun.protect ~finally:(fun()->close_out channel)(fun()->
      Hashtbl.iter(fun label offset->Printf.fprintf channel "label\t%s\t%d\n"label offset)m.M.labels;
      List.iter(fun(f:M.function_frame)->Printf.fprintf channel "frame\t%d\t%d\t%d\n"
        f.begin_offset f.end_offset f.prolog_size)m.M.frames);
    Xen_windows_x86_64.Pe_image.executable ~stack_reserve:0x2000000L ~entry:"_start" ~functions:m.M.frames m
end
module Codegen = Xen_x86_64.Native_backend.Make(Runtime)
let () =
  let source=Sys.argv.(2)in let input=open_in_bin source in
  let text=Fun.protect ~finally:(fun()->close_in input)(fun()->really_input_string input(in_channel_length input))in
  let checked=match Checker.check(Parser.parse ~file:source text)with
    |Ok p->p|Error d->failwith d.message in
  let checked=Semantic_opt.apply Semantic_opt.Off checked in
  match Codegen.generate checked with
  |Ok bytes->Codegen.write Sys.argv.(3)bytes
  |Error e->failwith e.message
