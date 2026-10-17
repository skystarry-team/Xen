(* SPDX-License-Identifier: Apache-2.0 *)
(* CPU-independent, thin little-endian Mach-O64 PIE writer. The encoder must
   return position-independent code; absolute address fixups are not permitted.
   dyld starts the LC_MAIN function using the platform C argc/argv convention.
   libSystem is loaded for dyld initialization, but this image imports no symbols.
   Ad-hoc SHA-256 signatures are emitted directly, without codesign or a linker.
   Apple Silicon native execution is checked by macOS CI. See
   MACOS_VALIDATION.md for the validation scope. *)
exception Error of string
let fail message = raise(Error message)
let align n amount =
  if n<0 || n>0xffffffff-amount then fail "Mach-O file offset exceeds 32 bits";
  (n+amount-1)/amount*amount
let append_number out ~big width number =
  for i=0 to width-1 do
    let shift=8*(if big then width-1-i else i) in
    Buffer.add_char out (Char.chr Int64.(to_int(logand(shift_right_logical number shift)255L)))
  done
let code_signature ~text_size image =
  let limit=String.length image in
  let slots=(limit+4095)/4096 in
  let identifier="org.xen.generated\000" in
  let hash_offset=88+String.length identifier in
  let directory_size=hash_offset+slots*32 in
  let out=Buffer.create (directory_size+20) in
  let u32 n=append_number out ~big:true 4(Int64.of_int n)
  and u64 n=append_number out ~big:true 8(Int64.of_int n) in
  u32 0xfade0cc0;u32(directory_size+20);u32 1;u32 0;u32 20;
  u32 0xfade0c02;u32 directory_size;u32 0x20400;u32 2;
  u32 hash_offset;u32 88;u32 0;u32 slots;u32 limit;
  Buffer.add_string out "\032\002\000\012";
  u32 0;u32 0;u32 0;u32 0;u64 0;u64 0;u64 text_size;u64 1;
  Buffer.add_string out identifier;
  for i=0 to slots-1 do
    Buffer.add_string out (Sha256.digest_substring image (i*4096) (min 4096(limit-i*4096)))
  done;
  Bytes.of_string(Buffer.contents out)

