(* SPDX-License-Identifier: Apache-2.0 *)
(* Little-endian A64 instructions. No host assembler or linker is used. *)
type section = Code | Rodata | Data
type relocation = Branch26 of int | Address of int
type t = {
  code : Buffer.t; rodata : Buffer.t; data : Buffer.t;
  labels : (string, section * int) Hashtbl.t;
  mutable fixups : (int * relocation * string) list;
  mutable serial : int;
}
exception Error of string
let create () = {code=Buffer.create 4096;rodata=Buffer.create 256;
  data=Buffer.create 32;labels=Hashtbl.create 64;fixups=[];serial=0}
let position m = Buffer.length m.code
let fresh m prefix = m.serial <- m.serial+1; prefix ^ string_of_int m.serial
let word m n = for i=0 to 3 do Buffer.add_char m.code
  (Char.chr ((n lsr (i*8)) land 255)) done
let define m name section offset =
  if Hashtbl.mem m.labels name then raise(Error ("duplicate label: "^name));
  Hashtbl.add m.labels name (section,offset)
let label m name = define m name Code (position m)
let constant m text =
  let name=fresh m "constant_" in
  define m name Rodata (Buffer.length m.rodata);Buffer.add_string m.rodata text;name
let global m name =
  define m name Data (Buffer.length m.data);Buffer.add_string m.data (String.make 8 '\000')
let reg r = if r<0 || r>31 then invalid_arg "A64 register"
let imm m rd value =
  reg rd;
  for half=0 to 3 do
    let chunk=Int64.(to_int (logand (shift_right_logical value (16*half)) 65535L)) in
    word m ((if half=0 then 0xd2800000 else 0xf2800000) lor
      (half lsl 21) lor (chunk lsl 5) lor rd)
  done
let int m rd value = imm m rd (Int64.of_int value)
let mov m rd rn = reg rd;reg rn;word m (0xaa0003e0 lor (rn lsl 16) lor rd)
let rr m base rd rn rm = reg rd;reg rn;reg rm;
  word m (base lor (rm lsl 16) lor (rn lsl 5) lor rd)
let add m = rr m 0x8b000000
let sub m = rr m 0xcb000000
let mul m rd rn rm = rr m 0x9b007c00 rd rn rm
let multiply_high m = rr m 0x9bc07c00
let cmp m rn rm = rr m 0xeb000000 31 rn rm
let cmp_zero m rn = cmp m rn 31
let cset m rd cond = word m (0x9a9f07e0 lor ((cond lxor 1) lsl 12) lor rd)
let shift_right m rd rn shift =
  reg rd;reg rn;
  if shift<0 || shift>63 then invalid_arg "A64 shift";
  word m (0xd340fc00 lor (shift lsl 16) lor (rn lsl 5) lor rd)
let bit_and m = rr m 0x8a000000
let bit_or m = rr m 0xaa000000
(* Scalar FP scratch registers are v0..v7; v8..v15 are never clobbered.
   Values move through integer registers as bits, preserving the Xen storage ABI. *)
let fp_unary m base rd rn = reg rd;reg rn;word m (base lor (rn lsl 5) lor rd)
let fp_base ~single base = if single then base else base lor 0x00400000
let fp_from_bits m ~single = fp_unary m (if single then 0x1e270000 else 0x9e670000)
let fp_to_bits m ~single = fp_unary m (if single then 0x1e260000 else 0x9e660000)
let fp_neg m ~single = fp_unary m (fp_base ~single 0x1e214000)
let fp_binary m ~single operator =
  let base=match operator with
    |"+"->0x1e202800|"-"->0x1e203800|"*"->0x1e200800|"/"->0x1e201800
    |_->invalid_arg "A64 FP operator" in
  rr m (fp_base ~single base)
let fp_cmp m ~single rn rm = rr m (fp_base ~single 0x1e202000) 0 rn rm
let fp_convert m ~single = fp_unary m (if single then 0x1e624000 else 0x1e22c000)
let fp_of_int m ~single ~unsigned =
  fp_unary m (fp_base ~single (if unsigned then 0x9e230000 else 0x9e220000))
let fp_to_int m ~single ~unsigned =
  fp_unary m (fp_base ~single (if unsigned then 0x9e390000 else 0x9e380000))
