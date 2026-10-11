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

let build (module B : Backend_intf.S) opt report jit jit_report source output =
  match B.generate ~jit ~jit_report (optimize opt report (compile source)) with
  | Error error ->
      let prefix = match error.span with None -> "" | Some span -> location span ^ ": " in
      fail (prefix ^ "native backend error: " ^ error.message)
  | Ok executable -> parent_directory output; B.write output executable

let run backend opt report jit jit_report source arguments =
  let temporary = Filename.temp_file "xen-run-" ".exe" in
  Fun.protect ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ()) (fun () ->
    build backend opt report jit jit_report source temporary;
    let argv = Array.of_list (temporary :: arguments) in
    let pid = try Unix.create_process temporary argv Unix.stdin Unix.stdout Unix.stderr with
      | Unix.Unix_error (error, _, _) ->
          let module B = (val backend : Backend_intf.S) in
          fail ("cannot execute target '" ^ Target.to_string B.description.target ^
            "' on this host: " ^ Unix.error_message error) in
    match snd (Unix.waitpid [] pid) with
    | Unix.WEXITED status -> exit status
    | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
        Printf.eprintf "program terminated by signal %d\n" signal; exit (128 + signal))

let usage () =
  prerr_endline "Usage:\n  xen version | --version\n  xen check <file.xen>\n  xen build <file.xen> [-o output] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]\n  xen run <file.xen> [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report] [-- program-args...]\n  xen test [file.xen | directory | std.module] [--filter substring] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--jit=on|off] [--jit-report]";
  exit 2

(* Compiler options may occur before or after the source/target. The run
   delimiter preserves all following tokens as literal program arguments. *)
type options = {
  opt : Semantic_opt.level;
  report : bool;
  jit : bool;
  jit_report : bool;
  source : string option;
  output : string;
  filter : string;
  args : string list;
  target : string;
}

let parse_options command arguments =
  let rec loop options = function
    | [] -> options
    | "--opt=off" :: rest -> loop {options with opt=Semantic_opt.Off} rest
    | "--opt=basic" :: rest -> loop {options with opt=Semantic_opt.Basic} rest
    | "--opt-report" :: rest -> loop {options with report=true} rest
    | "--jit=on" :: rest -> loop {options with jit=true} rest
    | "--jit=off" :: rest -> loop {options with jit=false} rest
    | "--jit-report" :: rest -> loop {options with jit_report=true} rest
    | "--target" :: value :: rest when value<>"" && not(String.starts_with ~prefix:"-" value) ->
        loop {options with target=value} rest
    | value :: rest when String.starts_with ~prefix:"--target=" value ->
        let target=String.sub value 9 (String.length value-9) in
        if target="" then usage();
        loop {options with target} rest
    | "-o" :: path :: rest when command="build" -> loop {options with output=path} rest
    | "--filter" :: value :: rest when command="test" -> loop {options with filter=value} rest
    | "--" :: args when command="run" -> {options with args}
    | value :: rest when not(String.starts_with ~prefix:"-" value) && options.source=None ->
        loop {options with source=Some value} rest
    | _ -> usage() in
  let options=loop {opt=Semantic_opt.Off;report=false;jit=true;jit_report=false;
    source=None;output="a.out";filter="";args=[];target=Target.to_string Target.default} arguments in
  if (options.report && options.opt<>Semantic_opt.Basic) ||
     (options.jit_report && not options.jit) then usage();
  options

let select_backend target = match Backend.of_string target with
  | Ok backend -> backend
  | Error message -> fail ("target error: " ^ message)

let () =
  match Array.to_list Sys.argv with
  | [_; ("version" | "--version")] -> Printf.printf "xen %s\n" Build_version.current
  | [_; "check"; source] -> ignore (compile source)
  | _ :: ("build"|"run" as command) :: options ->
      let o=parse_options command options in
      let source=match o.source with Some source->source|None->usage() in
      let backend=select_backend o.target in
      if command="build" then build backend o.opt o.report o.jit o.jit_report source o.output
      else run backend o.opt o.report o.jit o.jit_report source o.args
  | _ :: "test" :: options ->
      let o=parse_options "test" options in
      let backend=select_backend o.target in
      let target=Option.value ~default:"." o.source in
      let cases,errors=Test_runner.discover ~target ~filter:o.filter in
      List.iter print_diagnostic errors;
      let failed=ref(List.length errors)and passed=ref 0 in
      List.iter(fun(case:Test_runner.case)->
        match Test_runner.run ~backend ~opt:o.opt ~opt_report:o.report ~jit:o.jit ~jit_report:o.jit_report case with
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
