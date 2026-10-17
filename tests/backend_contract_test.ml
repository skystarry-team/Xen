(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
let expect condition message = if not condition then failwith message

module Probe : Backend_intf.S = struct
  let description : Backend_intf.description = {
    target = {architecture=Target.Aarch64; operating_system=Target.Linux};
    calling_convention="test only"; runtime="none"; executable_format="none";
  }
  type executable = unit
  let generate checked =
    Semantic_ir.verify (Semantic_ir.program checked);
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
    ["x86_64-windows"; "aarch64-windows"; "x86_64-macos"; "aarch64-macos"];
  List.iter (fun name -> expect (Result.is_ok (Backend.of_string name))
    ("missing ARM64 backend: " ^ name)) ["aarch64-linux"; "arm64-linux"];
  let module Default = (val Backend.default : Backend_intf.S) in
  let expected=match Result.bind (Backend.default_target ()) Backend.select with
    |Ok backend->let module B=(val backend:Backend_intf.S)in B.description.target
    |Error _->Target.default in
  expect (Default.description.target=expected) "registry default mismatch";
  List.iter(fun name->let module B=(val Backend.library_default(Ok(parsed name)):Backend_intf.S)in
    expect(B.description.target=Target.default) "library fallback depends on registry order")
    ["aarch64-macos";"x86_64-macos"];
  List.iter(fun (architecture,expected)->
    expect (Backend.host_target ~architecture ~system:"linux"=Ok (parsed expected)) "host target mismatch")
    ["amd64","x86_64-linux";"arm64","aarch64-linux"];
  List.iter(fun system->
    expect(Backend.host_target ~architecture:"amd64" ~system=Ok windows)
      "native Windows host was not recognized") ["mingw64";"win64"];
  List.iter(fun(windows,root,path,expected)->
    expect(Project_loader.relative_entry ~windows ~root path=expected)"project root path mismatch") [
    false,"/","/app.xen",Some "app.xen";
    false,"/project","/project/lib/test.xen",Some "lib/test.xen";
    false,"/project","/project-other/app.xen",None;
    false,"/Project","/project/app.xen",None;
    true,"C:\\","c:\\공백 경로\\app.xen",Some "공백 경로/app.xen";
    true,"C:\\Project","c:/project/lib/app.xen",Some "lib/app.xen";
    true,"C:\\Project","C:\\Project-other\\app.xen",None;
    true,"C:\\Project","D:\\Project\\app.xen",None;
    true,"\\\\server\\share\\","\\\\SERVER\\share\\lib\\app.xen",Some "lib/app.xen"];
  expect (Result.is_error(Backend.host_target ~architecture:"other" ~system:"linux")) "unknown host accepted";
  List.iter(fun(architecture,expected)->
    expect(Backend.host_target ~architecture ~system:"macosx"=Ok(parsed expected)) "macOS host target mismatch")
    ["amd64","x86_64-macos";"arm64","aarch64-macos"];
  expect(parsed "arm64-darwin"=parsed "aarch64-macos") "Darwin alias mismatch";
  let program=Parser.parse ~file:"probe.xen" "fn main(){}" in
  let case : Test_runner.case = {
    name="probe";function_name="main";owner="$entry";single=true;
    programs=[program];span={file="probe.xen";line=1;column=1};code_target=parsed "aarch64-linux";
  } in
  (  match Test_runner.run ~backend:(module Probe) case with
   | Test_runner.Compilation_error error ->
       expect (error.message="native backend error: probe backend reached")
         "runner did not use the injected backend"
   | _ -> failwith "probe backend error was lost");
  let mismatched={case with code_target=parsed "x86_64-linux"} in
  (match Test_runner.run ~backend:(module Probe) mismatched with
   |Test_runner.Compilation_error d->expect(String.starts_with ~prefix:"test discovered for" d.message)
       "discovery/backend mismatch was not rejected"
   |_->failwith "mismatched target test ran");
  print_endline "Backend target selection and driver contract passed"
