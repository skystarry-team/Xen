(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Seed registers outside Xen and check them after returning from the program.
   This detects missing saves even when the normal lowering does not use them. *)
let sentinel r = Int64.add 0x123456789abc0000L (Int64.of_int r)
module X = struct
  module R = Xen_linux_x86_64.Linux_runtime
  let saved = [3;12;13;14;15]
  include R
  let start m =
    R.start m;
    M.add_data_u64 m "probe_sp" 0L;
    M.bytes m [0x48;0x89;0x25];M.rip_rel32 m M.Data "probe_sp";
    List.iter(fun r->M.bytes m [if r>=8 then 0x49 else 0x48;0xb8 lor(r land 7)];
      M.u64 m(sentinel r))saved
  let exit m status =
    if status=0 then begin
      List.iter(fun r->M.bytes m[0x48;0xb8];M.u64 m(sentinel r);
        M.bytes m[if r>=8 then 0x49 else 0x48;0x39;0xc0 lor(r land 7)];
        M.branch m[0x0f;0x85]"probe_failed")saved;
      M.bytes m[0x48;0x3b;0x25];M.rip_rel32 m M.Data "probe_sp";
      M.branch m[0x0f;0x85]"probe_failed";
      R.exit m 0;M.label m "probe_failed";R.exit m 97
    end else R.exit m status
end
module A = struct
  module R = Xen_linux_arm64.Linux_runtime
  include R
  let start m =
    R.start m;
    M.global m "probe_sp";M.address m 15 "probe_sp";
    M.word m 0x910003e9;M.store m 9 15 0;
    for r=19 to 28 do M.imm m r(sentinel r)done
  let exit m status =
    if status=0 then begin
      for r=19 to 28 do M.imm m 9(sentinel r);M.cmp m r 9;M.cond m 1 "probe_failed"done;
      M.address m 15 "probe_sp";M.load m 9 15 0;M.word m 0x910003ea;
      M.cmp m 9 10;M.cond m 1 "probe_failed";
      R.exit m 0;M.label m "probe_failed";R.exit m 97
    end else R.exit m status
end
module X_codegen = Xen_x86_64.Native_backend.Make(X)
module A_codegen = Xen_arm64.Native_backend.Make(A)
let () =
  if Array.length Sys.argv<>5 then failwith "usage: asm_abi_fixture TARGET SOURCE OUTPUT OPT";
  let channel=open_in_bin Sys.argv.(2)in
  let source=Fun.protect ~finally:(fun()->close_in channel)
    (fun()->really_input_string channel(in_channel_length channel))in
  let checked=match Checker.check(Parser.parse ~file:Sys.argv.(2) source)with
    |Ok p->p|Error e->failwith e.message in
  let checked=Semantic_opt.apply(if Sys.argv.(4)="basic"then Semantic_opt.Basic else Semantic_opt.Off)checked in
  let executable=match Sys.argv.(1)with
    |"x86_64-linux"->X_codegen.generate checked
    |"aarch64-linux"->A_codegen.generate checked
    |_->failwith "unsupported fixture target"in
  match executable with
  |Error e->failwith e.message
  |Ok bytes->let channel=open_out_bin Sys.argv.(3)in
      Fun.protect ~finally:(fun()->close_out channel)(fun()->output_bytes channel bytes);
      Unix.chmod Sys.argv.(3)0o755
