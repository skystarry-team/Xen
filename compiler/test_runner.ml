(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

type case = { name:string; function_name:string; owner:string; single:bool;
              programs:Ast.program list; span:span; code_target:Target.t }
type outcome = Passed | Compilation_error of Checker.diagnostic
             | Failed of Unix.process_status * string * string

let diagnostic span message : Checker.diagnostic = {span;message;notes=[];help=None}
let protect file f = try Ok(f())with
  |Lexer.Error(span,message)|Parser.Error(span,message)|Project_loader.Error(span,message)->
      Error(diagnostic span message)
  |Sys_error message->Error(diagnostic {file;line=1;column=1} message)
  |Unix.Unix_error(error,operation,path)->Error(diagnostic {file;line=1;column=1}
      (operation^" "^path^": "^Unix.error_message error))

let files directory =
  let rec walk path =
    Sys.readdir path |> Array.to_list |> List.sort String.compare |> List.concat_map(fun name->
      let child=Filename.concat path name in
      match (Unix.lstat child).Unix.st_kind with
      |Unix.S_DIR when not(String.starts_with ~prefix:"." name) &&
          not(List.mem name ["_build";"dist";"stdlib"])->walk child
      |Unix.S_REG when Filename.check_suffix name ".xen"->[child]
      |_->[])in
  walk directory

let discover ~code_target ~target ~filter =
  let seen=Hashtbl.create 16 and cases=ref [] and errors=ref []in
  let add ~toolchain ~fallback programs =
    let single=match programs with [p] when p.imports=[]->true|_->false in
    List.iter(fun(p:Ast.program)->let owner=match p.module_decl with Some(n,_)->n|None->"$entry"in
      let selected=match toolchain with Some name->owner=name|None->
        Project_loader.namespace owner=Project_loader.Project_root in
      if selected then List.iter(fun(f:Ast.func)->if f.is_test then begin
        let name=(if owner="$entry"then fallback else owner)^"."^f.name in
        let matches=let n=String.length filter in
          let rec loop i=i+n<=String.length name &&
            (String.sub name i n=filter || loop(i+1))in loop 0 in
        let key=f.span.file,f.name in
        if matches && not(Hashtbl.mem seen key)then begin
          Hashtbl.add seen key();cases:={name;function_name=f.name;owner;single;programs;span=f.span;code_target}::!cases
        end
      end)p.functions)programs in
  let load file loader=match protect file loader with
    |Ok programs->add ~toolchain:None ~fallback:(Filename.basename file |> Filename.remove_extension) programs
    |Error d->errors:=d::!errors in
  let root=if Sys.file_exists target then Project_loader.Project_root else Project_loader.namespace target in
  (match root with
   |Project_loader.Std_root|Project_loader.Core_root->
       (match protect target(fun()->Project_loader.load_toolchain ~target:code_target target)with
        |Ok programs->add ~toolchain:(Some target) ~fallback:target programs
        |Error d->errors:=d::!errors)
   |Project_loader.Project_root->
       if Sys.file_exists target && Sys.is_directory target then
         (match protect target(fun()->files target)with
          |Error d->errors:=d::!errors
          |Ok paths->List.iter(fun file->load file(fun()->Project_loader.load ~target:code_target ~root:target file))paths)
       else load target(fun()->Project_loader.load ~target:code_target target));
  List.sort(fun a b->String.compare a.name b.name)!cases,List.rev !errors

let execute ?target ~write executable =
  let binary=Filename.temp_file "xen-test-" ".exe"
  and stdout_path=Filename.temp_file "xen-test-" ".stdout"
  and stderr_path=Filename.temp_file "xen-test-" ".stderr"in
  Fun.protect ~finally:(fun()->List.iter(fun path->try Sys.remove path with Sys_error _->())
      [binary;stdout_path;stderr_path])(fun()->
    write binary executable;
    let with_fd path flags f=let fd=Unix.openfile path flags 0o600 in
      Fun.protect ~finally:(fun()->Unix.close fd)(fun()->f fd)in
    let pid=with_fd stdout_path [Unix.O_WRONLY;Unix.O_TRUNC](fun output->
      with_fd stderr_path [Unix.O_WRONLY;Unix.O_TRUNC](fun errors->
      with_fd (if Sys.win32 then "NUL" else "/dev/null") [Unix.O_RDONLY](fun input->
      try Unix.create_process binary[|binary|]input output errors with
      |Unix.Unix_error(error,operation,path)->
          match target with
          |None->raise(Unix.Unix_error(error,operation,path))
          |Some target->raise(Sys_error("cannot execute target '"^Target.to_string target^
              "' on this host: "^Unix.error_message error)))))in
    let status=snd(Unix.waitpid[]pid)in
    status,Project_loader.read_file stdout_path,Project_loader.read_file stderr_path)

let run ?(backend=Backend.default) ?(opt=Semantic_opt.Basic) ?(opt_report=false) ?opt_cache case =
  let module B = (val backend : Backend_intf.S) in
  if case.code_target<>B.description.target then Compilation_error(diagnostic case.span
    ("test discovered for "^Target.to_string case.code_target^" cannot run with backend "^
     Target.to_string B.description.target)) else
  let checked=if case.single then Checker.check ~entry:case.function_name(List.hd case.programs)
    else Checker.check_project ~entry_module:case.owner ~entry_function:case.function_name case.programs in
  match checked with
  |Error d->Compilation_error d
  |Ok checked->
    let optimized=try Ok(Semantic_opt.apply ?cache:opt_cache ~report:opt_report opt checked)with
      |Semantic_ir.Invalid(span,message)->Error(diagnostic span ("optimization error: "^message))
      |Semantic_analysis.Diagnostic(span,message,notes)->Error({span;message="optimization error: "^message;notes;help=None}:Checker.diagnostic)in
    match optimized with Error d->Compilation_error d|Ok checked->
    match B.generate checked with
    |Error error->Compilation_error(diagnostic(Option.value ~default:case.span error.span)
        ("native backend error: "^error.message))
    |Ok executable->match protect case.span.file(fun()->execute ~target:B.description.target ~write:B.write executable)with
      |Error d->Compilation_error d
      |Ok(Unix.WEXITED 0,_,stderr)->ignore stderr;Passed
      |Ok(status,stdout,stderr)->Failed(status,stdout,stderr)