let offset m rd rn n =
  (* x16 is reserved scratch. Extended-register ADD/SUB also permits SP. *)
  if rd=16 || rn=16 then invalid_arg "offset scratch register";
  int m 16 (abs n);
  rr m (if n<0 then 0xcb206000 else 0x8b206000) rd rn 16
let memory m ~load ~bytes ~signed rt rn displacement =
  if displacement<0 || displacement mod bytes<>0 || displacement/bytes>4095 then
    raise(Error "load/store offset out of range");
  let base=match bytes,load,signed with
    |1,true,true->0x39800000|2,true,true->0x79800000|4,true,true->0xb9800000
    |1,_,_->0x39000000|2,_,_->0x79000000|4,_,_->0xb9000000|8,_,_->0xf9000000
    |_->invalid_arg "A64 memory width" in
  let base=if load && not(signed && bytes<8) then base lor 0x00400000 else base in
  word m (base lor ((displacement/bytes) lsl 10) lor (rn lsl 5) lor rt)
let load m ?(bytes=8) ?(signed=false) rt rn displacement =
  memory m ~load:true ~bytes ~signed rt rn displacement
let store m ?(bytes=8) rt rn displacement =
  memory m ~load:false ~bytes ~signed:false rt rn displacement
let branch m ?(link=false) target =
  let base=if link then 0x94000000 else 0x14000000 in
  m.fixups <- (position m,Branch26 base,target)::m.fixups;word m base
let cond m condition target =
  (* Inverted short branch over an unconditional B extends range to +/-128MiB. *)
  word m (0x54000000 lor (2 lsl 5) lor (condition lxor 1));branch m target
let address m rd target =
  m.fixups <- (position m,Address rd,target)::m.fixups;imm m rd 0L
let ret m = word m 0xd65f03c0
let syscall ?(immediate=0) m =
  if immediate<0 || immediate>65535 then raise(Error "A64 SVC immediate out of range");
  word m (0xd4000001 lor (immediate lsl 5))
let branch_bits displacement =
  if displacement mod 4<>0 || displacement< -134217728 || displacement>=134217728
  then raise(Error "A64 branch is unaligned or exceeds +/-128MiB");
  (displacement/4) land 0x3ffffff
let encode ?(position_independent=false) m ~code_address ~rodata_address ~data_address =
  let code=Bytes.of_string(Buffer.contents m.code) in
  let set at n = for i=0 to 3 do Bytes.set code (at+i)
    (Char.chr ((n lsr (i*8)) land 255)) done in
  List.iter(fun(at,kind,name)->
    let section,pos=match Hashtbl.find_opt m.labels name with
      |Some value->value|None->raise(Error ("undefined label: "^name)) in
    match kind with
    |Branch26 base->if section<>Code then raise(Error "branch to non-code section");
        set at (base lor branch_bits (pos-at))
    |Address rd->
        let base=match section with Code->code_address|Rodata->rodata_address|Data->data_address in
        let value=Int64.add base (Int64.of_int pos) in
        if position_independent then begin
          (* ADRP addresses architectural 4KiB pages even on a 16KiB OS.
             Preserve the four-word fixup footprint used by absolute
             addresses so branches and code labels never move during encoding. *)
          let pc=Int64.add code_address(Int64.of_int at) in
          let page value=Int64.shift_right_logical value 12 in
          let delta=Int64.sub(page value)(page pc) in
          if delta< -1048576L || delta>=1048576L then raise(Error "A64 ADRP exceeds +/-4GiB");
          let immediate=Int64.to_int(Int64.logand delta 0x1fffffL) in
          set at (0x90000000 lor ((immediate land 3) lsl 29) lor ((immediate lsr 2) lsl 5) lor rd);
          let low=Int64.to_int(Int64.logand value 4095L) in
          set (at+4)(0x91000000 lor (low lsl 10) lor (rd lsl 5) lor rd);
          set (at+8) 0xd503201f;set (at+12) 0xd503201f
        end else begin
          let encoded=create() in imm encoded rd value;
          Bytes.blit_string (Buffer.contents encoded.code) 0 code at 16
        end)m.fixups;
  code
