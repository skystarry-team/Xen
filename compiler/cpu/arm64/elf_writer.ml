(* SPDX-License-Identifier: Apache-2.0 *)
module M = Machine_ir

(* 64KiB segment boundaries work with Linux's 4/16/64KiB AArch64 pages. *)
let static_linux ~entry image =
  let page=0x10000 and base=0x400000L in
  let align n = Type_desc.align_up n page in
  let code_offset=page in
  let rodata_offset=align(code_offset+Buffer.length image.M.code) in
  let data_offset=align(rodata_offset+Buffer.length image.M.rodata) in
  let addr n=Int64.add base(Int64.of_int n) in
  let code=M.encode image ~code_address:(addr code_offset)
    ~rodata_address:(addr rodata_offset) ~data_address:(addr data_offset) in
  let out=Buffer.create(data_offset+Buffer.length image.M.data) in
  let number width n = for i=0 to width-1 do Buffer.add_char out
    (Char.chr Int64.(to_int(logand(shift_right_logical n (8*i))255L))) done in
  let u16 n=number 2(Int64.of_int n) and u32 n=number 4(Int64.of_int n)
  and u64 n=number 8(Int64.of_int n) in
  Buffer.add_string out "\127ELF\002\001\001\000\000\000\000\000\000\000\000\000";
  u16 2;u16 183;u32 1;number 8(addr(code_offset+entry));
  u64 64;u64 0;u32 0;u16 64;u16 56;u16 4;u16 0;u16 0;u16 0;
  let segment kind flags offset size =
    u32 kind;u32 flags;u64 offset;number 8(addr offset);number 8(addr offset);
    u64 size;u64 size;u64 page in
  segment 1 5 0 (code_offset+Bytes.length code);
  segment 1 4 rodata_offset (Buffer.length image.M.rodata);
  segment 1 6 data_offset (Buffer.length image.M.data);
  u32 0x6474e551;u32 6;u64 0;u64 0;u64 0;u64 0;u64 0;u64 16;
  let pad offset=Buffer.add_string out(String.make(offset-Buffer.length out)'\000') in
  pad code_offset;Buffer.add_bytes out code;
  pad rodata_offset;Buffer.add_buffer out image.M.rodata;
  pad data_offset;Buffer.add_buffer out image.M.data;
  Bytes.of_string(Buffer.contents out)
