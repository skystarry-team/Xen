(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
open Semantic_ir
let expect b message = if not b then failwith message
let () =
  let source="fn main(){#scope[jit]{let x=arg_count();println(x*x+match true{true=>1,false=>2});}}"in
  let checked=match Checker.check(Parser.parse ~file:"jit-ir.xen"source)with Ok p->p|Error d->failwith d.message in
  let checked,_=Semantic_opt.optimize checked in
  let f=List.hd(program checked).functions in
  let chunks=Semantic_opt.calculation_chunks f in
  Array.iteri(fun id chunks->
    let original=Array.of_list f.blocks.(id).operations and position=ref 0 in
    List.iter(fun(c:Semantic_opt.chunk)->expect(c.start= !position)"gap in region boundaries";
      expect(c.stop-c.start=List.length c.operations)"inexact region extent";
      List.iteri(fun index op->expect(original.(c.start+index)=op)"region differs from checked IR")c.operations;
      if c.calculation then expect(List.for_all(fun(op:operation)->op.scope=c.scope && Semantic_opt.safe_node op.node)c.operations)"unsafe region";
      position:=c.stop)chunks;
    expect(!position=Array.length original)"missing operations")chunks;
  let output=Machine_ir.create ~record_operands:true()in
  Machine_ir.bytes output [0x48;0xb8];Machine_ir.literal64 output 0x0123456789abcdefL;
  Machine_ir.bytes output[0x48;0x8b;0x85];Machine_ir.frame32 output 1 (-8L);
  let code=Bytes.of_string(Buffer.contents output.buffer)in
  let patches=List.rev output.operand_patches in
  expect(List.map(fun(p:Machine_ir.operand_patch)->p.at,p.width)patches=[2,8;13,4])"relocations not recorded structurally";
  Jit_runtime.validate{code;patches};
  let invalid patches=try Jit_runtime.validate{code;patches};failwith "corrupt recipe accepted"with Invalid_argument _->()in
  invalid [];invalid[{at=100;width=4;operand=Machine_ir.Frame 0}];
  invalid[{at=0;width=4;operand=Machine_ir.Frame 3}];
  invalid[{at=0;width=4;operand=Machine_ir.Literal}];
  invalid[{at=0;width=8;operand=Machine_ir.Literal};{at=2;width=4;operand=Machine_ir.Frame 0}];
  print_endline "JIT IR boundaries and structural relocation controls passed"