let executable ~architecture ~entry ~code_size ~rodata ~data ~encode =
  if code_size<=0 || entry<0 || entry>=code_size then fail "Mach-O entry is outside code";
  if architecture=Target.Aarch64 && (entry mod 4<>0 || code_size mod 4<>0) then
    fail "Mach-O AArch64 code/entry is unaligned";
  let cpu,subtype,page=match architecture with
    |Target.Aarch64->0x0100000c,0,16384
    |Target.X86_64->0x01000007,3,4096 in
  let commands=Buffer.create 1024 in
  let number width n=append_number commands ~big:false width n in
  let u32 n=number 4(Int64.of_int n) and u64 n=number 8(Int64.of_int n) in
  let text name=if String.length name>16 then fail "Mach-O section name too long";
    Buffer.add_string commands name;Buffer.add_string commands(String.make(16-String.length name)'\000') in
  let command_string kind prefix path =
    let command_size=align(prefix+String.length path+1)8 in
    u32 kind;u32 command_size;u32 prefix;
    if prefix=24 then (u32 0;u32 0x10000;u32 0x10000);
    Buffer.add_string commands path;
    Buffer.add_string commands(String.make(command_size-prefix-String.length path)'\000') in
  let dylinker_size=align(12+String.length "/usr/lib/dyld"+1)8
  and libsystem_size=align(24+String.length "/usr/lib/libSystem.B.dylib"+1)8 in
  let command_size=72*5+80*3+dylinker_size+libsystem_size+24+24+48+24+80+24+16 in
  let code_offset=align(32+command_size)16 in
  let text_size=align(code_offset+code_size)page in
  let rodata_offset=text_size in
  let rodata_size=align(max 1(String.length rodata))page in
  let data_offset=rodata_offset+rodata_size in
  let data_size=align(max 1(String.length data))page in
  let linkedit_offset=data_offset+data_size in
  (* The empty string table occupies one byte; signature follows at 16-byte alignment. *)
  let signature_offset=align(linkedit_offset+1)16 in
  let signature_size=20+88+String.length "org.xen.generated\000"+((signature_offset+4095)/4096)*32 in
  let file_size=signature_offset+signature_size in
  ignore(align file_size 16);
  let base=0x100000000L in
  let addr n=Int64.add base(Int64.of_int n) in
  let segment name offset memory_size file_length protection sections =
    u32 0x19;u32(72+80*List.length sections);text name;
    number 8 (if name="__PAGEZERO" then 0L else addr offset);
    number 8 (if name="__PAGEZERO" then base else Int64.of_int memory_size);
    u64 offset;u64 file_length;u32 protection;u32 protection;u32(List.length sections);u32 0;
    List.iter(fun(section,section_offset,size,alignment,flags)->
      text section;text name;number 8(addr section_offset);u64 size;
      u32 section_offset;u32 alignment;u32 0;u32 0;u32 flags;u32 0;u32 0;u32 0)sections in
  segment "__PAGEZERO" 0 0 0 0 [];
  segment "__TEXT" 0 text_size text_size 5 ["__text",code_offset,code_size,4,0x80000400];
  segment "__RODATA" rodata_offset rodata_size rodata_size 1 ["__const",rodata_offset,String.length rodata,3,0];
  segment "__DATA" data_offset data_size data_size 3 ["__data",data_offset,String.length data,3,0];
  segment "__LINKEDIT" linkedit_offset (align(file_size-linkedit_offset)page) (file_size-linkedit_offset) 1 [];
  command_string 0xe 12 "/usr/lib/dyld";
  command_string 0xc 24 "/usr/lib/libSystem.B.dylib";
  u32 0x80000028;u32 24;u64(code_offset+entry);u64 0;
  u32 0x32;u32 24;u32 1;u32 0x000c0000;u32 0x000c0000;u32 0;
  u32 0x80000022;u32 48;for _=1 to 10 do u32 0 done;
  u32 2;u32 24;u32 linkedit_offset;u32 0;u32 linkedit_offset;u32 1;
  u32 0xb;u32 80;for _=1 to 18 do u32 0 done;
  let code=encode ~code_address:(addr code_offset)
    ~rodata_address:(addr rodata_offset) ~data_address:(addr data_offset) in
  if Bytes.length code<>code_size then fail "Mach-O encoder changed code size";
  u32 0x1b;u32 24;
  let uuid=Bytes.of_string(String.sub(Sha256.digest(Bytes.to_string code^rodata^data))0 16) in
  Bytes.set uuid 6(Char.chr((Char.code(Bytes.get uuid 6)land 15)lor 0x50));
  Bytes.set uuid 8(Char.chr((Char.code(Bytes.get uuid 8)land 63)lor 0x80));
  Buffer.add_bytes commands uuid;
  u32 0x1d;u32 16;u32 signature_offset;u32 signature_size;
  if Buffer.length commands<>command_size then fail "Mach-O load command size mismatch";
  let out=Buffer.create file_size in
  let n width value=append_number out ~big:false width(Int64.of_int value) in
  n 4 0xfeedfacf;n 4 cpu;n 4 subtype;n 4 2;n 4 14;n 4 command_size;n 4 0x200085;n 4 0;
  Buffer.add_buffer out commands;
  let pad at=Buffer.add_string out(String.make(at-Buffer.length out)'\000') in
  pad code_offset;Buffer.add_bytes out code;
  pad rodata_offset;Buffer.add_string out rodata;
  pad data_offset;Buffer.add_string out data;
  pad signature_offset;
  Buffer.add_bytes out(code_signature ~text_size(Buffer.contents out));
  if Buffer.length out<>file_size then fail "Mach-O signature size mismatch";
  Bytes.of_string(Buffer.contents out)
