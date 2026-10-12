(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Execute Darwin trap adapters under Linux ARM64/QEMU with a simulated kernel
   return. Only the svc word is relocated to a branch into the simulation; the
   actual adapter's stack/register/carry code executes unchanged. This validates
   the adapter, not Darwin's syscall table, loader or actual kernel behavior. *)
module M = Xen_arm64.Machine_ir
module D = Xen_darwin_arm64.Darwin_runtime
module L = Xen_linux_arm64.Linux_runtime
let () =
  if Array.length Sys.argv<>2 then failwith "usage: darwin_abi_fixture OUTPUT";
  let m=M.create() in
  M.label m "_start";M.offset m 19 31 0;
  List.iter(fun(name,wanted,raw_number)->
    List.iter(fun reg->M.int m reg(100+reg))[1;2;3;4;5];
    Option.iter(M.int m 8)raw_number;
    M.branch m ~link:true name;
    M.int m 9 wanted;M.cmp m 0 9;M.cond m 1 "failed";
    List.iter(fun reg->M.int m 9(100+reg);M.cmp m reg 9;M.cond m 1 "failed")[1;2;3;4;5];
    M.offset m 9 31 0;M.cmp m 9 19;M.cond m 1 "failed")
    ["bsd_success",3,None;"bsd_failure",-9,None;
     "raw_success",42,Some 20;"raw_failure",-78,Some 9999];
  L.write_constant m 1 "darwin-adapter\n";L.exit m 0;
  M.label m "failed";L.fail m "Darwin adapter fixture failed\n";
  List.iter(fun(name,number,result,carry,emit)->
    M.label m name;let start=M.position m in emit m;M.ret m;
    let text=Buffer.contents m.M.code in
    let at=ref start in
    let is_svc i=i+4<=String.length text && String.sub text i 4="\001\016\000\212" in
    while !at<String.length text && not(is_svc !at) do at:= !at+4 done;
    if !at>=String.length text then failwith "missing Darwin svc fixture";
    let resume=M.fresh m "resume_" and kernel=M.fresh m "simulated_kernel_" in
    M.define m resume M.Code(!at+4);
    m.M.fixups<-(!at,M.Branch26 0x14000000,kernel)::m.M.fixups;
    M.label m kernel;M.int m 9 number;M.cmp m 16 9;M.cond m 1 "failed";
    M.int m 0 result;M.int m 1 999; (* second return deliberately destroys x1 *)
    M.int m 9 1;M.cmp m 31 (if carry then 31 else 9);
    M.branch m resume)
    ["bsd_success",6,3,false,(fun m->D.syscall m 6);
     "bsd_failure",6,9,true,(fun m->D.syscall m 6);
     "raw_success",20,42,false,D.raw_syscall;
     "raw_failure",9999,78,true,D.raw_syscall];
  L.emit m;
  Xen_linux_arm64.Native_backend.write Sys.argv.(1)(Xen_linux_arm64.Elf_writer.static_linux ~entry:0 m)
