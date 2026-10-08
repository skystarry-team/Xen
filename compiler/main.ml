(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

let location span = Printf.sprintf "%s:%d:%d" span.file span.line span.column
let fail message = prerr_endline message; exit 1

let print_diagnostic (diagnostic:Checker.diagnostic) =
  prerr_endline (location diagnostic.span ^ ": error: " ^ diagnostic.message);
  List.iter (fun (span, message) ->
    prerr_endline (location span ^ ": note: " ^ message)) diagnostic.notes;
  Option.iter (fun help -> prerr_endline ("help: " ^ help)) diagnostic.help

let compile path =
  let programs = try Project_loader.load path with
    | Sys_error message -> fail (path ^ ": " ^ message)
    | Lexer.Error (span, message) | Parser.Error (span, message) ->
        fail (location span ^ ": syntax error: " ^ message)
    | Project_loader.Error(span,message)->fail(location span^": error: "^message)
  in
  let checked = match programs with
    | [ast] when ast.Ast.imports=[] -> Checker.check ast
    | entry::_ -> let name=match entry.Ast.module_decl with Some(n,_)->n|None->"$entry" in
        Checker.check_project ~entry_module:name programs
    | []->assert false in
  match checked with
  | Error diagnostic ->
      print_diagnostic diagnostic;
      exit 1
  | Ok program -> program

let parent_directory path =
  let directory = Filename.dirname path in
  let rec create current =
    if current <> "." && current <> "/" && not (Sys.file_exists current) then
      (create (Filename.dirname current); Unix.mkdir current 0o755)
  in create directory

let optimize opt report checked =
  try Semantic_opt.apply ~report opt checked with
  | Semantic_ir.Invalid(span,message)->fail(location span ^ ": optimization error: " ^ message)
  | Semantic_analysis.Diagnostic(span,message,notes)->
      print_diagnostic {span;message="optimization error: "^message;notes;help=None};exit 1

let build opt report jit jit_report source output =
  match Native_backend.generate ~jit ~jit_report (optimize opt report (compile source)) with
  | Error error ->
      let prefix = match error.span with None -> "" | Some span -> location span ^ ": " in
      fail (prefix ^ "native backend error: " ^ error.message)
  | Ok executable -> parent_directory output; Native_backend.write output executable

let run opt report jit jit_report source arguments =
  let temporary = Filename.temp_file "xen-run-" ".elf" in
  Fun.protect ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ()) (fun () ->
    build opt report jit jit_report source temporary;
    let argv = Array.of_list (temporary :: arguments) in
    let pid = Unix.create_process temporary argv Unix.stdin Unix.stdout Unix.stderr in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED status -> exit status
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
        Printf.eprintf "program terminated by signal %d\n" signal; exit (128 + signal))

let usage () =
  prerr_endline "Usage:\n  xen version | --version\n  xen check <file.xen>\n  xen build <file.xen> [-o output] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]\n  xen run <file.xen> [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report] [-- program-args...]\n  xen test [file.xen | directory | std.module] [--filter substring] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]";
  exit 2

(* Compiler options may occur before or after the source/target. The run
   delimiter preserves all following tokens as literal program arguments. *)
let parse_options command options =
  let rec loop opt report jit jit_report target output filter args = function
    |[]->opt,report,jit,jit_report,target,output,filter,args
    |"--opt=off"::rest->loop Semantic_opt.Off report jit jit_report target output filter args rest
    |"--opt=basic"::rest->loop Semantic_opt.Basic report jit jit_report target output filter args rest
    |"--opt-report"::rest->loop opt true jit jit_report target output filter args rest
    |"--jit=on"::rest->loop opt report true jit_report target output filter args rest
    |"--jit=off"::rest->loop opt report false jit_report target output filter args rest
    |"--jit-report"::rest->loop opt report jit true target output filter args rest
    |"-o"::path::rest when command="build"->loop opt report jit jit_report target path filter args rest
    |"--filter"::value::rest when command="test"->loop opt report jit jit_report target output value args rest
    |"--"::arguments when command="run"->opt,report,jit,jit_report,target,output,filter,arguments
    |value::rest when not(String.starts_with ~prefix:"-" value) && target=None->
        loop opt report jit jit_report (Some value) output filter args rest
    |_->usage() in
  let opt,report,jit,jit_report,target,output,filter,args=loop Semantic_opt.Off false true false None "a.out" "" [] options in
  if (report && opt<>Semantic_opt.Basic) || (jit_report && not jit) then usage();
  opt,report,jit,jit_report,target,output,filter,args

let () =
  match Array.to_list Sys.argv with
  | [_; ("version" | "--version")] -> Printf.printf "xen %s\n" Build_version.current
  | [_; "check"; source] -> ignore (compile source)
  | _ :: ("build"|"run" as command) :: options ->
      let opt,report,jit,jit_report,target,output,_,args=parse_options command options in
      let source=match target with Some source->source|None->usage() in
      if command="build"then build opt report jit jit_report source output else run opt report jit jit_report source args
  | _ :: "test" :: options ->
      let opt,report,jit,jit_report,target,_,filter,_=parse_options "test" options in
      let target=Option.value ~default:"." target in
      let cases,errors=Test_runner.discover ~target ~filter in
      List.iter print_diagnostic errors;
      let failed=ref(List.length errors)and passed=ref 0 in
      List.iter(fun(case:Test_runner.case)->
        match Test_runner.run ~opt ~opt_report:report ~jit ~jit_report case with
        |Test_runner.Passed->incr passed;Printf.printf "PASS %s\n%!" case.name
        |Test_runner.Compilation_error d->incr failed;Printf.printf "FAIL %s (compilation)\n%!" case.name;
            print_diagnostic d
        |Test_runner.Failed(status,stdout,stderr)->incr failed;
            let reason=match status with Unix.WEXITED n->"exit "^string_of_int n
              |Unix.WSIGNALED n|Unix.WSTOPPED n->"signal "^string_of_int n in
            Printf.printf "FAIL %s (%s)\n%s%!"case.name reason stdout;
            prerr_endline(location case.span^": error: test '"^case.name^"' failed ("^reason^")");
            prerr_string stderr)cases;
      if cases=[] && errors=[]then(prerr_endline "no tests matched";exit 1);
      Printf.printf "%d passed; %d failed\n" !passed !failed;
      exit(if !failed=0 then 0 else 1)
  | _ -> usage ()
