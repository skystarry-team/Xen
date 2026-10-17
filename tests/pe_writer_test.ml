(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
module P = Xen_windows.Pe_writer
let expect condition message=if not condition then failwith message
let rejected f=try ignore(f());false with P.Error _->true
let emit ?(entry=0) ?(code_size=1) ?(rodata="") ?(data="") ?(bss_size=0)
    ?(imports=[]) ?(pointers=[]) ?(functions=[]) ?encode () =
  let encode=Option.value ~default:(fun ~code_address:_ ~rodata_address:_ ~data_address:_
    ~import_address:_->Bytes.make code_size '\195')encode in
  P.executable ~entry ~code_size ~rodata ~data ~bss_size ~imports ~pointers ~functions ~encode ()
let () =
  List.iter(fun f->expect(rejected f)"invalid PE input accepted")[
    (fun()->emit ~code_size:0 ());(fun()->emit ~entry:(-1)());(fun()->emit ~entry:1());
    (fun()->emit ~bss_size:(-1)());(fun()->emit ~bss_size:0x7fffffff ());
    (fun()->emit ~code_size:0x7fffffff ());
    (fun()->emit ~imports:["","foo"]());(fun()->emit ~imports:["x.dll","bad\000name"]());
    (fun()->emit ~encode:(fun ~code_address:_ ~rodata_address:_ ~data_address:_ ~import_address:_->Bytes.empty)());
    (fun()->emit ~data:(String.make 8 '\000') ~pointers:[
      {at={section=Data;offset=1};target={section=Code;offset=0}}]());
    (fun()->emit ~data:(String.make 8 '\000') ~pointers:[
      {at={section=Data;offset=0};target={section=Rodata;offset=0}}]());
    (fun()->emit ~data:(String.make 16 '\000') ~pointers:List.(init 2(fun _->
      {P.at={section=Data;offset=0};target={section=Code;offset=0}}))())];
  let bad_function ?(begin_offset=0) ?(end_offset=8) ?(prolog_size=4) codes =
    emit ~code_size:8 ~functions:[{begin_offset;end_offset;prolog_size;codes}]()in
  List.iter(fun f->expect(rejected f)"invalid PE unwind accepted")[
    (fun()->bad_function ~end_offset:9 []);(fun()->bad_function ~prolog_size:9 []);
    (fun()->bad_function [{code_offset=0;operation=Alloc_stack 8}]);
    (fun()->bad_function [{code_offset=5;operation=Alloc_stack 8}]);
    (fun()->bad_function [{code_offset=1;operation=Alloc_stack 7}]);
    (fun()->bad_function [{code_offset=1;operation=Push_nonvol 0}]);
    (fun()->bad_function [{code_offset=1;operation=Set_frame(5,0)}]);
    (fun()->bad_function [{code_offset=1;operation=Push_nonvol 5};
                          {code_offset=1;operation=Alloc_stack 32}])];
  (* Distinct DLLs may export the same symbol; library casing is insignificant. *)
  let checked=ref false in
  ignore(emit ~imports:["A.dll","same";"a.DLL","same";"B.dll","same"]
    ~encode:(fun ~code_address:_ ~rodata_address:_ ~data_address:_ ~import_address->
      let a=import_address ~library:"a.dll" ~symbol:"same" in
      expect(a=import_address ~library:"A.DLL" ~symbol:"same")"DLL casing changed IAT slot";
      expect(a<>import_address ~library:"B.dll" ~symbol:"same")"different DLL imports collapsed";
      checked:=true;Bytes.of_string "\195")());
  expect !checked "encoder was not called";
  List.iter(fun size->ignore(emit ~code_size:8 ~functions:[{
    begin_offset=0;end_offset=8;prolog_size=4;codes=[{code_offset=4;operation=Alloc_stack size}]}]()))
    [8;128;136;524280;524288];
  print_endline "PE input validation, DLL identity and unwind encodings passed"
