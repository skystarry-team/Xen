(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
module M = Machine_ir
let descriptor name =
  let found=List.find_map(fun r->if name="x"^string_of_int r then Some(r,64)
    else if name="w"^string_of_int r then Some(r,32)else None)(List.init 15 Fun.id)in
  match found with Some d->d|None->Asm_contract.fail("unsupported AArch64 register '"^name^"'")
let register name=fst(descriptor name)
let width name=snd(descriptor name)
let canonical name="x"^string_of_int(register name)
let immediate text =
  if String.length text<2 || text.[0]<>'#'then Asm_contract.fail "expected #integer immediate";
  match Int64.of_string_opt(String.sub text 1(String.length text-1))with
  |Some n->n|None->Asm_contract.fail "invalid integer immediate"
let bounded_immediate text low high message =let n=immediate text in
  if n<Int64.of_int low || n>Int64.of_int high then Asm_contract.fail message;Int64.to_int n
let memory text=match Asm_contract.bracketed text with
  |Some address->(match String.split_on_char ',' address with
    |[base]->String.trim base,"#0"|[base;offset]->String.trim base,String.trim offset
    |_->Asm_contract.fail "expected [register, #byte_offset] without writeback")
  |None->Asm_contract.fail "expected [register, #byte_offset] without writeback"
let conditions=["eq",0;"ne",1;"cs",2;"hs",2;"cc",3;"lo",3;"mi",4;"pl",5;
  "vs",6;"vc",7;"hi",8;"ls",9;"ge",10;"lt",11;"gt",12;"le",13]
let memory_ops=["ldr",true,None,false;"str",false,None,false;"ldur",true,None,true;"stur",false,None,true;
  "ldrb",true,Some 1,false;"strb",false,Some 1,false;"ldrh",true,Some 2,false;"strh",false,Some 2,false;
  "ldurb",true,Some 1,true;"sturb",false,Some 1,true;"ldurh",true,Some 2,true;"sturh",false,Some 2,true]
let assemble ?(input_types=[]) spec =
  let m=M.create()in
  let read,write,finish=Asm_contract.registers ~input_types spec ~canonical ~width ~written_bits:(fun _->64) register in
  let flags=ref false in
  let sized bits base=if bits=64 then base else base land 0x7fffffff in
  let same registers=let bits=width(List.hd registers)in
    if List.exists(fun r->width r<>bits)registers then Asm_contract.fail "register operand widths differ";bits in
  let rr base dst a b=let bits=same[dst;a;b]in M.rr m(sized bits base)(register dst)(register a)(register b)in
  List.iter(function
    |"mov",[dst;src]->
        if String.starts_with ~prefix:"#" src then begin
          let n=immediate src in write dst;
          if width dst=64 then M.imm m(register dst)n else begin
            if n< -2147483648L || n>4294967295L then Asm_contract.fail "mov immediate exceeds 32-bit register";
            for half=0 to 1 do let chunk=Int64.(to_int(logand(shift_right_logical n(16*half))65535L))in
              M.word m((if half=0 then 0x52800000 else 0x72800000)lor(half lsl 21)lor(chunk lsl 5)lor(register dst))done
          end
        end else let bits=same[dst;src]in read src;write dst;
          M.word m(sized bits 0xaa0003e0 lor(register src lsl 16)lor(register dst))
    |("add"|"sub"|"adds"|"subs" as op),[dst;a;b]when String.starts_with ~prefix:"#" b->
        let n=bounded_immediate b 0 4095 "add/sub immediate must be 0..4095"and bits=same[dst;a]in
        read a;write dst;
        let sets=op="adds"||op="subs"in if sets then flags:=true;
        let base=(if String.starts_with ~prefix:"add" op then 0x91000000 else 0xd1000000)lor(if sets then 0x20000000 else 0)in
        M.word m(sized bits base lor(n lsl 10)lor(register a lsl 5)lor(register dst))
    |("add"|"sub"|"adds"|"subs"|"mul"|"and"|"orr"|"eor" as op),[dst;a;b]->
        read a;read b;write dst;
        let base=List.assoc op["add",0x8b000000;"sub",0xcb000000;"adds",0xab000000;"subs",0xeb000000;
          "mul",0x9b007c00;"and",0x8a000000;"orr",0xaa000000;"eor",0xca000000]in
        rr base dst a b;if op="adds"||op="subs"then flags:=true
    |("lsl"|"lsr"|"asr" as op),[dst;src;count]->
        let bits=same[dst;src]in read src;
        if String.starts_with ~prefix:"#" count then begin
          let n=bounded_immediate count 0(bits-1)"shift count must fit register width (0..63 for 64-bit)"in write dst;
          let base=if op="asr"then (if bits=64 then 0x93400000 else 0x13000000)
            else if bits=64 then 0xd3400000 else 0x53000000 in
          let immr,imms=if op="lsl"then ((bits-n)land(bits-1)),bits-1-n else n,bits-1 in
          M.word m(base lor(immr lsl 16)lor(imms lsl 10)lor(register src lsl 5)lor(register dst))
        end else begin read count;ignore(same[dst;count]);write dst;
          rr(List.assoc op["lsl",0x9ac02000;"lsr",0x9ac02400;"asr",0x9ac02800])dst src count end
    |("neg"|"mvn"|"rev" as op),[dst;src]->let bits=same[dst;src]in read src;write dst;
        let d=register dst and s=register src in
        (match op with
         |"neg"->M.rr m(sized bits 0xcb000000)d 31 s
         |"mvn"->M.word m(sized bits 0xaa2003e0 lor(s lsl 16)lor d)
         |_->M.word m((if bits=64 then 0xdac00c00 else 0x5ac00800)lor(s lsl 5)lor d))
    |("sxtb"|"sxth"|"sxtw"|"uxtb"|"uxth" as op),[dst;src]->
        if width src<>32 || op="sxtw"&&width dst<>64 then Asm_contract.fail "unsupported integer extension widths";
        read src;write dst;let bits=width dst in
        let base=if op.[0]='s'then(if bits=64 then 0x93400000 else 0x13000000)
          else if bits=64 then 0xd3400000 else 0x53000000 in
        let top=if String.ends_with ~suffix:"b" op then 7 else if String.ends_with ~suffix:"h" op then 15 else 31 in
        M.word m(base lor(top lsl 10)lor(register src lsl 5)lor(register dst))
    |("cmp"|"tst" as op),[a;b]->
        read a;let bits=width a in
        if String.starts_with ~prefix:"#" b then begin
          if op<>"cmp"then Asm_contract.fail "tst requires register operands";
          let n=bounded_immediate b 0 4095 "cmp immediate must be 0..4095"in
          M.word m(sized bits 0xf100001f lor(n lsl 10)lor(register a lsl 5))
        end else begin read b;ignore(same[a;b]);
          M.rr m(sized bits(if op="cmp"then 0xeb000000 else 0xea000000))31(register a)(register b)end;
        flags:=true
    |"cset",[dst;condition]->
        if not !flags then Asm_contract.fail "condition flags must be initialized by cmp/tst/adds/subs";
        let condition=match List.assoc_opt condition conditions with Some c->c|None->Asm_contract.fail "unsupported cset condition"in
        write dst;M.word m(sized(width dst)0x9a9f07e0 lor((condition lxor 1)lsl 12)lor(register dst))
    |op,[reg;address]when List.exists(fun(name,_,_,_)->name=op)memory_ops->
        let _,load,bytes,unscaled=List.find(fun(name,_,_,_)->name=op)memory_ops in
        let bytes=match bytes with Some bytes->if width reg<>32 then Asm_contract.fail "byte/halfword memory operands require a w register";bytes
          |None->width reg/8 in
        let base,offset=memory address in
        if width base<>64 then Asm_contract.fail "memory base must be an x register";
        let n=if unscaled then bounded_immediate offset (-256)255 "unscaled memory offset must be -256..255"
          else bounded_immediate offset 0(bytes*4095)(if bytes=8 then "scaled memory offset must be 0..32760"else "scaled memory offset exceeds element range")in
        if not unscaled && n mod bytes<>0 then Asm_contract.fail(if bytes=8 then "scaled memory offset must be a multiple of 8"else "scaled memory offset must be a multiple of access width");
        read base;if load then write reg else read reg;
        if unscaled then M.word m((List.assoc bytes[1,0x38000000;2,0x78000000;4,0xb8000000;8,0xf8000000])lor
          (if load then 0x00400000 else 0)lor((n land 511)lsl 12)lor(register base lsl 5)lor(register reg))
        else if load then M.load m ~bytes(register reg)(register base)n else M.store m ~bytes(register reg)(register base)n
    |"nop",[]->M.word m 0xd503201f|"yield",[]->M.word m 0xd503203f
    |"dmb",["sy"]->M.word m 0xd5033fbf|"dmb",["ish"]->M.word m 0xd5033bbf
    |name,_->Asm_contract.fail("unsupported AArch64 instruction or operands '"^name^"'"))
    (Asm_contract.instructions spec.template);
  finish();Buffer.contents m.code
