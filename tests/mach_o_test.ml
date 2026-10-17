(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
module S = Xen_darwin.Sha256
module M = Xen_darwin.Mach_o
let expect condition message = if not condition then failwith message
let hex text=String.concat ""(List.init(String.length text)(fun i->Printf.sprintf "%02x"(Char.code text.[i])))
let () =
  List.iter(fun(text,wanted)->expect(hex(S.digest text)=wanted)"SHA-256 known answer mismatch") [
    "","e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    "abc","ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1";
    String.make 1000000 'a',"cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"];
  expect(S.digest_substring "prefixabc_suffix" 6 3=S.digest "abc")"SHA-256 slice mismatch";
  List.iter(fun(offset,length)->
    expect(try ignore(S.digest_substring "abc" offset length);false with Invalid_argument _->true)
      "invalid hash slice accepted")[-1,1;0,-1;2,2;4,0];
  let rejected ?(code_size=4) ?(entry=0) ?(encoded_size=4) () =
    try ignore(M.executable ~imports:[] ~architecture:Target.Aarch64 ~entry ~code_size ~rodata:"" ~data:""
      ~encode:(fun ~code_address:_ ~rodata_address:_ ~data_address:_->Bytes.make encoded_size '\000'));false
    with M.Error _->true in
  expect(rejected ~code_size:0 ())"empty Mach-O code accepted";
  expect(rejected ~entry:4 ())"out-of-code Mach-O entry accepted";
  expect(rejected ~entry:2 ())"unaligned Mach-O ARM entry accepted";
  expect(rejected ~code_size:3 ())"unaligned Mach-O ARM code accepted";
  expect(rejected ~encoded_size:8 ())"changed encoded Mach-O size accepted";
  print_endline "Mach-O input validation and SHA-256 known answers passed"
