(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Structural fixture only: emitting an image does not certify macOS execution. *)
let () =
  if Array.length Sys.argv<>3 then failwith "usage: mach_o_fixture ARCH OUTPUT";
  let architecture,code=match Sys.argv.(1) with
    |"aarch64"->Target.Aarch64,Bytes.of_string "\000\000\128\210\192\003\095\214"
    |"x86_64"->Target.X86_64,Bytes.of_string "\049\192\195"
    |_->failwith "unsupported architecture" in
  let encode ~code_address:_ ~rodata_address:_ ~data_address:_ = code in
  let image=Xen_darwin.Mach_o.executable ~architecture ~entry:0
    ~code_size:(Bytes.length code) ~rodata:"fixture constant\000" ~data:(String.make 8 '\000') ~encode in
  let channel=open_out_bin Sys.argv.(2) in
  Fun.protect ~finally:(fun()->close_out channel)(fun()->output_bytes channel image)
