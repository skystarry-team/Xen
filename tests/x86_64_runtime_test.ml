(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* This test links only CPU/common code. The deliberately non-executable probe
   supplies variable-length services and an encoder, with no Linux or ELF. *)
module M = Xen_x86_64.Machine_ir
let expect condition message = if not condition then failwith message
module Probe = struct
  let events = ref []
  let machine = ref None
  let service name output =
    events := (name, M.position output) :: !events;
    M.bytes output [0x0f;0x1f;0x40;0x00]
  let open_read_flags = 123
  let open_write_flags = 456
  let alloc = service "alloc"
  let unmap = service "unmap"
  let read = service "read"
  let write = service "write"
  let close = service "close"
  let open_ = service "open"
  let exit output status = service ("exit:" ^ string_of_int status) output
  let raw_syscall output ~arity = service ("raw:" ^ string_of_int arity) output
  let entry output =
    M.bytes output [0x90;0x90;0x90];M.label output "_start"
  let start output = entry output;service "start" output
  let foreign_start output ~main =
    entry output;service "foreign_start" output;M.branch output [0xe8] main;Ok ()
  let executable ~entry output =
    expect (entry=3) "CPU presumed the platform entry was at offset zero";
    machine := Some output;
    M.encode ~code_address:0x410000L ~rodata_address:0x420000L ~data_address:0x430000L output
end
module Codegen = Xen_x86_64.Native_backend.Make(Probe)
let checked source =
  match Checker.check (Parser.parse ~file:"runtime-probe.xen" source) with
  |Ok program->program
  |Error diagnostic->failwith diagnostic.message
let generate source =
  Probe.events:=[];
  match Codegen.generate (checked source) with
  |Ok bytes->bytes
  |Error error->failwith error.message
let emitted name = List.exists (fun (event,_)->event=name) !(Probe.events)
let in_function name =
  let machine=Option.get !(Probe.machine) in
  let entry=Hashtbl.find machine.M.labels "fn_main" in
  List.exists (fun (event,position)->event=name && position>=entry) !(Probe.events)
let () =
  let simple="fn main(){println(42);}" in
  let first=generate simple in
  expect (emitted "start" && not(emitted "foreign_start")) "static entry bypassed Runtime";
  ignore(generate "#global[bb]\nfn main(){let p=raw_alloc<Int>(1);raw_free(p);syscall6(9,0,1,2,3,4,5);println(\"ok\");}");
  List.iter(fun name->expect(in_function name)("lowering bypassed service "^name))
    ["alloc";"unmap";"raw:7";"write"];
  ignore(generate "fn main(){let mut f=open_write(\"probe\");f.write(\"text\");print(f.read());f.close();}");
  expect (in_function "close") "File cleanup bypassed Runtime";
  List.iter(fun name->expect(emitted name)("runtime helper bypassed service "^name))
    ["open";"read";"write";"close";"alloc";"unmap"];
  let cpu_routines=["__xen_print_float";"__xen_read_builtin";
    "__xen_numeric_whitespace";"__xen_numeric_parse_int";"__xen_numeric_parse_float"] in
  List.iter(fun label->expect(Hashtbl.mem (Option.get !(Probe.machine)).M.labels label)
    ("missing CPU runtime "^label))cpu_routines;
  let module Long_services = struct
    include Probe
    let pad output = for _=1 to 257 do M.u8 output 0x90 done
    let alloc output = pad output;Probe.alloc output;pad output
    let unmap output = pad output;Probe.unmap output
    let open_ output = pad output;Probe.open_ output;pad output
    let read output = pad output;Probe.read output
    let write output = pad output;Probe.write output
    let close output = pad output;Probe.close output
  end in
  let module Long_codegen = Xen_x86_64.Native_backend.Make(Long_services) in
  (match Long_codegen.generate(checked "fn main(){println(read_floats(\"probe\"));}") with
  |Ok _->()
  |Error error->failwith("runtime relocation depends on service length: "^error.message));
  ignore(generate "#global[bb]\nfn main(){extern_call<Int>(\"probe-library\",\"probe_symbol\",42);}");
  expect (emitted "foreign_start" && not(emitted "start")) "C entry bypassed Runtime";
  let machine=Option.get !(Probe.machine) in
  expect (List.map(fun(library,symbol,_)->library,symbol)machine.M.imports=
    ["probe-library","probe_symbol"]) "CPU imported a platform startup library";
  expect (Hashtbl.mem machine.M.labels "__xen_c_main") "CPU omitted its C ABI main thunk";
  expect (generate simple=first) "compilation state leaked between programs";
  let module Refuse = struct
    include Probe
    let foreign_start _ ~main:_ = Error "C startup unavailable in probe runtime"
  end in
  let module Unsupported = Xen_x86_64.Native_backend.Make(Refuse) in
  (match Unsupported.generate (checked "#global[bb]\nfn main(){extern_call<Int>(\"probe\",\"foreign\");}") with
  |Error error->expect(error.message="C startup unavailable in probe runtime") "lost platform error"
  |Ok _->failwith "CPU silently supplied another platform's C startup");
  print_endline "x86-64 lowering composes without Linux libraries or services"
