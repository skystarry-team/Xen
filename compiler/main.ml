(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

let location span = Printf.sprintf "%s:%d:%d" span.file span.line span.column
let fail message = prerr_endline message; exit 1

let print_diagnostic (diagnostic:Checker.diagnostic) =
  prerr_endline (location diagnostic.span ^ ": error: " ^ diagnostic.message);
  List.iter (fun (span, message) ->
    prerr_endline (location span ^ ": note: " ^ message)) diagnostic.notes;
  Option.iter (fun help -> prerr_endline ("help: " ^ help)) diagnostic.help

let compile ~target path =
  let programs = try Project_loader.load ~target path with
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

let optimize ?cache opt report checked =
  try Semantic_opt.apply ?cache ~report opt checked with
  | Semantic_ir.Invalid(span,message)->fail(location span ^ ": optimization error: " ^ message)
  | Semantic_analysis.Diagnostic(span,message,notes)->
      print_diagnostic {span;message="optimization error: "^message;notes;help=None};exit 1

let build ?cache (module B : Backend_intf.S) opt report source output =
  match B.generate (optimize ?cache opt report (compile ~target:B.description.target source)) with
  | Error error ->
      let prefix = match error.span with None -> "" | Some span -> location span ^ ": " in
      fail (prefix ^ "native backend error: " ^ error.message)
  | Ok executable -> parent_directory output; B.write output executable

let run ?cache backend opt report source arguments =
  let temporary = Filename.temp_file "xen-run-" ".exe" in
  Fun.protect ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ()) (fun () ->
    build ?cache backend opt report source temporary;
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
  prerr_endline "Usage:\n  xen version | --version\n  xen check <file.xen> [--target=<architecture>-<os>]\n  xen build <file.xen> [-o output] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--opt-cache=<directory>]\n  xen run <file.xen> [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--opt-cache=<directory>] [-- program-args...]\n  xen test [file.xen | directory | std.module] [--filter substring] [--target=<architecture>-<os>] [--opt=off|basic] [--opt-report] [--opt-cache=<directory>]";
  exit 2

(* Compiler options may occur before or after the source/target. The run
   delimiter preserves all following tokens as literal program arguments. *)
type options = {
  opt : Semantic_opt.level;
  report : bool;
  source : string option;
  output : string;
  filter : string;
  args : string list;
  target : string option;
  cache_directory : string option;
}

let parse_options command arguments =
  let rec loop options = function
    | [] -> options
    | flag :: _ when command="check" &&
        String.starts_with ~prefix:"--opt" flag -> usage()
    | "--opt=off" :: rest -> loop {options with opt=Semantic_opt.Off} rest
    | "--opt=basic" :: rest -> loop {options with opt=Semantic_opt.Basic} rest
    | "--opt-report" :: rest -> loop {options with report=true} rest
    | "--opt-cache" :: value :: rest when value<>"" && not(String.starts_with ~prefix:"-" value)->
        loop {options with cache_directory=Some value} rest
    | value :: rest when String.starts_with ~prefix:"--opt-cache=" value->
        let directory=String.sub value 12(String.length value-12)in
        if directory=""then usage();loop {options with cache_directory=Some directory} rest
    | "--target" :: value :: rest when value<>"" && not(String.starts_with ~prefix:"-" value) ->
        loop {options with target=Some value} rest
    | value :: rest when String.starts_with ~prefix:"--target=" value ->
        let target=String.sub value 9 (String.length value-9) in
        if target="" then usage();
        loop {options with target=Some target} rest
    | "-o" :: path :: rest when command="build" -> loop {options with output=path} rest
    | "--filter" :: value :: rest when command="test" -> loop {options with filter=value} rest
    | "--" :: args when command="run" -> {options with args}
    | value :: rest when not(String.starts_with ~prefix:"-" value) && options.source=None ->
        loop {options with source=Some value} rest
    | _ -> usage() in
  let options=loop {opt=Semantic_opt.Basic;report=false;
    source=None;output="a.out";filter="";args=[];target=None;cache_directory=None} arguments in
  if (options.report || options.cache_directory<>None) && options.opt<>Semantic_opt.Basic then usage();
  options

let select_backend target =
  let target=match target with Some name->name|None->
    match Backend.default_target () with Ok t->Target.to_string t|Error message->fail message in
  match Backend.of_string target with
  | Ok backend -> backend
  | Error message -> fail ("target error: " ^ message)

let prefix_cache directory (module B:Backend_intf.S) = Option.map(fun directory->
  Semantic_prefix_cache.create ~directory
    ~identity:(Semantic_prefix_cache.compiler_identity()^":"^Target.to_string B.description.target)())directory

let () =
  match Array.to_list Sys.argv with
  | [_; ("version" | "--version")] -> Printf.printf "xen %s\n" Build_version.current
  | _ :: "check" :: options ->
      let o=parse_options "check" options in
      let source=match o.source with Some source->source|None->usage() in
      let module B = (val select_backend o.target : Backend_intf.S) in
      ignore (compile ~target:B.description.target source)
  | _ :: ("build"|"run" as command) :: options ->
      let o=parse_options command options in
      let source=match o.source with Some source->source|None->usage() in
      let backend=select_backend o.target in
      let cache=prefix_cache o.cache_directory backend in
      if command="build" then build ?cache backend o.opt o.report source o.output
      else run ?cache backend o.opt o.report source o.args
  | _ :: "test" :: options ->
      let o=parse_options "test" options in
      let backend=select_backend o.target in
      let opt_cache=prefix_cache o.cache_directory backend in
      let target=Option.value ~default:"." o.source in
      let module B = (val backend : Backend_intf.S) in
      let cases,errors=Test_runner.discover ~code_target:B.description.target ~target ~filter:o.filter in
      List.iter print_diagnostic errors;
      let failed=ref(List.length errors)and passed=ref 0 in
      List.iter(fun(case:Test_runner.case)->
        match Test_runner.run ~backend ~opt:o.opt ~opt_report:o.report ?opt_cache case with
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
