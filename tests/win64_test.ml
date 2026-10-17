(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
module M = Xen_x86_64.Machine_ir
module W = Xen_x86_64.Win64
let expect condition message = if not condition then failwith message
let rejects f = match f()with
  |_->failwith "invalid Win64 bridge accepted"|exception Invalid_argument _->()
let () =
  let output=M.create()in
  let a=M.import output "first.dll" "same" and b=M.import output "second.dll" "same"in
  expect(a<>b)"Machine IR merged identical exports from distinct DLLs";
  expect(M.import output "first.dll" "same"=a)"Machine IR duplicated an import";
  List.iter(fun label->M.bytes output[0xff;0x15];M.rip_rel32 output M.Data label)[a;b];
  let bytes=M.encode ~code_address:0x1000L ~data_address:0x3000L
    ~import_address:(fun ~library ~symbol->expect(symbol="same")"wrong export";
      if library="first.dll"then 0x5000L else 0x6000L)output in
  expect(Bytes.get_int32_le bytes 2=0x3ffal && Bytes.get_int32_le bytes 8=0x4ff4l)
    "Machine IR import fixups did not resolve to real IAT slots";
  let legacy=M.encode ~code_address:0x1000L ~data_address:0x3000L output in
  expect(Bytes.get_int32_le legacy 2=0x1ffal && Bytes.get_int32_le legacy 8=0x1ffcl)
    "explicit PE import resolution changed the ELF data-slot contract";
  let bridge arguments = W.emit_bridge(M.create()) ~label:"bridge" ~library:"test.dll"
    ~symbol:"probe" ~arguments ~result:(Some W.I64)in
  List.iter(fun argument->rejects(fun()->bridge[argument]))[
    {W.scalar=I64;source=Gp 4};{scalar=I64;source=Gp 5};{scalar=I64;source=Gp 16};
    {scalar=F64;source=Gp 0};{scalar=I64;source=Fp 0};{scalar=F64;source=Fp 16};
    {scalar=I64;source=Stack(-8)};{scalar=I64;source=Stack 1};
    {scalar=I64;source=Stack 0x7ffffff0}];
  rejects(fun()->bridge(List.init 33(fun _->{W.scalar=I64;source=Immediate 0L})));
  List.iter(fun size->rejects(fun()->W.stack_allocate(M.create())size))[-1;1;0x80000000];
  let output=M.create()in W.stack_allocate output 0;expect(M.position output=0)"empty allocation emitted code";
  W.stack_allocate output (3*4096+16);ignore(M.encode output);
  let output=M.create()in
  ignore(W.emit_bridge output ~label:"bridge" ~library:"test.dll" ~symbol:"probe"
    ~arguments:[] ~result:None);
  rejects(fun()->W.emit_bridge output ~label:"bridge" ~library:"test.dll" ~symbol:"probe"
    ~arguments:[] ~result:None);
  print_endline "Win64 scalar sources, DLL import identity and IAT fixups passed"
