(* SPDX-License-Identifier: Apache-2.0 *)
(* ELF64 ET_EXEC with eager symbol relocations. CPU emitters own call lowering;
   this writer owns only Linux program loading and shared-library metadata. *)
let number out width n = for i=0 to width-1 do Buffer.add_char out
  (Char.chr Int64.(to_int(logand(shift_right_logical n(8*i))255L)))done
let int out width n=number out width(Int64.of_int n)
let pad out offset=Buffer.add_string out(String.make(offset-Buffer.length out)'\000')
let align out n=pad out(Type_desc.align_up(Buffer.length out)n)

let executable ~aarch64 ~entry ~imports ~code_size ~rodata ~data ~encode =
  let page=if aarch64 then 0x10000 else 0x1000 in
  let base=0x400000L and headers=7 and interp_offset=64+7*56 in
  let addr n=Int64.add base(Int64.of_int n)in
  let interpreter=if aarch64 then "/lib/ld-linux-aarch64.so.1\000"else "/lib64/ld-linux-x86-64.so.2\000"in
  let ro=Buffer.create 1024 in Buffer.add_buffer ro rodata;align ro 8;
  let strings=Buffer.create 128 in Buffer.add_char strings '\000';
  let string s=let offset=Buffer.length strings in Buffer.add_string strings s;Buffer.add_char strings '\000';offset in
  let libraries=List.fold_left(fun xs(lib,_,_)->if List.mem lib xs then xs else xs@[lib])[]imports in
  let needed=List.map string libraries and origin=string "$ORIGIN"in
  let names=List.map(fun(_,symbol,_)->string symbol)imports in
  let str_offset=Buffer.length ro in Buffer.add_buffer ro strings;align ro 8;
  let sym_offset=Buffer.length ro in Buffer.add_string ro(String.make 24 '\000');
  List.iter(fun name->int ro 4 name;int ro 1 0x12;int ro 1 0;int ro 2 0;int ro 8 0;int ro 8 0)names;
  let hash_offset=Buffer.length ro and count=List.length imports in
  int ro 4 1;int ro 4(count+1);int ro 4(if count=0 then 0 else 1);int ro 4 0;
  for i=1 to count do int ro 4(if i=count then 0 else i+1)done;
  align ro 8;let rela_offset=Buffer.length ro in
  let rodata_offset=Type_desc.align_up(page+code_size)page in
  let data_offset=Type_desc.align_up(rodata_offset+rela_offset+24*count)page in
  let roaddr off=addr(rodata_offset+off)in
  List.iteri(fun i(_,_,got)->number ro 8(addr(data_offset+got));
    number ro 8(Int64.logor(Int64.shift_left(Int64.of_int(i+1))32)(if aarch64 then 1025L else 6L));int ro 8 0)imports;
  let rw=Buffer.create 256 in Buffer.add_buffer rw data;align rw 8;
  let dynamic_offset=Buffer.length rw in
  let tag kind value=int rw 8 kind;number rw 8 value in
  List.iter(fun name->tag 1(Int64.of_int name))needed;
  List.iter(fun(k,off)->tag k(roaddr off))[5,str_offset;6,sym_offset;4,hash_offset;7,rela_offset];
  tag 10(Int64.of_int(Buffer.length strings));tag 11 24L;
  tag 8(Int64.of_int(24*count));tag 9 24L;tag 29(Int64.of_int origin);
  tag 24 0L;tag 21 0L;tag 0 0L;
  let dynamic_size=Buffer.length rw-dynamic_offset in
  let code=encode ~code_address:(addr page)~rodata_address:(addr rodata_offset)~data_address:(addr data_offset)in
  let out=Buffer.create(data_offset+Buffer.length rw)in
  Buffer.add_string out "\127ELF\002\001\001\000\000\000\000\000\000\000\000\000";
  int out 2 2;int out 2(if aarch64 then 183 else 62);int out 4 1;
  number out 8(addr(page+entry));int out 8 64;int out 8 0;int out 4 0;
  int out 2 64;int out 2 56;int out 2 headers;int out 2 0;int out 2 0;int out 2 0;
  let segment kind flags offset size alignment=
    int out 4 kind;int out 4 flags;int out 8 offset;number out 8(addr offset);number out 8(addr offset);
    int out 8 size;int out 8 size;int out 8 alignment in
  segment 6 4 64(headers*56)8;
  segment 3 4 interp_offset(String.length interpreter)1;
  segment 1 5 0(page+Bytes.length code)page;
  segment 1 4 rodata_offset(Buffer.length ro)page;
  segment 1 6 data_offset(Buffer.length rw)page;
  segment 2 6(data_offset+dynamic_offset)dynamic_size 8;
  int out 4 0x6474e551;int out 4 6;for _=1 to 5 do int out 8 0 done;int out 8 16;
  pad out interp_offset;Buffer.add_string out interpreter;
  pad out page;Buffer.add_bytes out code;pad out rodata_offset;Buffer.add_buffer out ro;
  pad out data_offset;Buffer.add_buffer out rw;Bytes.of_string(Buffer.contents out)
