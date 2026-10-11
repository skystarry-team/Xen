(* SPDX-License-Identifier: Apache-2.0 *)
module M = Machine_ir

let align value alignment = ((value + alignment - 1) / alignment) * alignment

let static_x86_64 ~entry image =
  let code_offset = 0x1000 and base = 0x400000L in
  let code_size = Buffer.length image.M.buffer in
  let rodata_size = Buffer.length image.M.rodata and data_size = Buffer.length image.M.data in
  let rodata_offset = align (code_offset + code_size) 0x1000 in
  let data_offset = align (rodata_offset + rodata_size) 0x1000 in
  let code_address = Int64.add base (Int64.of_int code_offset) in
  let rodata_address = Int64.add base (Int64.of_int rodata_offset) in
  let data_address = Int64.add base (Int64.of_int data_offset) in
  let code = M.encode ~code_address ~rodata_address ~data_address image in
  let output = M.create () in
  M.bytes output [0x7f;0x45;0x4c;0x46;2;1;1;0]; for _ = 1 to 8 do M.u8 output 0 done;
  M.u8 output 2; M.u8 output 0; M.u8 output 0x3e; M.u8 output 0;
  M.u32 output 1L;
  M.u64 output (Int64.add base (Int64.of_int (code_offset + entry)));
  M.u64 output 64L; M.u64 output 0L; M.u32 output 0L;
  M.u8 output 64; M.u8 output 0; M.u8 output 56; M.u8 output 0;
  M.u8 output 3; M.u8 output 0; M.u8 output 0; M.u8 output 0;
  M.u8 output 0; M.u8 output 0; M.u8 output 0; M.u8 output 0;
  M.u32 output 1L; M.u32 output 5L; M.u64 output 0L;
  M.u64 output base; M.u64 output base;
  M.u64 output (Int64.of_int (code_offset + code_size)); M.u64 output (Int64.of_int (code_offset + code_size)); M.u64 output 0x1000L;
  M.u32 output 1L; M.u32 output 4L; M.u64 output (Int64.of_int rodata_offset);
  M.u64 output rodata_address; M.u64 output rodata_address;
  M.u64 output (Int64.of_int rodata_size); M.u64 output (Int64.of_int rodata_size); M.u64 output 0x1000L;
  M.u32 output 1L; M.u32 output 6L; M.u64 output (Int64.of_int data_offset);
  M.u64 output data_address; M.u64 output data_address;
  M.u64 output (Int64.of_int data_size); M.u64 output (Int64.of_int data_size); M.u64 output 0x1000L;
  while M.position output < code_offset do M.u8 output 0 done;
  Buffer.add_bytes output.buffer code;
  while M.position output < rodata_offset do M.u8 output 0 done;
  Buffer.add_buffer output.buffer image.M.rodata;
  while M.position output < data_offset do M.u8 output 0 done;
  Buffer.add_buffer output.buffer image.M.data;
  Bytes.of_string (Buffer.contents output.buffer)
