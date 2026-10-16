(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
module M = Machine_ir
let families=[0,["rax";"eax";"ax";"al"];1,["rcx";"ecx";"cx";"cl"];
  3,["rbx";"ebx";"bx";"bl"];4,["rsp"];
  2,["rdx";"edx";"dx";"dl"];6,["rsi";"esi";"si";"sil"];7,["rdi";"edi";"di";"dil"]] @
  List.init 8(fun i->let n="r"^string_of_int(i+8)in i+8,[n;n^"d";n^"w";n^"b"])
let descriptor name =
  let found=List.find_map(fun(r,names)->List.find_mapi(fun i n->if n=name then Some(r,List.nth[64;32;16;8]i,List.hd names)else None)names)families in
  match found with Some d->d|None->Asm_contract.fail("unsupported x86-64 register '"^name^"'")
let register name=let r,_,_=descriptor name in r
let width name=let _,w,_=descriptor name in w
let canonical name=let _,_,r=descriptor name in r
let written_bits name=let w=width name in if w=32 then 64 else w
let preserved_registers spec =
  List.map register(spec.input_registers @ List.map fst spec.output_registers @ spec.clobbers)
  |> List.filter(fun r->r=3 || r>=12) |> List.sort_uniq Int.compare
let signed32 n=n>= -2147483648L && n<=2147483647L
let immediate width text =
  let bounds=match width with 8-> -128L,255L|16-> -32768L,65535L|32-> -2147483648L,4294967295L|_-> -2147483648L,2147483647L in
  match Int64.of_string_opt text with Some n when n>=fst bounds && n<=snd bounds->n
  |_->Asm_contract.fail(if width=64 then "expected signed 32-bit immediate"else "immediate exceeds operand width")
let memory text =
  let declared,text=List.fold_left(fun(width,s)(prefix,w)->if String.starts_with ~prefix s then
    Some w,String.trim(String.sub s(String.length prefix)(String.length s-String.length prefix))else width,s)
    (None,text)["byte ptr ",8;"word ptr ",16;"dword ptr ",32;"qword ptr ",64;"byte ",8;"word ",16;"dword ",32;"qword ",64]in
  Option.map(fun address->
    let rec split i =
      if i=String.length address then address,0L
      else if address.[i]='+' || address.[i]='-'then begin
        let base=String.trim(String.sub address 0 i)and magnitude=String.trim(String.sub address(i+1)(String.length address-i-1))in
        if magnitude="" || magnitude.[0]='+' || magnitude.[0]='-'then Asm_contract.fail "expected base register plus signed 32-bit displacement";
        let n=match Int64.of_string_opt magnitude with Some n when n>=0L->n|_->Asm_contract.fail "expected base register plus signed 32-bit displacement"in
        let n=if address.[i]='-'then Int64.neg n else n in
        if not(signed32 n)then Asm_contract.fail "memory displacement exceeds signed 32-bit range";base,n
      end else split(i+1)in
    let base,n=split 0 in
    if width base<>64 then Asm_contract.fail "memory base must be a 64-bit register";
    declared,base,n)(Asm_contract.bracketed text)
let conditions=["e",4;"z",4;"ne",5;"nz",5;"l",12;"le",14;"g",15;"ge",13;
  "b",2;"c",2;"be",6;"a",7;"ae",3;"s",8;"ns",9;"o",0;"no",1;"p",10;"np",11]
let assemble ?(input_types=[]) spec =
  let m=M.create()in
  List.iter(fun r->if r="rsp"then Asm_contract.fail "unsupported stack pointer constraint")
    (spec.input_registers @ List.map fst spec.output_registers @ spec.clobbers);
  let read,write,finish=Asm_contract.registers ~input_types spec ~canonical ~width ~written_bits register in
  let read r=if r<>"rsp"then read r in
  let write r=if r="rsp"then Asm_contract.fail "unsupported stack pointer write"else write r in
  let reserve,release,finish_stack=Asm_contract.stack()in
  let flags=ref false in
  let prefix bits r b force =
    if bits=16 then M.u8 m 0x66;
    let rex=0x40 lor(if bits=64 then 8 else 0)lor(if r>=8 then 4 else 0)lor(if b>=8 then 1 else 0)in
    if rex<>0x40 || force then M.u8 m rex in
  let same a b=let w=width a in if w<>width b then Asm_contract.fail "register operand widths differ";w in
  let rr op dst src =let bits=same dst src and d=register dst and s=register src in
    prefix bits s d (bits=8&&(d>=4||s>=4));M.bytes m op;M.u8 m(0xc0 lor((s land 7)lsl 3)lor(d land 7))in
  let emit_imm bits n=for i=0 to (if bits=64 then 4 else bits/8)-1 do M.u8 m Int64.(to_int(shift_right_logical n(i*8)))done in
  let group opcode extension dst =let bits=width dst and d=register dst in
    prefix bits 0 d (bits=8&&d>=4);M.u8 m opcode;M.u8 m(0xc0 lor(extension lsl 3)lor(d land 7))in
  let modrm r base n =
    let b=register base in
    let displacement=n<>0L || b land 7=5 in
    M.u8 m((if displacement then 0x80 else 0)lor((r land 7)lsl 3)lor(b land 7));
    if b land 7=4 then M.u8 m 0x24;
    if displacement then M.u32 m n in
  let address bits op reg (declared,base,n) =
    (match declared with Some w when w<>bits->Asm_contract.fail "memory width differs from register width"|_->());
    let r=register reg and b=register base in prefix bits r b (bits=8&&r>=4);
    M.bytes m op;modrm r base n in
  let require_flags ()=if not !flags then Asm_contract.fail "condition flags must be initialized by cmp/test"in
  List.iter(function
    |("add"|"sub" as op),["rsp";amount]->
        let n=immediate 64 amount in
        if n<0L then Asm_contract.fail "stack adjustment must be nonnegative";
        (if op="sub"then reserve else release)n;
        group 0x81 (if op="sub"then 5 else 0) "rsp";emit_imm 64 n;flags:=false
    |("push"|"pop" as op),[reg]->
        if width reg<>64 then Asm_contract.fail "push/pop requires a 64-bit register";
        if op="push"then(read reg;reserve 8L)else(write reg;release 8L);
        let r=register reg in if r>=8 then M.u8 m 0x41;
        M.u8 m((if op="push"then 0x50 else 0x58)lor(r land 7))
    |"lea",[dst;src]->
        if width dst<>64 then Asm_contract.fail "lea requires a 64-bit destination";
        let a=match memory src with Some((None,_,_)as a)->a
          |_->Asm_contract.fail "lea requires an unqualified memory address"in
        let _,base,_=a in read base;write dst;address 64 [0x8d] dst a
    |"mov",[dst;src]->(match memory dst,memory src with
      |Some((_,base,_)as a),None->read base;read src;let bits=width src in address bits[if bits=8 then 0x88 else 0x89]src a
      |None,Some((_,base,_)as a)->read base;write dst;let bits=width dst in address bits[if bits=8 then 0x8a else 0x8b]dst a
      |None,None->(match Int64.of_string_opt src with
        |Some n->let bits=width dst in
            if bits<>64 then ignore(immediate bits src);
            write dst;let d=register dst in prefix bits 0 d (bits=8&&d>=4);
            M.u8 m((if bits=8 then 0xb0 else 0xb8)lor(d land 7));
            if bits=64 then M.u64 m n else emit_imm bits n
        |None->read src;write dst;rr [if width dst=8 then 0x88 else 0x89]dst src)
      |_->Asm_contract.fail "memory-to-memory mov is unsupported")
    |("movzx"|"movsx"|"movsxd" as op),[dst;src]->
        let dw=width dst in
        let sw,base,operand=match memory src with
          |Some((Some sw,b,_)as a)->sw,Some b,`Memory a
          |Some _->Asm_contract.fail "extension load requires explicit memory width"
          |None->width src,None,`Register src in
        if not(dw>sw && (sw=8||sw=16||op="movsxd"&&sw=32&&dw=64))||op="movsxd"&&sw<>32 then
          Asm_contract.fail "unsupported integer extension widths";
        Option.iter read base;(match operand with `Register r->read r|_->());write dst;
        let d=register dst in
        let bytes=if op="movsxd"then [0x63]else[0x0f;(if op="movzx"then 0xb6 else 0xbe)+(if sw=16 then 1 else 0)]in
        (match operand with
         |`Register r->let s=register r in prefix dw d s (sw=8&&s>=4);M.bytes m bytes;
             M.u8 m(0xc0 lor((d land 7)lsl 3)lor(s land 7))
         |`Memory(_,b,n)->let br=register b in prefix dw d br false;M.bytes m bytes;modrm d b n)
    |("add"|"sub"|"xor"|"and"|"or"|"cmp"|"test" as op),[dst;src]->
        let bits=width dst in read dst;
        (match Int64.of_string_opt src with
         |Some _->let n=immediate bits src in if op<>"cmp"&&op<>"test"then write dst;
             if op="test"then group(if bits=8 then 0xf6 else 0xf7)0 dst
             else group(if bits=8 then 0x80 else 0x81)(List.assoc op["add",0;"or",1;"and",4;"sub",5;"xor",6;"cmp",7])dst;
             emit_imm bits n
         |None->read src;if op<>"cmp"&&op<>"test"then write dst;
             let opcode=List.assoc op["add",0x01;"sub",0x29;"xor",0x31;"and",0x21;"or",0x09;"cmp",0x39;"test",0x85]in
             rr [opcode-(if bits=8 then 1 else 0)]dst src);
        flags:=op="cmp"||op="test"
    |"imul",[dst;src]->
        let bits=width dst in if bits=8 then Asm_contract.fail "two-operand imul requires 16/32/64-bit operands";
        read dst;let d=register dst in
        (match Int64.of_string_opt src with
         |Some _->let n=immediate bits src in write dst;prefix bits d d false;M.u8 m 0x69;
             M.u8 m(0xc0 lor((d land 7)lsl 3)lor(d land 7));emit_imm bits n
         |None->ignore(same dst src);read src;write dst;let s=register src in prefix bits d s false;M.bytes m[0x0f;0xaf];M.u8 m(0xc0 lor((d land 7)lsl 3)lor(s land 7)));
        flags:=false
    |("shl"|"shr"|"sar" as op),[dst;count]->
        read dst;let bits=width dst and extension=List.assoc op["shl",4;"shr",5;"sar",7]in
        if count="cl"then(read "cl";write dst;group(if bits=8 then 0xd2 else 0xd3)extension dst)
        else(let n=match Int64.of_string_opt count with Some n when n>=0L && n<Int64.of_int bits->Int64.to_int n
          |_->Asm_contract.fail "shift count must fit register width (0..63 for 64-bit) or cl"in
          write dst;group(if bits=8 then 0xc0 else 0xc1)extension dst;M.u8 m n);flags:=false
    |("neg"|"not" as op),[dst]->read dst;write dst;group(if width dst=8 then 0xf6 else 0xf7)(if op="neg"then 3 else 2)dst;
        if op="neg"then flags:=false
    |"bswap",[dst]->let bits=width dst in if bits<>32 && bits<>64 then Asm_contract.fail "bswap requires 32/64-bit register";
        read dst;write dst;let d=register dst in prefix bits 0 d false;M.bytes m[0x0f;0xc8 lor(d land 7)]
    |name,[dst]when String.starts_with ~prefix:"set" name->
        let condition=String.sub name 3(String.length name-3)in
        let condition=match List.assoc_opt condition conditions with Some c->c|None->Asm_contract.fail "unsupported setcc condition"in
        if width dst<>8 then Asm_contract.fail "setcc requires an 8-bit destination";
        require_flags();write dst;let d=register dst in prefix 8 0 d(d>=4);M.bytes m[0x0f;0x90 lor condition;0xc0 lor(d land 7)]
    |"rdtsc",[]->write "eax";write "edx";M.bytes m[0x0f;0x31]
    |"cpuid",[]->read "eax";read "ecx";List.iter write["eax";"ebx";"ecx";"edx"];
        M.bytes m[0x0f;0xa2];flags:=false
    |"nop",[]->M.u8 m 0x90|"pause",[]->M.bytes m[0xf3;0x90]
    |"mfence",[]->M.bytes m[0x0f;0xae;0xf0]|"lfence",[]->M.bytes m[0x0f;0xae;0xe8]|"sfence",[]->M.bytes m[0x0f;0xae;0xf8]
    |name,_->Asm_contract.fail("unsupported x86-64 instruction or operands '"^name^"'"))
    (Asm_contract.instructions spec.template);
  finish_stack();finish();Buffer.contents m.buffer
