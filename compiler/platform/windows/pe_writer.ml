(* SPDX-License-Identifier: Apache-2.0 *)
(* Format contracts: https://learn.microsoft.com/windows/win32/debug/pe-format
   Unwind: https://learn.microsoft.com/cpp/build/exception-handling-x64 *)
exception Error of string
let fail message = raise(Error message)
type section = Code | Rodata | Data
type address = { section : section; offset : int }
type pointer = { at : address; target : address }
type unwind_operation = Push_nonvol of int | Alloc_stack of int | Set_frame of int * int
  | Save_nonvol of int * int | Save_xmm of int * int
type unwind_code = { code_offset : int; operation : unwind_operation }
type runtime_function = {
  begin_offset : int; end_offset : int; prolog_size : int; codes : unwind_code list;
}

let limit = 0x7fffffff
let checked n = if n<0 || n>limit then fail "PE image exceeds 2 GiB";n
let add a b = ignore(checked a);ignore(checked b);checked(a+b)
let align n amount = add n (amount-1) / amount * amount
let number out width value =
  for i=0 to width-1 do Buffer.add_char out
    (Char.chr Int64.(to_int(logand(shift_right_logical value (8*i))255L)))done
let int out width value = number out width (Int64.of_int value)
let pad out position =
  if position<Buffer.length out then fail "overlapping PE output regions";
  Buffer.add_string out(String.make(position-Buffer.length out)'\000')
let patch bytes offset width value =
  for i=0 to width-1 do Bytes.set bytes (offset+i)
    (Char.chr Int64.(to_int(logand(shift_right_logical value (8*i))255L)))done
let nonvolatile = function 3|5|6|7|12|13|14|15->true|_->false

let unwind_info code_size functions =
  let functions=List.sort(fun a b->compare a.begin_offset b.begin_offset)functions in
  let out=Buffer.create 64 and previous_end=ref 0 in
  let records=List.map(fun f->
    if f.begin_offset< !previous_end || f.end_offset<=f.begin_offset ||
       f.end_offset>code_size || f.prolog_size<0 || f.prolog_size>255 ||
       f.prolog_size>f.end_offset-f.begin_offset then fail "invalid PE function range/prolog";
    previous_end:=f.end_offset;
    let codes=List.sort(fun a b->compare b.code_offset a.code_offset)f.codes in
    let encoded=Buffer.create 16 and last=ref 256 and frame=ref 0 in
    let allocations=List.filter_map(fun c->match c.operation with Alloc_stack n->Some n|_->None)codes in
    let frame_offset=List.find_map(fun c->match c.operation with Set_frame _->Some c.code_offset|_->None)codes in
    List.iter(fun c->match c.operation,frame_offset with
      |(Save_nonvol _|Save_xmm _),Some at when c.code_offset<=at->
          fail "PE register saves must follow frame-pointer establishment"
      |_->())codes;
    if List.length allocations>1 then fail "multiple stack allocations in PE prolog are unsupported";
    List.iter(fun c->
      if c.code_offset<=0 || c.code_offset>f.prolog_size || c.code_offset>= !last then
        fail "invalid/duplicate PE unwind code offset";
      last:=c.code_offset;
      let op opcode info = int encoded 1 c.code_offset;int encoded 1 (opcode lor(info lsl 4))in
      match c.operation with
      |Push_nonvol reg->if not(nonvolatile reg)then fail "invalid PE saved register";op 0 reg
      |Alloc_stack size->
          if size<=0 || size>0xfffffff8 || size mod 8<>0 then fail "invalid PE stack allocation";
          if size<=128 then op 2 (size/8-1)
          else if size/8<=0xffff then (op 1 0;int encoded 2 (size/8))
          else (op 1 1;int encoded 4 size)
      |Save_nonvol(reg,offset)->
          if not(nonvolatile reg) || offset<0 || offset mod 8<>0 || offset/8>0xffff then
            fail "invalid PE saved GP register offset";
          if offset+8>List.fold_left (+) 0 allocations then fail "PE GP save exceeds allocation";
          op 4 reg;int encoded 2(offset/8)
      |Save_xmm(reg,offset)->
          if reg<6 || reg>15 || offset<0 || offset mod 16<>0 || offset/16>0xffff then
            fail "invalid PE saved XMM register offset";
          if offset+16>List.fold_left (+) 0 allocations then fail "PE XMM save exceeds allocation";
          op 8 reg;int encoded 2(offset/16)
      |Set_frame(reg,offset)->
          if !frame<>0 || not(nonvolatile reg) || offset<0 || offset>240 || offset mod 16<>0 then
            fail "invalid PE frame register";
          if not(List.exists(fun c'->c'.code_offset<c.code_offset && c'.operation=Push_nonvol reg)codes)then
            fail "PE frame register must first be pushed";
          if offset>List.fold_left (+) 0 allocations then fail "PE frame offset exceeds allocation";
          frame:=reg lor((offset/16)lsl 4);op 3 0)codes;
    let count=Buffer.length encoded/2 in
    if count>255 then fail "too many PE unwind slots";
    let offset=Buffer.length out in
    int out 1 1;int out 1 f.prolog_size;int out 1 count;int out 1 !frame;
    Buffer.add_buffer out encoded;pad out(align(Buffer.length out)4);
    f.begin_offset,f.end_offset,offset)functions in
  records,Buffer.contents out

type image_section = {
  name : string; size : int; mutable contents : bytes; flags : int;
  mutable rva : int; mutable file_offset : int;
}
let section name size contents flags =
  ignore(checked size);
  if Bytes.length contents>size then fail "PE raw data exceeds virtual section size";
  {name;size;contents;flags;rva=0;file_offset=0}
let image_base = 0x140000000L
let va rva = Int64.add image_base (Int64.of_int rva)

let executable ?(stack_reserve=0x100000L) ?(stack_commit=0x1000L)
    ~entry ~code_size ~rodata ~data ~bss_size ~imports ~pointers ~functions ~encode () =
  if code_size<=0 || entry<0 || entry>=code_size then fail "PE entry is outside code";
  ignore(checked code_size);
  if stack_commit<=0L || stack_reserve<stack_commit ||
     Int64.rem stack_reserve 0x1000L<>0L || Int64.rem stack_commit 0x1000L<>0L then
    fail "invalid PE stack reserve/commit";
  let valid_name name=if name="" || String.contains name '\000' then fail "invalid PE import name"in
  let groups=List.fold_left(fun groups (library,symbol)->
    valid_name library;valid_name symbol;
    let key=String.lowercase_ascii library in
    if List.exists(fun(lib,_)->String.lowercase_ascii lib=key)groups then
      List.map(fun(lib,symbols)->if String.lowercase_ascii lib=key then
        lib,(if List.mem symbol symbols then symbols else symbols@[symbol])else lib,symbols)groups
    else groups@[library,[symbol]])[]imports in
  (* Descriptor, lookup and address tables each include a null terminator.
     All IAT arrays are contiguous, independently of general writable data. *)
  let idata=Buffer.create 128 in
  if groups<>[]then pad idata(20*(List.length groups+1));
  let lookups=List.map(fun(_,symbols)->pad idata(align(Buffer.length idata)8);
    let offset=Buffer.length idata in pad idata(add offset (8*(List.length symbols+1)));offset)groups in
  let iat_start=Buffer.length idata in
  let iats=List.map(fun(_,symbols)->let offset=Buffer.length idata in
    pad idata(add offset (8*(List.length symbols+1)));offset)groups in
  let iat_size=Buffer.length idata-iat_start in
  let names=List.map(fun(lib,symbols)->
    let dll=Buffer.length idata in Buffer.add_string idata(lib^"\000");
    let symbols=List.map(fun symbol->pad idata(align(Buffer.length idata)2);
      let offset=Buffer.length idata in int idata 2 0;Buffer.add_string idata(symbol^"\000");offset)symbols in
    dll,symbols)groups in
  let records,xdata=unwind_info code_size functions in
  let text=section ".text" code_size Bytes.empty 0x60000020
  and constants=section ".rdata" (String.length rodata) (Bytes.of_string rodata) 0x40000040
  and writable=section ".data" (add(String.length data)bss_size) (Bytes.of_string data) 0xc0000040
  and imports_section=section ".idata" (Buffer.length idata) (Bytes.of_string(Buffer.contents idata)) 0xc0000040
  and pdata=section ".pdata" (12*List.length records) (Bytes.make(12*List.length records)'\000') 0x40000040
  and unwind=section ".xdata" (String.length xdata) (Bytes.of_string xdata) 0x40000040 in
  let sections=List.filter(fun s->s.size>0)[text;constants;writable;imports_section;pdata;unwind]in
  (* Assign RVAs before serializing relocations; the final .reloc section cannot
     move any of the sections it describes. All file/image additions are checked. *)
  let next_rva=ref 0x1000 in
  List.iter(fun s->s.rva<- !next_rva;next_rva:=add !next_rva(align s.size 0x1000))sections;
  let resolve a = let s=match a.section with Code->text|Rodata->constants|Data->writable in
    if a.offset<0 || a.offset>=s.size then fail "PE pointer target is outside section";
    s,add s.rva a.offset in
  let pointer_locations=List.map(fun p->
    let s,rva=resolve p.at in
    let initialized_size=if s==text then code_size else Bytes.length s.contents in
    if p.at.offset>initialized_size-8 then fail "PE pointer location is not backed by eight bytes";
    let _,target=resolve p.target in s,p.at.offset,rva,va target)pointers in
  let pointer_locations=List.sort(fun(_,_,a,_) (_,_,b,_)->compare a b)pointer_locations in
  let previous=ref (-8)in
  List.iter(fun(_,_,rva,_)->if rva< !previous+8 then fail "overlapping PE pointer fixups";
    previous:=rva)pointer_locations;
  let reloc=Buffer.create 32 in
  let rec relocation_blocks = function
    |[]->()
    |(_,_,first,_)::_ as entries->
        let page=first land (lnot 0xfff)in
        let here,rest=List.partition(fun(_,_,rva,_)->rva land(lnot 0xfff)=page)entries in
        int reloc 4 page;int reloc 4 (align(8+2*List.length here)4);
        List.iter(fun(_,_,rva,_)->int reloc 2 (0xa000 lor(rva-page)))here;
        pad reloc(align(Buffer.length reloc)4);relocation_blocks rest in
  relocation_blocks pointer_locations;
  let reloc_section=section ".reloc" (Buffer.length reloc) (Bytes.of_string(Buffer.contents reloc)) 0x42000040 in
  let sections=if reloc_section.size=0 then sections else begin
    reloc_section.rva<- !next_rva;next_rva:=add !next_rva(align reloc_section.size 0x1000);
    sections@[reloc_section]end in
  List.iteri(fun i ((_,symbols),lookup,iat,(dll,hints))->
    let rva offset=Int64.of_int(add imports_section.rva offset)in
    let field offset value=patch imports_section.contents (20*i+offset)4 value in
    field 0 (rva lookup);field 12(rva dll);field 16(rva iat);
    List.iteri(fun j _->let hint=rva(List.nth hints j)in
      patch imports_section.contents(lookup+8*j)8 hint;
      patch imports_section.contents(iat+8*j)8 hint)symbols)
    (List.mapi(fun i group->group,List.nth lookups i,List.nth iats i,List.nth names i)groups);
  let import_address ~library ~symbol =
    match List.find_opt(fun(_,((lib,_),_))->String.lowercase_ascii lib=String.lowercase_ascii library)
      (List.mapi(fun i group->i,(group,List.nth iats i))groups)with
    |None->fail("unknown PE import library: "^library)
    |Some(_,((_,symbols),iat))->
        let rec find i=function
          |[]->fail("unknown PE import symbol: "^symbol)
          |s::rest->if s=symbol then va(add imports_section.rva(iat+8*i))else find(i+1)rest in
        find 0 symbols in
  let code=encode ~code_address:(va text.rva) ~rodata_address:(va constants.rva)
    ~data_address:(va writable.rva) ~import_address in
  if Bytes.length code<>code_size then fail "PE encoder changed code size";
  text.contents<-code;
  List.iter(fun(s,offset,_,value)->patch s.contents offset 8 value)pointer_locations;
  List.iteri(fun i (begin_,end_,info)->
    List.iteri(fun j value->patch pdata.contents(12*i+4*j)4(Int64.of_int value))
      [add text.rva begin_;add text.rva end_;add unwind.rva info])records;
  let headers=align(0x80+4+20+240+40*List.length sections)0x200 in
  let next_file=ref headers in
  List.iter(fun s->if Bytes.length s.contents>0 then begin
    s.file_offset<- !next_file;next_file:=add !next_file(align(Bytes.length s.contents)0x200)end)sections;
  let out=Buffer.create !next_file in
  (* DOS exit stub; e_lfanew at 0x3c points to the aligned PE header. *)
  Buffer.add_string out "MZ";int out 2 0x80;int out 2 1;int out 2 0;
  int out 2 4;int out 2 0;int out 2 0xffff;int out 2 0;int out 2 0xb8;
  int out 2 0;int out 2 0;int out 2 0;int out 2 0x40;int out 2 0;
  pad out 0x3c;int out 4 0x80;
  Buffer.add_string out "\184\001\076\205\033";pad out 0x80;
  Buffer.add_string out "PE\000\000";int out 2 0x8664;int out 2(List.length sections);
  int out 4 0;int out 4 0;int out 4 0;int out 2 240;
  (* A fixed-base image is explicit when it has no absolute pointer fixups. *)
  int out 2 (if pointers=[]then 0x23 else 0x22);
  int out 2 0x20b;int out 1 0;int out 1 0;
  int out 4(align code_size 0x200);
  int out 4(List.fold_left(fun n s->if s==text then n else add n(align(Bytes.length s.contents)0x200))0 sections);
  int out 4 bss_size;int out 4(add text.rva entry);int out 4 text.rva;
  number out 8 image_base;int out 4 0x1000;int out 4 0x200;
  int out 2 6;int out 2 0;int out 2 0;int out 2 0;int out 2 6;int out 2 0;
  int out 4 0;int out 4 !next_rva;int out 4 headers;int out 4 0;
  int out 2 3;int out 2 (if pointers=[]then 0x100 else 0x160);
  number out 8 stack_reserve;number out 8 stack_commit;number out 8 0x100000L;number out 8 0x1000L;
  int out 4 0;int out 4 16;
  for i=0 to 15 do
    let address,size=match i with
      |1 when groups<>[]->imports_section.rva,20*(List.length groups+1)
      |3 when records<>[]->pdata.rva,pdata.size
      |5 when pointers<>[]->reloc_section.rva,reloc_section.size
      |12 when groups<>[]->imports_section.rva+iat_start,iat_size
      |_->0,0 in
    int out 4 address;int out 4 size
  done;
  List.iter(fun s->Buffer.add_string out(s.name^String.make(8-String.length s.name)'\000');
    int out 4 s.size;int out 4 s.rva;int out 4(align(Bytes.length s.contents)0x200);int out 4 s.file_offset;
    int out 4 0;int out 4 0;int out 2 0;int out 2 0;int out 4 s.flags)sections;
  pad out headers;
  List.iter(fun s->if Bytes.length s.contents>0 then begin
    pad out s.file_offset;Buffer.add_bytes out s.contents;
    pad out(add s.file_offset(align(Bytes.length s.contents)0x200))end)sections;
  if Buffer.length out<> !next_file then fail "PE file size mismatch";
  Bytes.of_string(Buffer.contents out)
