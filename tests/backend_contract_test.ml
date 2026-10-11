(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
let expect condition message = if not condition then failwith message

module Probe : Backend_intf.S = struct
  let description : Backend_intf.description = {
    target = {architecture=Target.Aarch64; operating_system=Target.Linux};
    calling_convention="test only"; runtime="none"; executable_format="none";
  }
  type executable = unit
  let generate ?(jit=true) ?(jit_report=false) checked =
    Semantic_ir.verify (Semantic_ir.program checked);
    expect (not jit && not jit_report) "runner lost backend options";
    Error ({span=None; message="probe backend reached"} : Backend_intf.error)
  let write _ () = failwith "error result must not be written"
end

let () =
  let parsed name = match Target.parse name with
    | Ok target -> target | Error message -> failwith message in
  expect (parsed "x86_64-linux" = Target.default) "legacy default changed";
  expect (parsed "arm64-linux" = parsed "aarch64-linux") "ARM64 alias mismatch";
  let windows=parsed "x86_64-windows" in
  expect (windows.architecture=Target.X86_64 && windows.operating_system=Target.Windows)
    "CPU and OS must be independent";
  List.iter (fun name -> expect (Result.is_error (Target.parse name))
    ("accepted malformed/unknown target: " ^ name))
    [""; "x86_64"; "x86_64-linux-extra"; "mystery-linux"; "x86_64-mystery"];
  List.iter (fun name -> expect (Result.is_error (Backend.of_string name))
    ("selected unimplemented target: " ^ name))
    ["x86_64-windows"; "aarch64-windows"];
  List.iter (fun name -> expect (Result.is_ok (Backend.of_string name))
    ("missing ARM64 backend: " ^ name)) ["aarch64-linux"; "arm64-linux"];
  let module Default = (val Backend.default : Backend_intf.S) in
  expect (Default.description.target=Target.default) "registry default mismatch";
  let program=Parser.parse ~file:"probe.xen" "fn main(){}" in
  let case : Test_runner.case = {
    name="probe";function_name="main";owner="$entry";single=true;
    programs=[program];span={file="probe.xen";line=1;column=1};
  } in
  (match Test_runner.run ~backend:(module Probe) ~jit:false case with
   | Test_runner.Compilation_error error ->
       expect (error.message="native backend error: probe backend reached")
         "runner did not use the injected backend"
   | _ -> failwith "probe backend error was lost");
  print_endline "Backend target selection and driver contract passed"
