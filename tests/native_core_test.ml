(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
let fail format = Printf.ksprintf (fun message -> prerr_endline message; exit 1) format
let expect condition format = if not condition then fail format
let contains haystack needle =
  let n = String.length needle in
  let rec loop i = i + n <= String.length haystack &&
    (String.sub haystack i n = needle || loop (i + 1)) in
  loop 0

let read_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let compile source =
  let ast = Parser.parse ~file:"test.xen" source in
  let checked = if ast.Ast.imports=[] then Checker.check ast else
    let root=Filename.temp_file "xen-project-test-" "" in Sys.remove root;Unix.mkdir root 0o700;
    let module_name=match ast.Ast.module_decl with Some(n,_)->n|None->"$entry" in
    let path=Filename.concat root (module_name^".xen") in
    let out=open_out_bin path in output_string out source;close_out out;
    Fun.protect ~finally:(fun()->Sys.remove path;Unix.rmdir root)(fun()->
      let programs=Project_loader.load path in
      let entry=match ast.Ast.module_decl with Some(n,_)->n|None->"$entry" in
      Checker.check_project ~entry_module:entry programs) in
  let lowered = match checked with
    | Ok lowered -> lowered
    | Error diagnostic -> fail "checker rejected test at line %d: %s\nsource: %s"
        diagnostic.span.line diagnostic.message source
  in
  let lowered=Semantic_opt.apply (if Sys.getenv_opt "XEN_TEST_OPT"=Some "basic"then Semantic_opt.Basic else Semantic_opt.Off) lowered in
  match Native_backend.generate lowered with
  | Ok executable -> executable
  | Error error -> fail "native backend rejected test: %s" error.message

let check_error source =
  let ast = Parser.parse ~file:"test.xen" source in
  let checked=if ast.Ast.imports=[] then Checker.check ast else
    let root=Filename.temp_file "xen-project-error-" "" in Sys.remove root;Unix.mkdir root 0o700;
    let module_name=match ast.Ast.module_decl with Some(n,_)->n|None->"$entry" in
    let path=Filename.concat root (module_name^".xen") in
    let out=open_out_bin path in output_string out source;close_out out;
    Fun.protect ~finally:(fun()->Sys.remove path;Unix.rmdir root)(fun()->
      let programs=Project_loader.load path in
      let entry=match ast.Ast.module_decl with Some(n,_)->n|None->"$entry" in
      Checker.check_project ~entry_module:entry programs) in
  match checked with
  | Error diagnostic -> diagnostic
  | Ok _ -> fail "checker unexpectedly accepted invalid source: %s" source

let syntax_error source =
  try ignore (Parser.parse ~file:"literal.xen" source); fail "parser unexpectedly accepted invalid source"
  with Lexer.Error (span, message) | Parser.Error (span, message) -> span, message

let execute_args source arguments =
  let executable = compile source in
  let path = Filename.temp_file "xen-native-test-" ".elf" in
  let stdout_path = Filename.temp_file "xen-native-test-" ".stdout" in
  let stderr_path = Filename.temp_file "xen-native-test-" ".stderr" in
  Fun.protect ~finally:(fun () -> Sys.remove path; Sys.remove stdout_path; Sys.remove stderr_path) (fun () ->
    Native_backend.write path executable;
    let stdout_fd = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let stderr_fd = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let pid = Unix.create_process path (Array.of_list (path :: arguments)) Unix.stdin stdout_fd stderr_fd in
    Unix.close stdout_fd; Unix.close stderr_fd;
    let status = match snd (Unix.waitpid [] pid) with Unix.WEXITED n -> n | _ -> -1 in
    status, read_file stdout_path, read_file stderr_path)

let execute source = execute_args source []

let execute_with_fd_limit ?memory_limit_kib limit source =
  let executable = compile source in
  let path = Filename.temp_file "xen-native-fd-test-" ".elf" in
  let stdout_path = Filename.temp_file "xen-native-fd-test-" ".stdout" in
  let stderr_path = Filename.temp_file "xen-native-fd-test-" ".stderr" in
  Fun.protect ~finally:(fun () -> Sys.remove path; Sys.remove stdout_path; Sys.remove stderr_path) (fun () ->
    Native_backend.write path executable;
    let stdout_fd = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let stderr_fd = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let memory=match memory_limit_kib with None->""|Some n->Printf.sprintf "ulimit -v %d; " n in
    let command = Printf.sprintf "ulimit -n %d; %sexec \"$1\"" limit memory in
    let pid = Unix.create_process "/bin/sh" [|"sh";"-c";command;"sh";path|] Unix.stdin stdout_fd stderr_fd in
    Unix.close stdout_fd; Unix.close stderr_fd;
    let status = match snd (Unix.waitpid [] pid) with Unix.WEXITED n -> n | _ -> -1 in
    status, read_file stdout_path, read_file stderr_path)

let test_fixup () =
  let output = Machine_ir.create () in
  Machine_ir.branch output [0xe9] "target";
  Machine_ir.u8 output 0x90;
  Machine_ir.label output "target";
  let encoded = Machine_ir.encode output in
  expect (Bytes.length encoded = 6) "unexpected encoded branch length";
  expect (Char.code (Bytes.get encoded 1) = 1) "rel32 fixup has the wrong displacement"

let test_backward_and_rip_fixups () =
  let output = Machine_ir.create () in
  Machine_ir.label output "back"; Machine_ir.u8 output 0x90;
  Machine_ir.branch output [0xe8] "back";
  Machine_ir.bytes output [0x48;0x8d;0x05];
  Machine_ir.rip_rel32 output Machine_ir.Rodata "constant";
  Machine_ir.add_rodata output "constant" "x";
  let encoded = Machine_ir.encode ~code_address:0x401000L ~rodata_address:0x402000L output in
  expect (Char.code (Bytes.get encoded 2) = 0xfa) "backward call displacement is wrong";
  expect (Char.code (Bytes.get encoded 9) = 0xf3) "RIP-relative constant displacement is wrong"

let test_elf () =
  let executable = compile "fn main() { println(42); }" in
  expect (Bytes.length executable > 0x1000) "ELF did not place code on a separate page";
  expect (Bytes.sub_string executable 0 4 = "\x7fELF") "ELF magic is missing";
  expect (Char.code (Bytes.get executable 4) = 2) "ELF is not 64-bit";
  expect (Char.code (Bytes.get executable 16) = 2) "ELF is not ET_EXEC";
  expect (Char.code (Bytes.get executable 18) = 0x3e) "ELF machine is not x86-64"
  ; expect (Char.code (Bytes.get executable 56) = 3) "ELF does not contain three load segments";
  expect (Char.code (Bytes.get executable 68) = 5) "text segment is not RX";
  expect (Char.code (Bytes.get executable 124) = 4) "constant segment is not read-only";
  expect (Char.code (Bytes.get executable 180) = 6) "data segment is not RW"

let test_end_to_end () =
  let source =
    "fn add(a: Int, b: Int) -> Int { return a + b; }\n" ^
    "fn main() { let mut i = 0; while i < 5 { if i != 2 { println(add(i, 10)); } i = i + 1; } println(-7); }\n"
  in
  let executable = compile source in
  let path = Filename.temp_file "xen-native-test-" ".elf" in
  let stdout_path = Filename.temp_file "xen-native-test-" ".stdout" in
  Fun.protect ~finally:(fun () -> Sys.remove path; Sys.remove stdout_path) (fun () ->
    Native_backend.write path executable;
    let stdout_fd = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let pid = Unix.create_process path [|path|] Unix.stdin stdout_fd Unix.stderr in
    Unix.close stdout_fd;
    (match snd (Unix.waitpid [] pid) with Unix.WEXITED 0 -> () | _ -> fail "native executable failed");
    expect (read_file stdout_path = "10\n11\n13\n14\n-7\n") "native stdout differs")

let test_semantic_diagnostic_notes () =
  let note d line needle=List.exists(fun(span,message)->
    span.Ast.line=line && span.file="test.xen" && contains message needle)d.Checker.notes in
  List.iter(fun count->List.iter(fun main_first->
    let main="fn main(){let a=[1];let mut v=V{s:a.as_slice()};v.bad();println(v.s.len());}\n"in
    let method_="impl V{\nfn bad(&mut self){let pad=["^
      String.concat ","(List.init count(fun _->"1"))^
      "];let own=[2];self.s=own.as_slice();}\n}\n"in
    let foreign=check_error("struct V{s:Slice<Int>}\n"^
      (if main_first then main^method_ else method_^main))in
    let line=if main_first then 4 else 3 in
    expect(contains foreign.message "escapes its owner scope" &&
      note foreign line "borrow of 'own' originates" && note foreign line "owner's scope")
      "foreign owner diagnostic crashed, named a caller local, or lost the callee scope")
    [true;false])[1;13;20];
  let shared=check_error
    "fn main(){\nlet mut data=[1];\nlet view=data.as_slice();\ndata.push(2);\nprintln(view.len());\n}"in
  expect(shared.span.line=4 && note shared 3 "borrow of 'data' originates here" &&
    note shared 5 "remain live through this use") "shared loan diagnostic omitted origin or later use";
  let parameter=check_error
    "#global[explc]\nfn bad(p:&mut Vec<Int>){\nlet s:Slice<Int>=p.as_slice();\np.push(2);\nprintln(s.len());}\nfn main(){let mut v=[1];bad(&mut v);}"in
  expect(parameter.span.line=4 && contains parameter.message "cannot mutate 'p'" &&
    note parameter 3 "borrow of 'p' originates" && note parameter 5 "remain live")
    "borrowed parameter diagnostic printed an internal placeholder instead of p";
  let joined=check_error
    "#global[explc]\nfn check(flag:Bool){\nlet mut a=1;\nlet mut b=2;\nlet r=if flag{&mut a}else{&mut b};\nlet forwarded=r;\na=3;\nprintln(*forwarded);\n}\nfn main(){check(true);}"in
  expect(joined.span.line=7 && note joined 5 "mutable borrow" && note joined 8 "remain live")
    "joined/forwarded loan diagnostic lost source locations";
  let loop=check_error
    "#global[explc]\nfn main(){let mut a=1;let mut run=true;\nwhile run{let r=&a;\na=2;\nprintln(*r);run=false;}}"in
  expect(loop.span.line=4 && note loop 3 "originates" && note loop 5 "remain live")
    "loop loan diagnostic lost reachable later use";
  let overwritten=check_error
    "struct V{old:Slice<Int>,sibling:Slice<Int>}\nfn run(flag:Bool){\nlet mut data=[1];let other=[2];\nlet mut view=V{old:data.as_slice(),sibling:other.as_slice()};\ndata.push(3);\nif flag{\nview.old=other.as_slice();\nprintln(view.sibling.len());\n}else{\nprintln(view.old.len());\n}}\nfn main(){run(true);}"in
  expect(note overwritten 10 "remain live" && not(note overwritten 8 "remain live"))
    "diagnostic witness followed an overwritten field into a sibling use";
  let overwritten_loop=check_error
    "struct V{old:Slice<Int>,sibling:Slice<Int>}\nfn run(mut_flag:Bool){\nlet mut flag=mut_flag;let mut data=[1];let other=[2];\nlet mut view=V{old:data.as_slice(),sibling:other.as_slice()};\ndata.push(3);\nwhile flag{view.old=other.as_slice();\nprintln(view.sibling.len());flag=false;\n}\nprintln(view.old.len());}\nfn main(){run(true);}"in
  expect(note overwritten_loop 9 "remain live" && not(note overwritten_loop 7 "remain live"))
    "loop witness ignored field replacement or reported a sibling use";
  let partial=check_error
    "struct P{left:File,right:File}\nfn consume(file:File){}fn consume_pair(value:P){}\nfn main(){\nlet p=P{left:open_read(\"/dev/null\"),right:open_read(\"/dev/null\")};\nconsume(p.left);\nconsume_pair(p);}"in
  expect(partial.span.line=6 && contains partial.message "p.left" &&
    contains partial.message "partial move" && note partial 5 "value moved here")
    "partial move diagnostic did not identify the failing field";
  let whole=check_error
    "struct P{left:File,right:File}\nfn consume(value:P){}\nfn main(){\nlet p=P{left:open_read(\"/dev/null\"),right:open_read(\"/dev/null\")};\nconsume(p);\nconsume(p);}"in
  expect(contains whole.message "use of moved P 'p'" && not(contains whole.message "partial move") &&
    note whole 5 "value moved here") "whole aggregate move was reported as a partial field move";
  let enum=check_error
    "enum E{Open(File),Empty}\nfn consume(value:E){}\nfn main(){let e=E.Open(open_read(\"/dev/null\"));consume(e);consume(e);}"in
  expect(contains enum.message "use of moved E 'e'" && not(contains enum.message "__payload") &&
    not(contains enum.message "__tag")) "whole enum move leaked representation fields";
  let capability=check_error "fn main(){\n#scope[explc]{\nsyscall0(39);\n}}"in
  expect(capability.span.line=3 && note capability 2 "does not provide bb" && capability.help<>None)
    "capability diagnostic omitted operation or lexical boundary";
  let call=check_error
    "#global[explc]\nstruct V{s:Slice<Int>}\nimpl V{\nfn set(&mut self,source:&Vec<Int>){self.s=source.as_slice();}\n}\nfn main(){\nlet mut data=[1];let other=[2];\nlet mut view=V{s:other.as_slice()};\nview.set(&data);\ndata.push(3);\nprintln(view.s.len());}"in
  expect(call.span.line=10 && note call 4 "originates" && note call 9 "forwarded by this call" &&
    note call 11 "remain live") "summary diagnostic omitted callee origin, forwarding call, or later use";
  let escape=check_error
    "struct V{s:Slice<Int>}\nfn main(){let a=[1];let mut view=V{s:a.as_slice()};\n{\nlet inner=[2];\nview.s=inner.as_slice();\n}\nprintln(view.s.len());}"in
  expect(note escape 5 "originates" && note escape 3 "owner's scope")
    "escape diagnostic omitted owner scope boundary"

let test_checker () =
  let ast = Parser.parse ~file:"bad.xen" "fn main() { let value = 1; value = 2; }" in
  (match Result.map Semantic_ir.program (Checker.check ast) with
   | Error diagnostic -> expect (String.length diagnostic.message > 0) "empty checker diagnostic"
   | Ok _ -> fail "checker accepted assignment to immutable local");
  let span,message=syntax_error "fn" in
  expect(span.line=1 && span.column=3 && contains message "identifier")
    "truncated function declaration did not produce a located syntax diagnostic"

let test_diagnostic_ux () =
  let numeric = check_error "fn main(){let narrow:I8=1;let wide:I16=2;let result:I8=wide;}" in
  expect (numeric.help=Some "convert explicitly with i8(...)")
    "I8/I16 mismatch did not suggest i8 conversion";
  let mixed_numeric = check_error "fn main(){let whole:Int=1;let decimal:Float=2.0;let result:Int=decimal;}" in
  expect (mixed_numeric.help=Some "convert explicitly with i64(...)")
    "Int/Float mismatch did not suggest canonical i64 conversion";
  let non_numeric = check_error "fn main(){let mut text=\"\";text=1;}" in
  expect (non_numeric.help=None) "non-numeric mismatch suggested a numeric conversion";
  let moved = check_error
    "fn consume(file:File){}\nfn main(){\nlet file=open_read(\"/dev/null\");\nconsume(file);\nprintln(file.is_open());\n}" in
  expect (moved.span.line=5 && moved.span.column=9) "use-after-move location changed";
  (match moved.notes with
   | [({file;line;column},message)] ->
       expect(file="test.xen" && line=4 && column=9 && message="value moved here")
         "function-argument move note location differs"
   | _ -> fail "use-after-move did not include exactly one move note");
  let reinitialized =
    "fn consume(file:File){}fn main(){let mut file=open_read(\"/dev/null\");consume(file);file=open_read(\"/dev/null\");println(file.is_open());}" in
  (match Checker.check (Parser.parse ~file:"test.xen" reinitialized) with
   | Ok _ -> () | Error _ -> fail "reinitialization retained a stale move state");
  let block = check_error
    "fn consume(file:File){}fn main(){let file=open_read(\"/dev/null\");{consume(file);}println(file.is_open());}" in
  expect (List.length block.notes=1) "single-path block move lost its note";
  let scoped = check_error
    "fn consume(file:File){}fn main(){let file=open_read(\"/dev/null\");#scope[explc]{consume(file);}println(file.is_open());}" in
  expect (List.length scoped.notes=1) "single-path capability scope move lost its note";
  let same_origin = check_error
    "fn consume(file:File){}fn use(flag:Bool){let file=open_read(\"/dev/null\");consume(file);if flag{}else{}println(file.is_open());}fn main(){use(true);}" in
  expect (List.length same_origin.notes=1) "same move origin across branches lost its note";
  let divergent = check_error
    "fn consume(file:File){}fn use(flag:Bool){let file=open_read(\"/dev/null\");if flag{consume(file);}else{consume(file);}println(file.is_open());}fn main(){use(true);}" in
  expect (contains divergent.message "moved File" && divergent.notes=[])
    "different branch move locations lost the error or produced a misleading note";
  let vector_move = check_error
    "fn consume(values:Vec<File>){}fn use(){let values:Vec<File>=[];consume(values);println(values.len());}fn main(){use();}" in
  expect (List.length vector_move.notes=1) "non-File move did not include its move note"

let test_control_flow_and_arity () =
  let missing = check_error "fn value(flag: Bool) -> Int { if flag { return 1; } } fn main() {}" in
  expect (contains missing.message "fall through") "missing-return diagnostic differs";
  let unreachable = check_error "fn main() { return; println(1); }" in
  expect (contains unreachable.message "unreachable") "unreachable diagnostic differs";
  let params = check_error "fn f(a:Int,b:Int,c:Int,d:Int,e:Int,f:Int,g:Int) {} fn main() {}" in
  expect (contains params.message "six parameters") "parameter-limit diagnostic differs";
  let arguments = check_error "fn f(a:Int,b:Int,c:Int,d:Int,e:Int,f:Int) {} fn main() { f(1,2,3,4,5,6,7); }" in
  expect (contains arguments.message "six arguments") "argument-limit diagnostic differs"

let test_lexical_blocks_and_cleanup () =
  let ast=Parser.parse ~file:"blocks.xen" "fn main(){{}{let x=1;println(x);}}" in
  (match ast.Ast.functions with
   |[{body=[{node=Ast.Block [] ;_};{node=Ast.Block [_;_];_}];_}]->()
   |_->fail "standalone blocks were not preserved in AST");
  List.iter(fun(source,needle)->let d=check_error source in
    expect(contains d.message needle) "lexical block diagnostic differs") [
    ("fn main(){let x=1;let x=2;}","duplicate local");
    ("fn main(){{let x=1;}println(x);}","unknown local") ];
  let source=
    "fn echo(x:String)->String{{let x=\"inner\";println(x);}return x;}"^
    "fn number()->Int{{let s=\"gone\";}return 7;}"^
    "fn decimal()->Float{{let v=[1];}return 2.5;}"^
    "fn main(){let x=1;{let x=x+1;println(x);}{let x=3;println(x);}println(x);"^
    "println(echo(\"outer\"));println(number());println(decimal());"^
    "let mut i=0;while i<4{{let s=\"iteration\";i=i+1;if i==2{continue;}if i==3{break;}println(i);}}}" in
  let status,stdout,stderr=execute source in
  if not(status=0&&stderr=""&&stdout="2\n3\n1\ninner\nouter\n7\n2.5\n1\n")then
    fail "lexical shadowing, cleanup, or return staging differs: %d %S %S" status stdout stderr;
  let lowered=match Checker.check(Parser.parse ~file:"cleanup.xen"
    "fn main(){let a=\"a\";{let b=[1];let c=\"c\";return;}}")with
    |Ok p->p|Error d->fail "cleanup IR source rejected: %s" d.message in
  let func=List.hd (Semantic_ir.program lowered).Semantic_ir.functions in
  let named prefix=Array.to_list func.locals|>List.find(fun(l:Semantic_ir.local)->String.starts_with ~prefix:(prefix^"$")l.name)in
  let a=named "a"and b=named "b"and c=named "c"in
  let drops=Array.to_list func.blocks|>List.concat_map(fun(block:Semantic_ir.block)->List.filter_map(fun(op:Semantic_ir.operation)->match op.node with Semantic_ir.Drop p when p.root=a.id||p.root=b.id||p.root=c.id->Some p.root|_->None)block.operations)in
  if drops<>[c.id;b.id;a.id]then fail "return cleanup is not actual declaration-reverse: %s" (Semantic_ir.dump(Semantic_ir.program lowered));
  let status,_,stderr=execute
    "fn early()->Int{{let f=open_read(\"/dev/null\");return 1;}}fn main(){let mut i=0;while i<2000{{let f=open_read(\"/dev/null\");i=i+1;if i%2==0{continue;}}}println(early());}" in
  expect(status=0&&stderr="") "File lexical cleanup leaked descriptors"

let test_modes () =
  let ast = Parser.parse ~file:"modes.xen" "#![bb]\n#![explc]\nfn main() {}" in
  (match Result.map Semantic_ir.program (Checker.check ast) with
  | Error diagnostic -> fail "mode source rejected: %s" diagnostic.message
  | Ok {functions=[func];_} -> expect (func.Semantic_ir.mode_set = [Ast.Explc; Ast.Bb]) "mode set was not normalized or preserved"
  | Ok _ -> fail "unexpected mode program shape");
  let valid = [""; "#![explc]\n"; "#![jit]\n"; "#![bb]\n"; "#![explc, jit]\n";
    "#![explc, bb]\n"; "#![jit, bb]\n"; "#![bb, explc, jit]\n"] in
  List.iter (fun prefix -> ignore (Parser.parse ~file:"modes.xen" (prefix ^ "fn main() {}"))) valid;
  let jit = check_error "#![jit]\nfn main() {}" in
  expect (contains jit.message "function-level jit mode is not supported" &&
          contains jit.message "#scope[jit]" && contains jit.message "experimental")
    "unsupported function jit diagnostic differs";
  ignore(compile "fn main(){#scope[jit]{println(1);}}");
  let invalid = ["#![]\n"; "#![wat]\n"; "#![jit, jit]\n"; "#![jit,]\n";
    "#![jit] fn main() {}"; "#![jit]\n#![jit]\n"] in
  List.iter (fun prefix ->
    try ignore (Parser.parse ~file:"modes.xen" (prefix ^ (if contains prefix "fn main" then "" else "fn main() {}")));
      fail "invalid mode attribute was accepted: %S" prefix
    with Parser.Error _ -> ()) invalid

let test_mode_scopes () =
  let ast = Parser.parse ~file:"scopes.xen"
    "#global[bb, explc]\n#![explc]\nfn main(){#scope[bb]{#scope[explc]{println(1);}}}" in
  expect (ast.Ast.global_mode_set = [Ast.Explc; Ast.Bb]) "global modes were not normalized";
  (match Result.map Semantic_ir.program (Checker.check ast) with
   |Ok program->let f=List.hd program.Semantic_ir.functions in
       expect(f.mode_set=[Ast.Explc;Ast.Bb]&&Array.for_all(fun(s:Semantic_ir.scope)->s.mode_set=[Ast.Explc;Ast.Bb])f.scopes) "nested effective capabilities were not preserved"
   |Error d->fail "valid scoped mode source rejected: %s" d.message);
  List.iter (fun source -> try ignore(Parser.parse ~file:"scopes.xen" source);fail "invalid global/scope syntax accepted"
    with Parser.Error _ -> ()) [
      "#global[]\nfn main(){}"; "#global[wat]\nfn main(){}"; "#global[bb,bb]\nfn main(){}";
      "#global[bb,]\nfn main(){}"; "#global[bb] fn main(){}";
      "fn f(){}\n#global[bb]\nfn main(){}"; "#global[bb]\n#global[explc]\nfn main(){}";
      "fn main(){#scope[]{} }"; "fn main(){#scope[wat]{} }";
      "fn main(){#scope[bb,bb]{} }"; "fn main(){#scope[bb,]{} }" ];
  let global_jit=check_error "#global[jit]\nfn main(){}" in
  expect (contains global_jit.message "global jit mode is not supported" &&
          contains global_jit.message "#scope[jit]") "unsupported global jit diagnostic differs";
  let global_refs =
    "#global[explc]\nfn read(x:&Int)->Int{return *x;}\nfn main(){let x=7;println(read(&x));}" in
  let status,stdout,stderr=execute global_refs in
  expect(status=0 && stdout="7\n" && stderr="") "global explc ownership/reference behavior differs";
  let status,stdout,stderr=execute
    "#global[bb]\nfn load(p:Ptr<Int>)->Int{return raw_load_int(p,0);}\nfn main(){let p=raw_alloc_int(1);raw_store_int(p,0,6);println(load(p));raw_free_int(p);}" in
  expect(status=0 && stdout="6\n" && stderr="") "global bb signature/builtin behavior differs";
  let status,stdout,stderr=execute
    "fn main(){let x=5;#scope[explc]{let r=&x;println(*r);}println(x);}" in
  expect(status=0 && stdout="5\n5\n" && stderr="") "lexical explc scope execution differs";
  let status,stdout,stderr=execute
    "fn main(){#scope[bb]{let p=raw_alloc_int(1);raw_store_int(p,0,42);println(raw_load_int(p,0));raw_free_int(p);}println(9);}" in
  expect(status=0 && stdout="42\n9\n" && stderr="") "lexical bb scope execution differs";
  let leaked=check_error "fn main(){#scope[bb]{let p=raw_alloc_int(1);}println(p);}" in
  expect(contains leaked.message "unknown local") "scope local leaked outward";
  let outside=check_error "fn main(){#scope[bb]{let p=raw_alloc_int(1);raw_free_int(p);}raw_alloc_int(1);}" in
  expect(contains outside.message "requires #![bb]") "scope bb capability leaked outward";
  let moved=check_error
    "fn take(f:File){}fn main(){let f=open_read(\"/dev/null\");#scope[explc]{take(f);}println(f.is_open());}" in
  expect(contains moved.message "moved File") "scope move state did not propagate";
  let status,stdout,stderr=execute
    "fn take(f:File){}fn main(){let mut f=open_read(\"/dev/null\");#scope[explc]{take(f);f=open_read(\"/dev/null\");}println(f.is_open());}" in
  expect(status=0 && stdout="true\n" && stderr="") "scope reinitialization did not propagate";
  let status,stdout,stderr=execute
    "fn main(){let mut i=0;while i<4{#scope[bb]{if i==1{i=i+1;continue;}if i==3{break;}println(i);}i=i+1;}println(8);}" in
  expect(status=0 && stdout="0\n2\n8\n" && stderr="") "scope control flow execution differs";
  let capability_callees=
    "#![explc]\nfn e(s:String)->Int{return len(s);}"^
    "#![bb]\nfn b(x:Int)->Int{return x+1;}"^
    "#![explc,bb]\nfn eb(v:Vec<Int>)->Int{return len(v);}"^
    "fn main(){let s=\"safe\";let v=[1,2];println(e(s)+b(1)+eb(v));println(s);println(v);}" in
  let lowered=match Checker.check(Parser.parse ~file:"capability-calls.xen" capability_callees)with
    |Ok p->p|Error d->fail "value-only capability call rejected: %s" d.message in
  (match List.find(fun(f:Semantic_ir.func)->f.name="main")(Semantic_ir.program lowered).functions with
   |{mode_set=[];_}->()
   |_->fail "callee capability changed caller IR mode");
  let status,stdout,stderr=execute capability_callees in
  expect(status=0&&stdout="8\nsafe\n[1, 2]\n"&&stderr="") "value-only capability calls changed caller ownership";
  let ref_boundary=check_error "#![explc]\nfn read(x:&Int)->Int{return *x;}fn main(){let x=1;read(&x);}" in
  expect(contains ref_boundary.message "references require") "public reference boundary lost explc gate";
  let ptr_boundary=check_error "#![bb]\nfn make()->Ptr<Int>{return raw_alloc_int(1);}fn main(){make();}" in
  expect(contains ptr_boundary.message "receiving Ptr<Int>") "public pointer boundary lost bb gate"

let test_calls_and_runtime () =
  let source =
    "fn id(x:Int)->Int{return x;}\n" ^
    "fn six(a:Int,b:Int,c:Int,d:Int,e:Int,f:Int)->Int{return a+b+c+d+e+f;}\n" ^
    "fn main(){println(six(id(1),id(2),id(3),id(4),id(5),id(6))+id(7));println(true);println(false);println(-9223372036854775808);}" in
  let status, stdout, stderr = execute source in
  expect (status = 0 && stderr = "") "nested-call executable failed";
  expect (stdout = "28\ntrue\nfalse\n-9223372036854775808\n") "nested-call or print output differs";
  let status, stdout, stderr = execute "fn main(){println(9/3);false&&1/0==0;}" in
  expect (status = 0 && stdout = "3\n" && stderr = "") "normal or short-circuit division failed";
  let status, _, stderr = execute "fn main(){println(1/0);}" in
  if not (status = 1 && contains stderr "xen runtime error: division by zero") then
    fail "zero-division contract differs: status=%d stderr=%S" status stderr;
  let status, _, stderr = execute "fn main(){println(-9223372036854775808 / -1);}" in
  expect (status = 1 && contains stderr "signed division overflow") "division-overflow contract differs"

let test_feedback_patch () =
  let ast = Parser.parse ~file:"operators.xen"
    "fn main(){println(20/3%2*4);}" in
  (match ast with
   | { Ast.functions = [{ Ast.body = [{ node = Ast.Expr { node = Ast.Call ("println", [{ node = Ast.Binary ("*", { node = Ast.Binary ("%", { node = Ast.Binary ("/", _, _); _ }, _); _ }, _); _ }]); _ }; _ }]; _ }]; _ } -> ()
   | _ -> fail "multiplicative operators did not remain left-associative");
  List.iter (fun (source, needle) ->
    let diagnostic = check_error source in
    if not (contains diagnostic.message needle) then
      fail "new checker rejection differs for %S: %s" source diagnostic.message)
    [ ("fn main(){println(1.0%1.0);}", "expected Int");
      ("fn main(){println(\"a\"-\"b\");}", "arithmetic expects");
      ("fn main(){println(\"a\"*\"b\");}", "arithmetic expects");
      ("fn main(){println(\"a\"/\"b\");}", "arithmetic expects");
      ("fn main(){println(\"a\"+1);}", "expected String");
      ("fn main(){println();}", "expects 1 argument");
      ("fn main(){int_to_str(1.0);}", "expected Int");
      ("fn main(){int_to_str();}", "expects 1 argument");
      ("fn println(x:Int){}fn main(){}", "reserved");
      ("fn int_to_str(x:Int)->String{return \"\";}fn main(){}", "reserved") ];
  let status, stdout, stderr = execute
    "fn main(){println(7%3);println(-7%3);println(7%-3);println(-7%-3);println(0%3);}" in
  expect (status=0 && stderr="" && stdout="1\n-1\n1\n-1\n0\n") "signed remainder results differ";
  let status, _, stderr = execute "fn main(){println(1%0);}" in
  if not (status=1 && contains stderr "remainder by zero") then
    fail "remainder-by-zero contract differs: %d %S" status stderr;
  expect (contains stderr "test.xen:1:19") "remainder-by-zero diagnostic lost its location";
  let status,_,stderr=execute "fn main(){println(-9223372036854775808%-1);}" in
  expect(status=1&&contains stderr "signed remainder overflow") "signed remainder overflow contract differs";
  let nul = String.make 1 '\000' in
  let status, stdout, stderr = execute
    ("fn make()->String{return \"B\"+\"C\";}fn main(){let a=\"A\";println(\"\"+\"\");" ^
     "println(a+make()+\"D\");println(a);println(\"x" ^ nul ^ "\"+\"é\");" ^
     "println(int_to_str(0)+\",\"+int_to_str(-1)+\",\"+int_to_str(-9223372036854775808)+\",\"+int_to_str(9223372036854775807));}") in
  expect (status=0 && stderr="") "String concatenation executable failed";
  let expected = "\nABCD\nA\nx" ^ nul ^ "é\n0,-1,-9223372036854775808,9223372036854775807\n" in
  if stdout <> expected then fail "String concatenation or int_to_str bytes differ: %S" stdout;
  let status, stdout, stderr = execute
    "fn main(){print(1);print(2.5);print(true);print(\"x\");print([1,2]);print([3.5]);println(\"\");println(false);println(4);println(5.5);println(\"s\");println([6]);println([7.5]);}" in
  expect (status=0 && stderr="" &&
    stdout="12.5truex[1, 2][3.5]\nfalse\n4\n5.5\ns\n[6]\n[7.5]\n")
    "print/println newline contract differs"

let test_call_depth () =
  let prefix = "fn down(n:Int)->Int{if n==0{return 0;}else{return down(n-1);}}\nfn main(){println(down(" in
  let status, stdout, _ = execute (prefix ^ "4094));}") in
  expect (status = 0 && stdout = "0\n") "call depth 4096 should succeed";
  let status, _, stderr = execute (prefix ^ "4095));}") in
  expect (status = 1 && contains stderr "maximum call depth exceeded") "call depth above 4096 was not diagnosed"

let test_float_literals_and_checker () =
  let ast = Parser.parse ~file:"float.xen"
    "fn value(x:Float)->Float{return x+1.5e-2;} fn main(){println(value(1e3));}" in
  (match ast with
   | { Ast.functions = { Ast.params = [{ typ = Ast.Float; _ }]; return_type = Ast.Float; body = [statement]; _ } :: _; _ } ->
       (match statement.node with
        | Ast.Return (Some { node = Ast.Binary (_, _, { node = Ast.Float_lit value; _ }); _ }) ->
            expect (value = 0.015) "Float literal value was not preserved in AST"
        | _ -> fail "unexpected Float AST shape")
   | _ -> fail "Float signature was not preserved in AST");
  (match Result.map Semantic_ir.program (Checker.check ast) with
   |Ok program->let f=List.hd program.Semantic_ir.functions in
       expect(f.return_type=Ast.F64&&List.map(fun id->f.locals.(id).typ)f.params=[Ast.F64]) "Float ABI types were not canonicalized"
   |Error d->fail "Float source rejected: %s"d.message);

  let mixed = check_error "fn main(){println(1+1.0);}" in
  expect (contains mixed.message "expected Int") "implicit Int/Float promotion was accepted"

let test_float_execution_and_calls () =
  let source =
    "fn mix(a:Float,b:Int,c:Bool,d:Float,e:Int,f:Float)->Float{" ^
    "if c{return a+float(b)*d-float(e)/f;}return -0.0;}" ^
    "fn recurse(n:Int,x:Float)->Float{if n==0{return x;}return recurse(n-1,x+0.5);}" ^
    "fn main(){let mut x=1.5;x=x*2.0;println(x);println(mix(1.0,2,true,3.0,4,2.0));" ^
    "println(recurse(3,1.0));println(1.0<2.0);println(2.0<=2.0);println(3.0>2.0);" ^
    "println(3.0>=4.0);println(0.0/0.0==0.0/0.0);println(0.0/0.0!=0.0);" ^
    "println(0.0/0.0<1.0);println(1.0/0.0);println(-0.0);}" in
  let status, stdout, stderr = execute source in
  expect (status = 0 && stderr = "") "Float call executable failed";
  if stdout <> "3.0\n5.0\n2.5\ntrue\ntrue\ntrue\nfalse\nfalse\ntrue\nfalse\ninf\n-0.0\n" then
    fail "Float arithmetic, ABI, or comparison output differs: %S" stdout

let test_float_conversions_and_print () =
  let source =
    "fn main(){println(float(9007199254740993));println(int(3.9));println(int(-3.9));" ^
    "println(int(-9223372036854775808.0));println(0.1);println(1.2345678901234567);" ^
    "println(1.7976931348623157e308);println(4.9406564584124654e-324);" ^
    "println(1e-4);println(1e-5);println(1e16);println(1e17);println(-0.0);" ^
    "println(1.0/0.0);println(-1.0/0.0);println(0.0/0.0);println(-(0.0/0.0));}" in
  let status, stdout, stderr = execute source in
  expect (status = 0 && stderr = "") "Float conversion/format executable failed";
  if stdout <>
    "9007199254740992.0\n3\n-3\n-9223372036854775808\n0.10000000000000001\n" ^
    "1.2345678901234567\n1.7976931348623157e+308\n4.9406564584124654e-324\n" ^
    "0.0001\n1.0000000000000001e-05\n10000000000000000.0\n1e+17.0\n-0.0\ninf\n-inf\n-nan\nnan\n" then
    fail "%%.17g-compatible Float output differs: %S" stdout;
  List.iter (fun expression ->
    let status, stdout, stderr = execute ("fn main(){println(7);println(int(" ^ expression ^ "));}") in
    if not (status = 1 && stdout = "7\n" && contains stderr "test.xen:1:30" &&
      contains stderr "xen runtime error: Float cannot be converted to Int") then
      fail "invalid Float-to-Int conversion contract differs for %s: %d %S %S"
        expression status stdout stderr)
    ["1.0/0.0"; "0.0/0.0"; "9223372036854775808.0"]

let test_string_literals_and_checker () =
  let ast = Parser.parse ~file:"string.xen"
    "fn id(s:String)->String{return s;}fn main(){println(\"a\\n\\t\\r\\\"\\\\b\");}" in
  (match ast with
   | { Ast.functions = { Ast.params = [{ typ = Ast.String; _ }]; return_type = Ast.String; _ } :: _; _ } -> ()
   | _ -> fail "String signature was not preserved in AST");
  (match Result.map Semantic_ir.program (Checker.check ast) with
   |Ok program->let f=List.hd program.Semantic_ir.functions in
       expect(Array.exists(fun(b:Semantic_ir.block)->List.exists(fun(op:Semantic_ir.operation)->match op.node with Semantic_ir.Acquire(v,Semantic_ir.Move,_)when v.typ=Ast.String->true|_->false)b.operations)f.blocks) "managed return did not move ownership"
   |Error d->fail "managed return rejected: %s"d.message);

  let ordering = check_error "fn main(){println(\"a\"<\"b\");}" in
  expect (contains ordering.message "comparison expects") "String ordering was accepted"

let test_string_execution_and_abi () =
  let nul = String.make 1 '\000' in
  let source =
    "fn mix(a:String,b:Int,c:Float,d:Bool,e:String,f:Int)->String{" ^
    "if d{println(a);println(b);println(c);println(e);println(f);}return e;}" ^
    "fn recur(n:Int,s:String)->String{if n==0{return s;}return recur(n-1,s);}" ^
    "fn main(){let mut s=\"left\";let copy=s;s=\"right\";println(copy);println(s);" ^
    "println(s==\"right\");println(s!=copy);println(len(\"é\"));println(len(\"a" ^ nul ^ "b\"));" ^
    "println(mix(\"A\",2,3.5,true,\"B\",6));println(recur(3,\"R\"));}" in
  let status, stdout, stderr = execute source in
  expect (status = 0 && stderr = "") "String ABI executable failed";
  if stdout <> "left\nright\ntrue\ntrue\n2\n3\nA\n2\n3.5\nB\n6\nB\nR\n" then
    fail "String ownership, byte length, comparison, or mixed ABI output differs: %S" stdout

let test_string_builtins_and_moves () =
  let status, stdout, stderr = execute_args
    "fn main(){println(arg_count());println(arg(0));println(\"|\");println(arg(1));}" ["one"; "two"] in
  expect (status = 0 && stdout = "2\none\n|\ntwo\n" && stderr = "") "program argument builtins differ";
  let status, _, stderr = execute "fn main(){println(arg(0));}" in
  expect (status = 1 && contains stderr "missing program argument") "missing argument contract differs";
  List.iter (fun (source, expected) ->
    let status, _, stderr = execute source in
    expect (status = 1 && stderr = expected) "String failure builtin output differs")
    [ ("fn main(){assert(false);}", "assertion failed\n");
      ("fn main(){assert_msg(false,\"why\");}", "assertion failed: why\n");
      ("fn main(){panic(\"boom\");}", "boom\n") ];
  let status,stdout,stderr=execute
    "#![explc]\nfn take(s:String){} fn main(){let mut s=\"x\";take(s);println(s);s=s;while false{take(s);}println(s);}" in
  expect(status=0&&stdout="x\nx\n"&&stderr="") "explc changed managed String clone semantics"

let test_vec_checker () =
  let ast = Parser.parse ~file:"vec.xen"
    "fn empty()->Vec<Int>{return [];}fn main(){let mut v:Vec<Int>=[];v.push(1);v[0]=2;println(v.get(0));}" in
  (match Result.map Semantic_ir.program (Checker.check ast) with
   | Ok {functions=({ Semantic_ir.return_type = Ast.Vec Ast.I64; _ } :: _);_} -> ()
   | Ok _ -> fail "Vec type was not preserved in lowered IR"
   | Error diagnostic -> fail "valid Vec program rejected: %s" diagnostic.message);
  let ambiguous = check_error "fn main(){let v=[];}" in
  expect (contains ambiguous.message "cannot infer") "ambiguous empty Vec was accepted";
  let mixed = check_error "fn main(){let v=[1,2.0];}" in
  expect (contains mixed.message "expected Int") "mixed Vec element types were accepted";
  let immutable = check_error "fn main(){let v=[1];v.push(2);}" in
  expect (contains immutable.message "mutable local") "immutable Vec mutation was accepted";
  let managed = Parser.parse ~file:"vec.xen" "fn main(){let v:Vec<String>=[];}" in
  (match Checker.check managed with Ok _->()|Error d->fail "Vec<String> was rejected: %s" d.message);
  let borrowed = check_error "fn main(){let v:Vec<&Int>=[];}" in
  expect (contains borrowed.message "unsupported vector element") "borrowed Vec element was accepted"

let test_nested_vec_mutation () =
  let status,stdout,stderr=execute
    "struct Bag{values:Vec<Int>}enum Choice{Add,Skip}fn main(){let mut bag=Bag{values:[]};bag.values.push(1);bag.values.set(0,2);let choice=Choice.Add;match choice{Choice.Add=>{bag.values.push(3);},Choice.Skip=>{}}println(bag.values);let mut values:Vec<Int>=[];match choice{Choice.Add=>{values.push(4);},Choice.Skip=>{}}println(values);}" in
  if status<>0||stdout<>"[2, 3]\n[4]\n"||stderr<>"" then
    fail "nested/match Vec mutation differs: status=%d stdout=%S stderr=%S" status stdout stderr;
  let immutable=check_error "struct Bag{values:Vec<Int>}fn main(){let bag=Bag{values:[]};bag.values.push(1);}" in
  expect(contains immutable.message "field of a mutable local") "immutable struct Vec field mutation was accepted"

let test_pr4_review_regressions () =
  let status,stdout,stderr=execute
    "struct Counter{value:Int}impl Counter{fn read(&self)->Int{return self.value;}}enum Choice{Go,Stop}fn main(){let counter=Counter{value:7};let choice=Choice.Go;match choice{Choice.Go=>{println(counter.read());},Choice.Stop=>{}}}" in
  expect(status=0&&stdout="7\n"&&stderr="")
    "a read-only method named read was treated as a mutable receiver";
  let self_clone=Parser.parse ~file:"self-clone.xen"
    "struct Node{children:Vec<Node>}fn main(){let mut node=Node{children:[]};node.children.push(node);}" in
  (match Checker.check self_clone with Ok _->()|Error d->fail "a cloneable root was rejected while mutating its Vec field: %s" d.message);
  List.iter(fun source->let status,_,err=execute source in expect(status=0&&err="") "safe match mutate-then-move failed") [
    "enum Choice{Go,Stop}fn take(files:Vec<File>){}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));take(files);},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let moved=files;},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn take<T>(value:T){}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));take<Vec<File>>(files);},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn take<T>(value:T){}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));take(files);},Choice.Stop=>{}}}";
    "struct Sink{value:Int}impl Sink{fn take(&self,files:Vec<File>){}}enum Choice{Go,Stop}fn main(){let sink=Sink{value:0};let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));sink.take(files);},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let mut target:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));target=files;},Choice.Stop=>{}}}";
    "struct Holder{files:Vec<File>}enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let mut holder=Holder{files:[]};let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));holder.files=files;},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let mut slots:Vec<Vec<File>>=[[]];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));slots[0]=files;},Choice.Stop=>{}}}";
    "#![explc]\nfn main(){let mut files:Vec<File>=[];let mut target:Vec<File>=[];let target_ref=&mut target;match true{true=>{files.push(open_read(\"/dev/null\"));*target_ref=files;},false=>{}}}";
    "struct Box{files:Vec<File>}enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let boxed=Box{files:files};},Choice.Stop=>{}}}";
    "struct Box<T>{value:T}enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let boxed=Box{value:files};},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let pair:(Vec<File>,Int)=(files,1);},Choice.Stop=>{}}}";
    "enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let nested:Vec<Vec<File>>=[files];},Choice.Stop=>{}}}";
    "enum Wrapped{Files(Vec<File>)}enum Choice{Go,Stop}fn main(){let mut files:Vec<File>=[];let choice=Choice.Go;match choice{Choice.Go=>{files.push(open_read(\"/dev/null\"));let wrapped:Wrapped=Wrapped.Files(files);},Choice.Stop=>{}}}";
  ];
  let recursive_signature=Parser.parse ~file:"recursive.xen"
    "struct Node{children:Vec<Node>}fn relay(node:Node)->Node{return node;}fn main(){}" in
  (match Checker.check recursive_signature with Ok _->()|Error d->fail "recursive Vec signature was rejected: %s" d.message);
  let sibling_clone=Parser.parse ~file:"sibling.xen"
    "struct Bag{values:Vec<String>,current:String}fn main(){let mut bag=Bag{values:[],current:\"x\"};bag.values.push(bag.current);}" in
  (match Checker.check sibling_clone with Ok _->()|Error d->fail "cloning a sibling managed field was rejected: %s" d.message);
  let clone_argument=Parser.parse ~file:"clone-argument.xen"
    "struct Bag{values:Vec<Int>,label:String}fn inspect(bag:Bag)->Int{return 1;}fn main(){let mut bag=Bag{values:[],label:\"x\"};bag.values.push(inspect(bag));}" in
  (match Checker.check clone_argument with Ok _->()|Error d->fail "a cloneable root argument was treated as a move: %s" d.message);
  let nested_self_move=check_error
    "struct Bag{values:Vec<Int>,file:File}fn extract(bag:Bag)->Int{return 1;}fn main(){let mut bag=Bag{values:[],file:open_read(\"x\")};bag.values.push(extract(bag));}" in
  expect(contains nested_self_move.message "while mutating one of its Vec fields")
    "a field receiver was left live while an argument moved its root";
  let index_self_move=check_error
    "struct Bag{values:Vec<Int>,file:File}fn index_from(bag:Bag)->Int{return 0;}fn main(){let mut bag=Bag{values:[0],file:open_read(\"x\")};bag.values.set(index_from(bag),1);}" in
  expect(contains index_self_move.message "while mutating one of its Vec fields")
    "a Vec.set index could move the receiver root while its field address was live";
  let generated_consume=check_error
    "module guarded_consume; use std.iter; struct Bag{values:Vec<Int>,n:Int} impl Bag{fn next(&mut self)->Option<Int>{return Option<Int>.None;}} fn index_from<T>(value:T)->Int{return 0;} fn main(){let mut bag=Bag{values:[0],n:0};bag.values.set(index_from(bag.enumerate()),1);}" in
  expect(contains generated_consume.message "while mutating one of its Vec fields")
    "a compiler-generated consume bypassed the Vec field receiver guard";
  let sibling_move=Parser.parse ~file:"sibling-move.xen"
    "struct Bag{values:Vec<Int>,file:File}fn use_file(file:File)->Int{return 1;}fn main(){let mut bag=Bag{values:[],file:open_read(\"x\")};bag.values.push(use_file(bag.file));}" in
  (match Checker.check sibling_move with Ok _->()|Error d->fail "moving a sibling field was rejected: %s" d.message)

let test_slice_checker_and_execution () =
  let status,stdout,stderr=execute
    "fn size(s:Slice<Int>)->Int{return len(s);}fn main(){let mut v:Vec<Int>=[10,20,30];let s:Slice<Int>=v.slice(1,3);println(size(s));println(s[0]);let e:Slice<Int>=v.slice(2,2);println(e.len());}" in
  expect(status=0&&stdout="2\n20\n0\n"&&stderr="") "Slice view execution differs";
  let live=check_error "fn main(){let mut v=[1];let s:Slice<Int>=v.as_slice();v.push(2);println(s.len());}" in
  expect(contains live.message "while it is borrowed") "live Slice allowed owner mutation";
  let escaped=check_error "fn bad(v:Vec<Int>)->Slice<Int>{return v.as_slice();}fn main(){}" in
  expect(contains escaped.message "cannot be returned") "Slice return was accepted";
  let moved=check_error "fn main(){let mut files:Vec<File>=[];let f=open_read(\"x\");files.push(f);println(f.is_open());}" in
  expect(contains moved.message "moved File") "Vec<File>.push did not move its value"

let test_generic_scalar_vec () =
  let status,stdout,stderr=execute
    "fn first<T>(v:Vec<T>)->T{return v.get(0);}fn main(){println(first<I16>([i16(7)]));let mut f:Vec<F32>=[f32(1.5)];f.push(f32(2.5));println(f.pop());let bytes:Vec<U8>=[u8(9),u8(10)];let s:Slice<U8>=bytes.as_slice();println(s[1]);}" in
  expect(status=0&&stdout="7\n2.5\n10\n"&&stderr="") "generic/fixed-width Vec execution differs";
  let move_read=check_error "fn first<T>(v:Vec<T>)->T{return v.get(0);}fn main(){let files:Vec<File>=[];first<File>(files);}" in
  expect(contains move_read.message "move-only File") "move-only generic Vec read was accepted"

let test_vec_execution_and_abi () =
  let source =
    "fn id(v:Vec<Int>)->Vec<Int>{return v;}" ^
    "fn mix(a:Vec<Int>,b:String,c:Float,d:Int,e:Vec<Float>,f:Bool)->Int{" ^
    "if f{println(b);println(c);println(e);}return a[0]+d;}" ^
    "fn main(){let mut a:Vec<Int>=[];a.push(1);a.push(2);a.push(3);a.push(4);a.push(5);" ^
    "println(a.len());println(a.pop());a.set(0,9);a[1]=8;println(a.get(0));" ^
    "let b=id(a);println(a);println(b);println(a==b);println(a!=[9,8,3,4]);" ^
    "println(mix(a,\"x\",1.5,7,[2.5,-0.0],true));}" in
  let status, stdout, stderr = execute source in
  expect (status = 0 && stderr = "") "Vec ABI executable failed";
  if stdout <> "5\n5\n9\n[9, 8, 3, 4]\n[9, 8, 3, 4]\ntrue\nfalse\nx\n1.5\n[2.5, -0]\n16\n" then
    fail "Vec operations, formatting, equality, or mixed ABI differ: %S" stdout;
  let status, _, stderr = execute "fn main(){let v=[1];println(v[-1]);}" in
  expect (status = 1 && contains stderr "test.xen:1:29" && contains stderr "vector index out of bounds")
    "negative Vec index contract differs";
  let status, _, stderr = execute "fn main(){let mut v:Vec<Int>=[];println(v.pop());}" in
  expect (status = 1 && contains stderr "cannot pop from an empty vector") "empty Vec pop contract differs";
  let status, stdout, stderr = execute
    "fn main(){let mut v:Vec<Int>=[1,2,3,4,5];v.push(6);println(v);}" in
  expect (status = 0 && stderr = "" && stdout = "[1, 2, 3, 4, 5, 6]\n")
    "Vec literal allocation beyond the initial capacity differs";
  let status,stdout,stderr=execute "#![explc]\nfn take(v:Vec<Int>){}fn main(){let v=[1];take(v);println(v);}" in
  expect(status=0&&stdout="[1]\n"&&stderr="") "explc changed managed Vec clone semantics"

let test_generic_vec_storage_and_lifecycle () =
  let status,stdout,stderr=execute
    "struct P{x:U8,s:String}fn id(v:Vec<P>)->Vec<P>{return v;}fn main(){let mut n:Vec<U8>=[u8(1),u8(2),u8(3),u8(4)];n.push(u8(5));n.set(1,u8(9));let ns:Slice<U8>=n.slice(1,4);println(ns[0]);println(n.pop());let a:Vec<P>=[P{x:u8(1),s:\"a\"}];let mut b=id(a);b.set(0,P{x:u8(2),s:\"b\"});println(a[0].s);println(b[0].s);let mut v:Vec<String>=[\"x\"];v.push(\"y\");println(v.pop());println([[\"a\"],[\"b\"]]==[[\"a\"],[\"b\"]]);}" in
  expect(status=0&&stderr=""&&stdout="9\n5\na\nb\ny\ntrue\n")
    "generic Vec packed storage or managed lifecycle differs";
  let rejected=check_error "struct P{x:Int}fn main(){println([P{x:1}]==[P{x:1}]);}" in
  expect(contains rejected.message "Vec equality is not supported")
    "Vec equality accepted an element without equality semantics"

let test_remaining_builtins () =
  let quote value = "\"" ^ String.escaped value ^ "\"" in
  let valid = Parser.parse ~file:"builtins.xen"
    "fn main(){let a=zeros(2);let b=repeat(1,2);let c=repeat(1.5,2);let s=read_text(\"x\");let i=read_ints(\"x\");let f=read_floats(\"x\");}" in
  (match Checker.check valid with Ok _ -> () | Error d -> fail "builtin checker rejected valid calls: %s" d.message);
  List.iter (fun (source,needle) -> let d=check_error source in expect (contains d.message needle) "builtin checker diagnostic differs") [
    ("fn zeros(x:Int){}fn main(){}", "reserved");
    ("fn main(){zeros(1,2);}", "expects 1 argument");
    ("fn main(){repeat(true,2);}", "Int or Float");
    ("fn main(){read_text(1);}", "expected String") ];
  let status,stdout,stderr=execute
    "fn main(){println(zeros(5));println(repeat(7,5));println(repeat(-0.0,2));println(zeros(0));}" in
  if not(status=0 && stderr="" && stdout="[0, 0, 0, 0, 0]\n[7, 7, 7, 7, 7]\n[-0, -0]\n[]\n") then
    fail "zeros/repeat runtime differs: %d %S %S" status stdout stderr;
  let path=Filename.temp_file "xen-read-builtins-" ".dat" in
  Fun.protect ~finally:(fun()->Sys.remove path) (fun()->
    let oc=open_out_bin path in output_string oc " -9223372036854775808\t+7\r\n0 ";close_out oc;
    let p=quote path in let status,stdout,stderr=execute ("fn main(){println(read_ints("^p^"));println(len(read_text("^p^")));}") in
    if not(status=0 && stderr="" && stdout="[-9223372036854775808, 7, 0]\n28\n") then
      fail "read_text/read_ints runtime differs: %d %S %S" status stdout stderr;
    let oc=open_out_bin path in output_string oc "1 -.5 2. 1e2 -0.0 4.9406564584124654e-324 1.7976931348623157e308";close_out oc;
    let status,stdout,stderr=execute ("fn main(){println(read_floats("^p^"));}") in
    if not(status=0 && stderr="" && stdout="[1, -0.5, 2, 100, -0, 4.9406564584124654e-324, 1.7976931348623157e+308]\n") then
      fail "read_floats runtime differs: %d %S %S" status stdout stderr;
    let oc=open_out_bin path in output_string oc ("a" ^ String.make 1 '\000' ^ "b");close_out oc;
    let status,stdout,stderr=execute ("fn main(){let s=read_text("^p^");println(len(s));println(s==\"a"^String.make 1 '\000'^"b\");}") in
    expect(status=0 && stderr="" && stdout="3\ntrue\n") "read_text did not preserve embedded NUL";
    let oc=open_out_bin path in close_out oc;
    let status,stdout,stderr=execute ("fn main(){println(len(read_text("^p^")));println(read_ints("^p^"));}") in
    expect(status=0 && stderr="" && stdout="0\n[]\n") "empty read builtin result differs";
    let oc=open_out_bin path in output_string oc "NaN";close_out oc;
    let status,_,stderr=execute ("fn main(){read_floats("^p^");}") in
    expect(status=1 && contains stderr "invalid float token") "invalid Float token was accepted");
  List.iter(fun(source,message)->let status,_,stderr=execute source in
    expect(status=1 && contains stderr message && contains stderr "test.xen:1:") "builtin failure contract differs") [
      ("fn main(){zeros(-1);}","zeros length cannot be negative");
      ("fn main(){repeat(1,-1);}","repeat length cannot be negative");
      ("fn main(){read_text(\"/definitely/missing/xen\");}","file open failed") ]

let test_reference_parser_and_checker () =
  let ast = Parser.parse ~file:"ref.xen"
    "#![explc]\nfn f(x:&mut Vec<Int>,y:&String){*x=[1];println(*y);}" in
  (match ast with
   | { Ast.functions = [{ Ast.params = [{typ=Ast.Ref(true,Ast.Vec Ast.Int);_};
                       {typ=Ast.Ref(false,Ast.String);_}]; _ }]; _ } -> ()
   | _ -> fail "reference types or precedence were not preserved in AST");
  let rejected = [
    ("fn main(){let x=1;let r=&x;}", "explc");
    ("#![explc]\nfn main(){let x=1;let r=&mut x;}", "mutable local");
    ("#![explc]\nfn main(){let mut x=1;let r=&x;x=2;println(*r);}", "borrowed");
    ("#![explc]\nfn main(){let mut x=1;let r=&mut x;println(x);println(*r);}", "borrowed");
    ("#![explc]\nfn main(){let mut x=1;let a=&mut x;let b=&x;println(*a);println(*b);}", "conflicting");
    ("#![explc]\nfn bad(x:&Int)->&Int{return x;}fn main(){}", "cannot be returned");
    ("fn bad(x:&Int){}fn main(){}", "reference parameters");
  ] in
  List.iter (fun (source, message) ->
    let error = check_error source in
    if not(contains error.message message)then fail "reference rejection diagnostic differs: expected %s, got %s" message error.message) rejected;
  let _, nested = syntax_error "#![explc]\nfn bad(x:& &Int){}fn main(){}" in
  expect (contains nested "reference-to-reference") "nested reference type was accepted";
  (match Checker.check (Parser.parse ~file:"nll.xen"
      "#![explc]\nfn main(){let mut x=1;let r=&x;println(*r);x=2;println(x);}") with
   | Ok _ -> () | Error d -> fail "borrow did not end after last reference use: %s" d.message)

let test_reference_execution_and_abi () =
  let source =
    "#![explc]\nfn update(i:&mut Int,f:&mut Float,b:&Bool,s:&String,v:&mut Vec<Int>,w:&Vec<Float>){" ^
    "*i=*i+2;*f=*f+0.5;v.push(*i);v[0]=7;println(*b);println(*s);println(w.len());}" ^
    "#![explc]\nfn main(){let mut i=3;let mut f=1.0;let b=true;let s=\"R\";" ^
    "let mut v=[1];let w=[2.5,-0.0];let ri=&mut i;let rf=&mut f;let rb=&b;" ^
    "let rs=&s;let rv=&mut v;let rw=&w;update(ri,rf,rb,rs,rv,rw);" ^
    "println(*ri);println(*rf);println(*rv);*rv=[8,9];rv.push(10);println(v);}" in
  let status, stdout, stderr = execute source in
  expect (status=0 && stderr="") "reference ABI executable failed";
  expect (stdout="true\nR\n2\n5\n1.5\n[7, 5]\n[8, 9, 10]\n")
    "reference dereference, replacement, or Vec auto-dereference differs"

let test_aggregate_references () =
  let positives=[
    "struct ABI and forwarding",
      "struct C{n:Int,text:String}fn update(c:&mut C){c.n=c.n+2;c.text=c.text+\"!\";}fn read(c:&C)->Int{return c.n;}fn main(){let mut c=C{n:3,text:\"x\"};let r=&mut c;let forwarded=r;let call:fn(&mut C)->Unit=update;call(forwarded);println(r.text);println(read(&c));c.n=9;println(c.n);}", "x!\n5\n9\n";
    "tuple projection and replacement",
      "fn edit(p:&mut (Int,String)){p.0=p.0+1;p.1=\"changed\";}fn main(){let mut pair:(Int,String)=(1,\"old\");let r=&mut pair;edit(r);println(r.0);println(r.1);*r=(7,\"new\");let copy=*r;println(copy.0);println(pair.1);}", "2\nchanged\n7\nnew\n";
    "enum value match and replacement",
      "enum E<T>{Empty,Full(T)}fn read(e:&E<String>)->String{return match *e{E.Empty=>\"empty\",E.Full(s)=>s};}fn replace(e:&mut E<String>){*e=E.Full(\"new\");}fn main(){let mut e:E<String>=E.Full(\"old\");println(read(&e));replace(&mut e);println(read(&e));let r=&mut e;*r=E.Empty;println(read(&e));}", "old\nnew\nempty\n";
    "independent managed clone and self replacement",
      "struct Bag{text:String,items:Vec<Int>}fn main(){let mut b=Bag{text:\"old\",items:[1]};let r=&mut b;let mut copy=*r;copy.text=\"copy\";copy.items.push(2);*r=*r;println(r.text);println(r.items);println(copy.text);println(copy.items);}", "old\n[1]\ncopy\n[1, 2]\n";
    "partial field move and reinitialization",
      "struct R{file:File,n:Int}fn take(r:&mut R)->File{let f=r.file;println(r.n);r.file=open_read(\"/dev/null\");return f;}fn main(){let mut owner=R{file:open_read(\"/dev/null\"),n:7};let mut f=take(&mut owner);println(f.read());let r=&mut owner;let mut moved=r.file;println(r.n);r.file=open_read(\"/dev/null\");println(moved.read());}", "7\n\n7\n\n";
    "Slice owner released after aggregate reference last use",
      "struct View{s:Slice<Int>,n:Int}fn main(){let mut a=[1];let view=View{s:a.as_slice(),n:7};let r=&view;let q=r;println(q.s[0]);a.push(2);println(view.n);}", "1\n7\n";
    "definite summary overwrite",
      "struct View{s:Slice<Int>}fn replace(v:&mut View,s:Slice<Int>){*v=View{s:s};}fn main(){let mut a=[1];let b=[2];let mut view=View{s:a.as_slice()};replace(&mut view,b.as_slice());a.push(3);println(view.s[0]);}", "2\n";
    "generic struct and method receiver",
      "struct Box<T>{value:T}impl<T> Box<T>{fn get(&self)->T{return self.value;}}fn read(b:&Box<String>)->String{return b.get();}fn main(){let b=Box<String>{value:\"ok\"};let r=&b;println(read(r));println(r.get());}", "ok\nok\n";
    "explicit enum field replacement",
      "struct H{o:Option<Int>}fn main(){let mut h=H{o:Option.Some(1)};let r=&mut h;r.o=Option<Int>.None;*r=H{o:Option<Int>.None};println(match r.o{Option.None=>1,Option.Some(n)=>n});}", "1\n";
  ]in
  List.iter(fun(name,source,expected)->let status,out,err=execute("#global[explc]\n"^source)in
    if status<>0||out<>expected||err<>""then fail "aggregate reference %s: status=%d stdout=%S stderr=%S"name status out err)positives;
  List.iter(fun(source,needle)->let d=check_error source in
    if not(contains d.message needle)then fail "aggregate reference expected %s, got %s\n%s"needle d.message source)[
    "struct P{x:Int}fn main(){let p=P{x:1};let r=&p;}","explc";
    "struct P{x:Int}fn read(p:&P){}fn main(){}","reference parameters";
    "#global[explc]\nstruct P{x:Int}fn main(){let p=P{x:1};let r=&mut p;}","mutable local";
    "#global[explc]\nstruct P{x:Int}fn main(){let mut p=P{x:1};let r=&p;p.x=2;println(r.x);}","borrowed";
    "#global[explc]\nstruct P{x:Int}fn main(){let mut p=P{x:1};let r=&mut p;println(p.x);println(r.x);}","borrowed";
    "#global[explc]\nstruct P{x:Int}fn main(){let mut p=P{x:1};let r=&p;r.x=2;}","immutable local";
    "#global[explc]\nstruct P{x:Int}fn main(){let mut p=P{x:1};let r=&p;*r=P{x:2};}","shared reference";
    "#global[explc]\nfn main(){let mut p:(Int,String)=(1,\"x\");let r=&p;r.0=2;}","immutable local";
    "#global[explc]\nstruct R{f:File}fn main(){let r=R{f:open_read(\"/dev/null\")};let p=&r;let copy=*p;}","cannot move";
    "#global[explc]\nstruct R{f:File}fn main(){let mut r=R{f:open_read(\"/dev/null\")};let p=&mut r;let copy=*p;}","cannot move";
    "#global[explc]\nstruct R{f:File}fn main(){let r=R{f:open_read(\"/dev/null\")};let p=&r;let f=p.f;}","shared reference";
    "#global[explc]\nstruct R{f:File,n:Int}fn main(){let mut r=R{f:open_read(\"/dev/null\"),n:1};let f=r.f;let p=&mut r;}","moved";
    "#global[explc]\nstruct R{f:File}fn take(r:R){}fn main(){let r=R{f:open_read(\"/dev/null\")};let p=&r;take(r);let f=p.f;}","borrowed";
    "#global[explc]\nstruct View{s:Slice<Int>}fn main(){let mut a=[1];let v=View{s:a.as_slice()};let r=&v;a.push(2);println(r.s[0]);}","borrowed";
    "#global[explc]\nstruct View{s:Slice<Int>}fn replace(v:&mut View,s:Slice<Int>,c:Bool){if c{v.s=s;}}fn main(){let mut a=[1];let b=[2];let mut v=View{s:a.as_slice()};replace(&mut v,b.as_slice(),true);a.push(3);println(v.s[0]);}","borrowed";
    "#global[explc]\nstruct View{s:Slice<Int>}fn replace(v:&mut View,s:Slice<Int>){v.s=s;}fn main(){let a=[1];let mut b=[2];let mut v=View{s:a.as_slice()};replace(&mut v,b.as_slice());b.push(3);println(v.s[0]);}","borrowed";
    "#global[explc]\nstruct View{s:Slice<Int>}fn main(){let mut a=[1];let b=[2];let mut v=View{s:a.as_slice()};let r=&mut v;let copy=*r;r.s=b.as_slice();a.push(3);println(copy.s[0]);}","borrowed";
    "#global[explc]\nstruct View{s:Slice<Int>}fn bad(v:&mut View){let a=[1];*v=View{s:a.as_slice()};}fn main(){let a=[2];let mut v=View{s:a.as_slice()};bad(&mut v);println(v.s[0]);}","escapes";
    "#global[explc]\nstruct P{x:Int}fn main(){let p=P{x:1};let r=&p;let q=&r;}","cannot reference";
    "#global[explc]\nstruct P{x:Int}fn main(){let r=&P{x:1};}","local variable";
    "#global[explc]\nstruct R{x:&Int}fn main(){}","unsupported struct field";
    "#global[bb,explc]\nstruct R{p:Ptr<Int>}fn main(){let r=R{p:raw_alloc<Int>(1)};let q=&r;let copy=*q;}","cannot move";
    "struct R{p:Ptr<Int>}#![explc]\nfn read(r:&R){}fn main(){}","requires #![bb]";
    "#global[explc]\nenum E{Open(File),Empty}fn main(){let e=E.Open(open_read(\"/dev/null\"));let r=&e;let copy=*r;}","cannot move";
    "#global[explc]\nfn main(){let p=(open_read(\"/dev/null\"),1);let r=&p;let copy=*r;}","cannot move";
  ];
  (* Existing contextual inference limitation, common to owned and referenced
     struct fields. Explicit enum arguments above remain a working control. *)
  List.iter(fun body->let d=check_error("#global[explc]\nstruct H{o:Option<Int>}fn main(){let mut h=H{o:Option.Some(1)};"^body^"}")in
    expect(contains d.message "cannot infer type parameter") "struct field contextual inference limitation changed")
    ["h.o=Option.None;";"let r=&mut h;r.o=Option.None;";"let r=&mut h;*r=H{o:Option.None};"];
  let status,out,err=execute_with_fd_limit 32
    "#global[explc]\nstruct R{f:File}fn replace(r:&mut R){*r=R{f:open_read(\"/dev/null\")};}fn main(){let mut r=R{f:open_read(\"/dev/null\")};let mut i=0;while i<80{replace(&mut r);i=i+1;}let mut f=r.f;println(f.read());}"in
  expect(status=0&&out="\n"&&err="") "aggregate reference replacement leaked or duplicated File cleanup"

let test_shared_reborrow_and_coercion () =
  let positives=[
    "explicit scalar reborrow",
      "fn main(){let mut x=1;let r=&mut x;let s=&*r;let q=s;let again=&*s;println(*q+*again);*r=2;println(*r);}", "2\n2\n";
    "annotated scalar coercion and shared arguments",
      "fn sum(a:&Int,b:&Int)->Int{return *a+*b;}fn main(){let mut x=3;let r=&mut x;let s:&Int=r;println(*s);println(sum(r,r));*r=4;println(*r);}", "3\n6\n4\n";
    "aggregate methods",
      "struct C{n:Int}impl C{fn read(&self)->Int{return self.n;}fn add(&mut self,n:Int){self.n=self.n+n;}}fn read(c:&C)->Int{return c.n;}fn main(){let mut c=C{n:2};let r=&mut c;let s=&*r;println(s.n);println(read(r));r.add(r.read());println(r.n);}", "2\n2\n4\n";
    "tuple indirect call",
      "fn first(p:&(Int,String))->Int{return p.0;}fn main(){let mut p:(Int,String)=(5,\"x\");let r=&mut p;let s:&(Int,String)=r;println(s.1);let f:fn(&(Int,String))->Int=first;println(f(r));r.0=6;println(r.0);}", "x\n5\n6\n";
    "enum shared value observation",
      "enum E{Value(Int),Empty}fn read(e:&E)->Int{return match *e{E.Value(n)=>n,E.Empty=>0};}fn main(){let mut e=E.Value(7);let r=&mut e;println(read(r));*r=E.Empty;println(read(&*r));}", "7\n0\n";
    "joined parent origins and nested child forwarding",
      "struct C{n:Int}fn run(c:Bool){let mut a=C{n:1};let mut b=C{n:2};let r=if c{&mut a}else{&mut b};let s:&C=if c{r}else{r};let q=if c{s}else{&*s};println(q.n);r.n=3;println(r.n);}fn main(){run(true);run(false);}", "1\n3\n2\n3\n";
    "shared result through match context",
      "struct C{n:Int}fn main(){let mut c=C{n:8};let r=&mut c;let s:&C=match true{true=>r,false=>&*r};println(s.n);r.n=9;println(r.n);}", "8\n9\n";
    "reference expression evaluated once",
      "fn choose()->Bool{print(\"choose\");return true;}fn main(){let mut x=1;let r=&mut x;let s:&Int=if choose(){r}else{&*r};println(*s);*r=2;println(*r);}", "choose1\n2\n";
    "generic shared parameter",
      "struct Box<T>{value:T}fn read<T>(b:&Box<T>)->T{return b.value;}fn main(){let mut b=Box<Int>{value:10};let r=&mut b;println(read(r));b.value=11;println(b.value);}", "10\n11\n";
    "callee-created Slice preserves child authority",
      "fn view(v:&Vec<Int>,out:&mut V){out.s=v.as_slice();}struct V{s:Slice<Int>}fn main(){let mut a=[1];let b=[2];let mut v=V{s:b.as_slice()};let r=&mut a;view(r,&mut v);println(v.s[0]);r.push(3);println(r.len());}", "1\n2\n";
  ]in
  List.iter(fun(name,source,expected)->let status,out,err=execute("#global[explc]\n"^source)in
    if status<>0||out<>expected||err<>""then fail "shared reborrow %s: status=%d stdout=%S stderr=%S"name status out err)positives;
  let status,out,err=execute
    "struct C{n:Int}impl C{fn read(&self)->Int{return self.n;}fn add(&mut self){self.n=self.read()+1;}}fn main(){let mut c=C{n:1};c.add();println(c.n);}"in
  expect(status=0&&out="2\n"&&err="") "implicit shared method reborrow inherited explc";
  List.iter(fun(source,needle)->let d=check_error source in
    if not(contains d.message needle)then fail "shared reborrow expected %s, got %s\n%s"needle d.message source)[
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let s=&*r;*r=2;println(*s);}","borrowed";
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let alias=r;let s:&Int=r;*alias=2;println(*s);}","borrowed";
    "#global[explc]\nstruct C{n:Int}fn main(){let mut c=C{n:1};let r=&mut c;let s:&C=r;r.n=2;println(s.n);}","borrowed";
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let s=&*r;*s=2;}","shared";
    "#global[explc]\nfn write(r:&mut Int){*r=2;}fn main(){let mut x=1;let r=&mut x;let s=&*r;write(s);}","expected &mut";
    "#global[explc]\nfn both(a:&Int,b:&mut Int){*b=*a;}fn main(){let mut x=1;let r=&mut x;both(r,r);}","conflicting";
    "#global[explc]\nfn use(a:&Int,b:Int){}fn change(a:&mut Int)->Int{*a=2;return 2;}fn main(){let mut x=1;let r=&mut x;use(r,change(r));}","borrowed";
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let s:&Int=r;let mut i=0;while i<2{println(*s);*r=2;i=i+1;}}","borrowed";
    "#global[explc]\nstruct C{n:Int}fn run(c:Bool){let mut a=C{n:1};let mut b=C{n:2};let r=if c{&mut a}else{&mut b};let s:&C=r;r.n=3;println(s.n);}fn main(){run(true);}","borrowed";
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let s=&r;}","cannot reference";
    "#global[explc]\nfn main(){let mut x=1;let r=&mut x;let s=&mut *r;}","mutable reborrow";
    "#![explc]\nfn read(r:&Int){}fn main(){let mut x=1;#scope[explc]{let r=&mut x;}read(&x);}","explc";
    "struct C{n:Int}fn main(){let mut c=C{n:1};let s=&*(&mut c);println(s.n);}","explc";
    "struct C{n:Int}fn main(){let mut c=C{n:1};let s:&C=&mut c;println(s.n);}","explc";
    "#global[explc]\nfn change(x:&mut Int)->Int{*x=2;return 2;}fn main(){let f:fn(&Int)->Int=change;}","expected fn";
    "#global[explc]\nfn view(v:&Vec<Int>,out:&mut V){out.s=v.as_slice();}struct V{s:Slice<Int>}fn main(){let mut a=[1];let b=[2];let mut v=V{s:b.as_slice()};let r=&mut a;view(r,&mut v);r.push(3);println(v.s[0]);}","borrowed";
  ]

let xen_string value =
  let b = Buffer.create (String.length value + 2) in
  Buffer.add_char b '"';
  String.iter (function
    | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n" | '\t' -> Buffer.add_string b "\\t"
    | '\r' -> Buffer.add_string b "\\r" | c -> Buffer.add_char b c) value;
  Buffer.add_char b '"'; Buffer.contents b

let test_file_checker () =
  let valid =
    "#![explc]\nfn relay(f:File)->File{return f;}" ^
    "#![explc]\nfn inspect(f:&File)->Bool{return f.is_open();}" ^
    "#![explc]\nfn use(f:&mut File){f.write(\"x\");f.close();}" ^
    "fn main(){let mut f=open_write(\"/tmp/xen-check-file\");println(f.is_open());}" in
  (match Checker.check (Parser.parse ~file:"file.xen" valid) with
   | Ok _ -> () | Error d -> fail "valid File source rejected: %s" d.message);
  let rejected = [
    ("fn main(){let f=open_read(\"x\");f.close();}", "mutable local");
    ("fn take(f:File){}fn main(){let f=open_read(\"x\");take(f);println(f.is_open());}", "moved File");
    ("fn main(){let mut f=open_read(\"x\");f=f;}", "itself");
    ("fn main(){let f=open_read(\"x\");println(f);}", "println accepts");
    ("fn main(){let f=open_read(\"x\");println(f==f);}", "File equality");
    ("fn main(){let f=open_read(\"x\");println(len(f));}", "len expects") ] in
  List.iter (fun (source,needle) -> let d=check_error source in
    expect (contains d.message needle) "File checker diagnostic differs") rejected

let test_file_execution () =
  let path = Filename.temp_file "xen-file-test-" ".dat" in
  Sys.remove path;
  Fun.protect ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ()) (fun () ->
    let p=xen_string path in
    let source =
      "#![explc]\nfn relay(f:File)->File{return f;}" ^
      "#![explc]\nfn main(){let mut out=open_write("^p^");println(out.is_open());" ^
      "out.write(\"hé\");out.write(\"llo\");out.close();out.close();println(out.is_open());" ^
      "let input=open_read("^p^");let mut moved=relay(input);println(moved.read());println(len(moved.read()));}" in
    let status,stdout,stderr=execute source in
    expect (status=0 && stderr="" && stdout="true\nfalse\nhéllo\n0\n") "File write/read/offset/close behavior differs";
    expect (read_file path="héllo") "open_write did not create/truncate the expected bytes");
  let status,_,stderr=execute "fn main(){let f=open_read(\"/definitely/missing/xen-file\");}" in
  expect (status=1 && contains stderr "test.xen:1:17" && contains stderr "file open failed") "File open failure contract differs";
  let nul=String.make 1 '\000' in
  let status,_,stderr=execute ("fn main(){let f=open_read(\"a"^nul^"b\");}") in
  expect (status=1 && contains stderr "embedded NUL") "embedded-NUL path was not rejected";
  let status,_,stderr=execute "fn main(){let mut f=open_write(\"/dev/full\");f.write(\"x\");}" in
  expect (status=1 && contains stderr "file write failed") "/dev/full write failure contract differs";
  let status,_,stderr=execute "fn main(){let mut f=open_read(\"/dev/null\");f.close();f.read();}" in
  expect (status=1 && contains stderr "test.xen:1:54" && contains stderr "File is closed") "closed File use contract differs";
  let large=Filename.temp_file "xen-file-large-" ".dat" in
  let oc=open_out_bin large in for _=1 to 20000 do output_string oc "0123456789" done;close_out oc;
  Fun.protect ~finally:(fun()->Sys.remove large) (fun()->
    let status,stdout,stderr=execute ("fn main(){let mut f=open_read("^xen_string large^");println(len(f.read()));}") in
    expect(status=0 && stderr="" && stdout="200000\n") "large File read differed")

let test_ptr_checker_and_execution () =
  let ast=Parser.parse ~file:"ptr.xen"
    "#![bb]\nfn relay(p:Ptr<Int>)->Ptr<Int>{return p;}\n#![bb]\nfn main(){let p=raw_alloc_int(1);raw_free_int(relay(p));}" in
  (match Result.map Semantic_ir.program (Checker.check ast) with
   | Ok {functions=({Semantic_ir.return_type=Ast.Ptr Ast.I64;_}::_);_} -> ()
   | Ok _ -> fail "Ptr<Int> was not preserved in lowered IR"
   | Error d -> fail "valid Ptr<Int> source rejected: %s" d.message);
  let refs=Parser.parse ~file:"ptr-ref.xen"
    "#![explc, bb]\nfn inspect(p:&Ptr<Int>,q:&mut Ptr<Int>){}\n#![bb]\nfn main(){}" in
  (match Checker.check refs with Ok _->()|Error d->fail "Ptr reference source rejected: %s" d.message);
  let bad_target=check_error "#![bb]\nfn bad(p:Ptr<String>){}fn main(){}" in
  expect(contains bad_target.message "not raw-safe POD") "unsupported Ptr target was accepted";
  let rejected=[
    ("fn bad(p:Ptr<Int>){}fn main(){}", "requires #![bb]");
    ("fn main(){raw_alloc_int(1);}", "requires #![bb]");
    ("#![bb]\nfn main(){let p=raw_alloc_int(1);println(p);}", "accepts Int");
    ("#![bb]\nfn main(){let p=raw_alloc_int(1);println(p==p);}", "equality");
    ("#![bb]\nfn main(){raw_load_int(1,0);}", "expected Ptr<Int>") ] in
  List.iter(fun(source,needle)->let d=check_error source in expect(contains d.message needle) "Ptr checker diagnostic differs")rejected;
  let source=
    "#![bb]\nfn relay(p:Ptr<Int>)->Ptr<Int>{return p;}\n"^
    "#![bb]\nfn peek(p:Ptr<Int>)->Int{return raw_load_int(p,1);}\n"^
    "#![bb]\nfn mixed(a:Int,b:Int,c:Int,d:Int,p:Ptr<Int>,f:Int)->Int{return a+b+c+d+f+raw_load_int(p,1);}\n"^
    "#![bb]\nfn main(){let p=raw_alloc_int(2);println(raw_load_int(p,0));raw_store_int(p,1,42);let q=relay(p);println(peek(q));println(raw_load_int(p,1));println(mixed(1,2,3,4,q,5));raw_free_int(q);let z=raw_alloc_int(0);raw_free_int(z);}" in
  let status,stdout,stderr=execute source in
  expect(status=0 && stdout="0\n42\n42\n57\n" && stderr="") "Ptr runtime or ABI behavior differs";
  List.iter(fun(source,message)->let status,_,stderr=execute source in
    expect(status=1 && contains stderr "test.xen:2:" && contains stderr message) "Ptr runtime failure contract differs") [
      ("#![bb]\nfn main(){raw_alloc_int(-1);}","count must be non-negative");
      ("#![bb]\nfn main(){raw_alloc_int(1152921504606846976);}","size overflow");
      ("#![bb]\nfn main(){raw_alloc_int(1152921504606846975);}","allocation failed");
      ("#![bb]\nfn main(){let p=raw_alloc_int(1);raw_load_int(p,-1);}","offset out of bounds");
      ("#![bb]\nfn main(){let p=raw_alloc_int(1);raw_store_int(p,1,2);}","offset out of bounds") ]

let test_named_structs () =
  let source =
    "struct Address { city: String, zip: Int }\n" ^
    "struct User { name: String, address: Address, score: Float, active: Bool }\n" ^
    "fn relay(user: User) -> User { return user; }\n" ^
    "fn choose(a: User, b: Int, c: Int, d: Int, e: Int, f: Int) -> User { return a; }\n" ^
    "fn main() { let mut original = User { active: true, score: 2.5, address: Address { zip: 7, city: \"Seoul\" }, name: \"Kim\" }; let copy = relay(original); let selected = choose(copy, 1, 2, 3, 4, 5); let address = selected.address; original.name = \"Lee\"; println(address.city); println(selected.name); println(original.name); println(address.zip); println(selected.score); println(selected.active); }" in
  let ast=Parser.parse ~file:"struct.xen" source in
  (match Result.map Semantic_ir.program (Checker.check ast) with
   | Ok {layouts=[address;user];_}->
       expect(address.size=32 && address.managed) "Address layout metadata differs";
       expect(user.size=72 && user.managed) "User nested layout metadata differs"
   | Ok _->fail "unexpected struct layout shape"|Error d->fail "valid struct rejected: %s" d.message);
  let status,stdout,stderr=execute source in
  if not(status=0 && stderr="" && stdout="Seoul\nKim\nLee\n7\n2.5\ntrue\n") then fail "named struct runtime/ABI/ownership behavior differs (%d): %S %S" status stdout stderr;
  List.iter(fun(source,needle)->let d=check_error source in expect(contains d.message needle) "struct diagnostic differs") [
    ("struct A { x: Missing } fn main(){}","unknown type");
    ("struct A { next: B } struct B { next: A } fn main(){}","recursive value layout");
    ("struct A { x: Int } fn main(){let a=A{};}","missing field");
    ("struct A { x: Int } fn main(){let a=A{x:1,y:2};}","unknown field");
    ("struct A { x: Int } fn main(){let a=A{x:1,x:2};}","duplicate literal field");
    ("struct A { x: Int } fn main(){let a=A{x:1};a.x=2;}","immutable");
    ("struct A { x: Int } fn main(){let a=A{x:1};println(a==a);}","struct equality") ]

let test_fixed_width_numeric_types () =
  let source =
    "struct Tiny{x:U8} struct Packed{a:U8,b:U64,c:U16,t:Tiny}\n"^
    "fn wrap(a:U8,b:U8)->U8{return a+b;} fn f(x:F32)->F32{return x*2.0;}\n"^
    "fn mix(a:I8,b:U16,c:I32,d:U64,e:F32,g:F64)->U64{println(a);println(b);println(c);println(e);println(g);return d;}\n"^
    "fn tiny(v:Tiny)->Tiny{return v;} fn packed(v:Packed)->Packed{return v;}\n"^
    "fn main(){let a:U8=255;println(wrap(a,2));let n:I16=-32768;println(n);"^
    "let top:U64=18446744073709551615;println(top);println(f(1.25));"^
    "println(u8(250)/u8(3));println(u8(250)%u8(3));println(u64(9223372036854775807)<top);"^
    "println(i16(f32(-12.75)));println(u64(f64(18446744073709549568)));"^
    "println(mix(-8,16,32,top,1.5,2.5));"^
    "let mut p=Packed{a:7,b:top,c:500,t:Tiny{x:9}};p.a=8;p.c=600;"^
    "println(p.a);println(p.b);println(p.c);println(p.t.x);println(tiny(Tiny{x:33}).x);println(packed(p).b);}" in
  let lowered=match Checker.check(Parser.parse ~file:"numbers.xen" source)with
    |Ok p->p|Error d->fail "fixed-width source rejected: %s" d.message in
  (match (Semantic_ir.program lowered).layouts with
   |[{size=1;alignment=1;_};{fields=[a;b;c;t];size=24;alignment=8;_}]->
       expect(a.offset=0&&b.offset=8&&c.offset=16&&t.offset=18) "fixed-width struct offsets differ"
   |_->fail "fixed-width struct layout metadata differs");
  let status,stdout,stderr=execute source in
  let expected="1\n-32768\n18446744073709551615\n2.5\n83\n1\ntrue\n-12\n18446744073709549568\n-8\n16\n32\n1.5\n2.5\n18446744073709551615\n8\n18446744073709551615\n600\n9\n33\n18446744073709551615\n" in
  expect(status=0&&stderr=""&&stdout=expected) "fixed-width arithmetic, ABI, print, or struct behavior differs";
  List.iter(fun(src,needle)->let d=check_error src in expect(contains d.message needle) "fixed-width static diagnostic differs") [
    ("fn main(){let x:U8=256;}","outside U8");
    ("fn main(){let x:U8=-1;}","negative literal");
    ("fn main(){u8(300);}","outside U8");
    ("fn main(){let a:I8=1;let b:I16=2;println(a+b);}","expected I8");
    ("fn main(){let x:U8=1;println(-x);}","signed integer");
    ("fn main(){let x:F32=1e39;}","outside F32") ];
  List.iter(fun(src,needle)->let status,_,stderr=execute src in
    expect(status=1&&contains stderr needle&&contains stderr "test.xen:1:") "checked conversion runtime diagnostic differs") [
    ("fn main(){let x:I64=300;println(u8(x));}","numeric conversion to U8 failed");
    ("fn main(){let x:F64=1e40;println(f32(x));}","numeric conversion to F32 failed");
    ("fn main(){let x:F64=0.0/0.0;println(i32(x));}","numeric conversion to I32 failed") ]

let test_modules_and_imports () =
  let root=Filename.temp_file "xen-modules-" "" in Sys.remove root;Unix.mkdir root 0o700;
  let util=Filename.concat root "util" and common=Filename.concat root "common" in
  Unix.mkdir util 0o700;Unix.mkdir common 0o700;
  let app=Filename.concat root "app.xen" and text=Filename.concat util "text.xen"
  and model=Filename.concat common "model.xen" in
  let write path contents=let out=open_out_bin path in output_string out contents;close_out out in
  Fun.protect ~finally:(fun()->List.iter(fun p->try Sys.remove p with Sys_error _->())[app;text;model];
    Unix.rmdir util;Unix.rmdir common;Unix.rmdir root) (fun()->
    write app "module app;\nimport util.text;\nimport common.model;\nfn main(){let b=common.model.Box{value:\"hello\"};let m=util.text.Message{box:b};util.text.show(m);let flag:common.model.Flag=common.model.Flag.On;println(match flag{common.model.Flag.On=>1,common.model.Flag.Off=>0});}\n";
    write text "module util.text;\nimport common.model;\nstruct Message{box:common.model.Box}\nfn show(m:Message){println(m.box.value);}\n";
    write model "module common.model;\nstruct Box{value:String}\nenum Flag{On,Off}\nfn show(){println(99);}\n";
    let programs=Project_loader.load app in
    expect(List.length programs=3) "recursive module graph was not loaded once";
    let lowered=match Checker.check_project ~entry_module:"app" programs with Ok p->p|Error d->fail "module checker rejected valid graph: %s" d.message in
    expect((Semantic_ir.program lowered).entry="app.main") "module entry identity differs";
    let executable=match Native_backend.generate lowered with Ok x->x|Error e->fail "module backend failed: %s" e.message in
    let elf=Filename.concat root "app" and stdout=Filename.concat root "stdout" in
    Native_backend.write elf executable;let fd=Unix.openfile stdout[Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC]0o600 in
    let pid=Unix.create_process elf[|elf|]Unix.stdin fd Unix.stderr in Unix.close fd;
    expect((match snd(Unix.waitpid[]pid)with Unix.WEXITED 0->true|_->false)&&read_file stdout="hello\n1\n") "module ELF output differs";
    Sys.remove elf;Sys.remove stdout;
    write app "module app;\nimport util.text;\nfn main(){let s=\"abcd\";let v=[1,2];println(util.text.borrow_len(s));println(util.text.raw_value());println(util.text.both(v));println(s);println(v);}\n";
    write text "module util.text;\n#global[explc,bb]\nfn borrow_len(s:String)->Int{let r=&s;return len(r);}\nfn raw_value()->Int{let p=raw_alloc_int(1);raw_store_int(p,0,42);let value=raw_load_int(p,0);raw_free_int(p);return value;}\nfn both(v:Vec<Int>)->Int{let r=&v;let p=raw_alloc_int(1);raw_store_int(p,0,len(r));let value=raw_load_int(p,0);raw_free_int(p);return value;}\n";
    let capability_programs=Project_loader.load app in
    let capability_lowered=match Checker.check_project ~entry_module:"app" capability_programs with
      |Ok p->p|Error d->fail "module capability encapsulation rejected: %s" d.message in
    (match List.find(fun(f:Semantic_ir.func)->f.name="app.main")(Semantic_ir.program capability_lowered).functions with
     |{mode_set=[];_}->()|_->fail "imported global capability propagated to caller IR");
    let executable=match Native_backend.generate capability_lowered with Ok x->x|Error e->fail "module capability backend failed: %s" e.message in
    Native_backend.write elf executable;let fd=Unix.openfile stdout[Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC]0o600 in
    let pid=Unix.create_process elf[|elf|]Unix.stdin fd Unix.stderr in Unix.close fd;
    expect((match snd(Unix.waitpid[]pid)with Unix.WEXITED 0->true|_->false)&&read_file stdout="4\n42\n2\nabcd\n[1, 2]\n")
      "module lexical capabilities or managed clone semantics differ";
    Sys.remove elf;Sys.remove stdout;
    write app "module app;\nimport util.text;\nfn main(){common.model.show();}\n";
    let ps=Project_loader.load app in
    (match Checker.check_project ~entry_module:"app" ps with
     | Error d->expect(contains d.message "unknown local" || contains d.message "not directly imported") "transitive import diagnostic differs"
     | Ok _->fail "transitive import access was accepted");
    write app "module app;\nimport missing.file;\nfn main(){}\n";
    (try ignore(Project_loader.load app);fail "missing import was accepted" with
     | Project_loader.Error(span,message)->expect(span.file=app && contains message "not found") "missing import diagnostic differs");
    write app "module app;\nimport util.text;\nfn main(){}\n";
    write text "module util.wrong;\nfn show(){}\n";
    (try ignore(Project_loader.load app);fail "module/path mismatch was accepted" with
     | Project_loader.Error(span,message)->expect(span.file=text && contains message "does not match") "module mismatch diagnostic differs");
    write text "module util.text;\nimport app;\nfn show(){}\n";
    (try ignore(Project_loader.load app);fail "import cycle was accepted" with
     | Project_loader.Error(span,message)->expect(span.file=text && contains message "cycle") "cycle diagnostic differs"))

let test_qualified_generic_imports () =
  let root=Filename.temp_file "xen-qualified-generics-" "" in
  Sys.remove root;Unix.mkdir root 0o700;
  let app=Filename.concat root "app.xen" and ext=Filename.concat root "opt_ext.xen"
  and elf=Filename.concat root "app" and stdout=Filename.concat root "stdout" in
  let write path contents=let out=open_out_bin path in output_string out contents;close_out out in
  Fun.protect ~finally:(fun()->
    List.iter(fun p->try Sys.remove p with Sys_error _->())[app;ext;elf;stdout];Unix.rmdir root)(fun()->
    write ext "module opt_ext;\nfn zip<T,U>(left:T,right:U)->Int{return 42;}\nstruct SquareMap<I>{iterator:I}\n";
    write app "module app;\nimport opt_ext;\nfn main(){let zipped=opt_ext.zip<Int,Int>(1,2);let mapped=opt_ext.SquareMap<Int>{iterator:zipped};println(mapped.iterator);}\n";
    let programs=Project_loader.load app in
    let lowered=match Checker.check_project ~entry_module:"app" programs with
      |Ok p->p|Error d->fail "qualified generic import was rejected: %s" d.message in
    let executable=match Native_backend.generate lowered with
      |Ok x->x|Error e->fail "qualified generic import backend failed: %s" e.message in
    Native_backend.write elf executable;
    let fd=Unix.openfile stdout[Unix.O_WRONLY;Unix.O_CREAT;Unix.O_TRUNC]0o600 in
    let pid=Unix.create_process elf[|elf|]Unix.stdin fd Unix.stderr in Unix.close fd;
    let status=match snd(Unix.waitpid[]pid)with Unix.WEXITED n->n| _ -> -1 in
    expect(status=0&&read_file stdout="42\n") "qualified generic call or aggregate literal failed")

let test_generics_enums_and_match () =
  let source=
    "fn identity<T>(value:T)->T{return value;}\n"^
    "struct Pair<T,U>{first:T,second:U}\n"^
    "fn main(){let pair=Pair<I32,String>{first:7,second:\"x\"};"^
    "let option=Option.Some(pair);let text=match option{"^
    "Option.Some(value)=>value.second,Option.None=>\"none\"};"^
    "println(text);println(identity(9));println(identity<I32>(8));"^
    "let result:Result<I64,String>=Result.Err(\"bad\");"^
    "println(match result{Result.Ok(value)=>value,Result.Err(error)=>0});"^
    "let tuple=identity((1,\"tuple\"));println(1);}" in
  let status,stdout,stderr=execute source in
  expect(status=0&&stderr=""&&stdout="x\n9\n8\n0\n1\n") "generic/enum/match execution differs";
  List.iter(fun(src,needle)->let d=check_error src in expect(contains d.message needle) "stage-three diagnostic differs") [
    ("fn f<T>(x:T)->T{return x+x;}fn main(){println(f(1));}","concrete type");
    ("fn main(){let x=Option.Some(1);println(match x{Option.Some(v)=>v});}","non-exhaustive");
    ("fn main(){let x=Option.Some(1);println(match x{_=>0,Option.Some(v)=>v});}","unreachable");
    ("enum Option<T>{Other(T)} fn main(){}","reserved") ]

let test_generic_body_contract () =
  let declarations =
    "fn id<T>(x:T)->T{return x;}struct Pair<T>{value:T,count:Int}fn test_inc(x:Int)->Int{return x+1;}" in
  let invalid = [
    "fn bad<T>(x:T)->T{let y=x;return y+1;}";
    "fn bad<T>(x:T)->Int{let y:Int=x;return y;}";
    "fn bad<T>(x:T)->T{return id<T>(x)+1;}";
    "fn bad<T>(x:T)->T{return id(x)+1;}";
    "fn bad<T>(x:T)->Int{return id<Int>(x);}";
    "fn bad<T>(x:T,cb:fn(T)->T)->T{return cb(x)+1;}";
    "fn bad<T>(x:T)->T{{let x:Int=1;}return x+1;}";
    "fn bad<T>(x:T)->T{if true{let x:Int=1;}return x+1;}";
    "fn bad<T>(x:(T,Int))->T{return x.0+1;}";
    "fn bad<T>(x:T)->T{return (if true{x}else{x})+1;}";
    "fn bad<T>(x:Option<T>)->T{return match x{Option.Some(y)=>y+1,Option.None=>{panic(\"none\");}};}";
    "fn bad<T>(x:T)->Bool{return match x{1=>true,_=>false};}";
    "fn bad<T>(x:Option<T>)->Bool{return match x{Option.Some(1)=>true,_=>false};}";
    "fn bad<T>(x:T)->Bool{return x==x;}";
    "fn bad<T>(x:Vec<T>)->Bool{return x==x;}";
    "fn bad<T>(x:T)->T{let y=(x,1);return y.0+1;}";
    "fn bad<T>(x:Pair<T>)->T{return x.value+1;}";
    "fn bad<T>(x:Result<T,Int>)->Result<T,Int>{let y=x?;return Result.Ok(y+1);}";
    "fn bad<T>(x:T)->Int{return len(x);}";
    "fn bad<T>(x:T)->Int{return i64(x);}";
    "fn bad<T>(x:T){println(x);}";
    "fn bad<T>(x:T)->Int{return box<Int>(x).into_inner();}";
    "fn bad<T>(x:T)->Int{return *x;}";
    "fn bad<T>(x:T)->Int{return x.count;}";
    "fn bad<T>(x:T)->Result<Int,Int>{let y=x?;return Result.Ok(y+1);}";
    "fn bad<T>(x:Vec<T>)->T{return match x.get(0){v=>v+1};}";
    "fn bad<T>(x:T)->T{let y=match true{true=>x,false=>1};return y;}";
    "fn concrete(x:Int)->Int{return x;}fn bad<T>(x:T)->Int{return concrete(x);}";
  ] in
  List.iter(fun body->
    let argument=if contains body "x:Option<T>"then "Option<Int>.Some(1)"
      else if contains body "x:Result<T,Int>"then "Result<Int,Int>.Ok(1)"
      else if contains body "x:Pair<T>"then "Pair<Int>{value:1,count:0}"
      else if contains body "x:(T,Int)"then "(1,0)"
      else if contains body "x:Vec<T>"then "[1]"else "1"in
    let entry="fn main(){bad<Int>("^argument^(if contains body "cb:fn"then ",test_inc"else "")^");}"in
    List.iter(fun entry->
    let d=check_error(declarations^body^entry)in
    expect(contains d.message "concrete type" || contains d.message "unconstrained")
      "generic restriction lost through a binding, projection, call or scope";
    expect(d.span.file="test.xen"&&d.span.line>0&&d.span.column>0)
      "generic restriction lost its source span") ["fn main(){}";entry])invalid;
  let source=declarations^
    "fn unwrap_or<T>(x:Option<T>,fallback:T)->T{return match x{Option.Some(v)=>v,Option.None=>fallback};}"^
    "fn count<T>(x:Pair<T>)->Int{let y=x.count;return y+1;}"^
    "fn apply<T>(x:T,cb:fn(T)->T)->T{let y=cb(x);return y;}"^
    "fn inc(x:Int)->Int{return x+1;}"^
    "fn first<T>(x:(T,Int))->T{return match x{(v,_)=>v};}"^
    "fn restored<T>(x:T)->T{{let x:Int=2;println(x+1);}return x;}"^
    "fn propagate<T,E>(x:Result<T,E>)->Result<T,E>{let y=x?;return Result.Ok(y);}"^
    "fn main(){println(unwrap_or(Option<Int>.Some(7),9));"^
    "println(unwrap_or(Option<String>.None,\"fallback\"));"^
    "println(unwrap_or(Option<Box<Int>>.Some(box(7)),box(9)).into_inner());"^
    "println(count<String>(Pair<String>{value:\"v\",count:3}));println(apply(4,inc));"^
    "println(first<Int>((6,0)));println(restored(8));"^
    "println(match propagate<Int,String>(Result.Ok(9)){Result.Ok(v)=>v,Result.Err(_)=>0});}" in
  let status,out,err=execute source in
  expect(status=0&&out="7\nfallback\n7\n4\n5\n6\n3\n8\n9\n"&&err="")
    "valid symbolic generic operations were rejected or changed";
  let status,out,err=execute_with_fd_limit 32
    ("fn unwrap_or<T>(x:Option<T>,fallback:T)->T{return match x{Option.Some(v)=>v,Option.None=>fallback};}"^
     "fn main(){for pass in 0..96{"^
     "{let file=unwrap_or<File>(Option<File>.Some(open_read(\"/dev/null\")),open_read(\"/dev/null\"));assert(file.is_open());}"^
     "{let file=unwrap_or<File>(Option<File>.None,open_read(\"/dev/null\"));assert(file.is_open());}"^
     "}println(\"closed\");}")in
  expect(status=0&&out="closed\n"&&err="")"generic match leaked selected or unused File payloads";
  List.iter(fun(declaration,entry)->List.iter(fun entry->
    let d=check_error(declaration^entry)in
    expect(contains d.message "concrete type"||contains d.message "unconstrained")
      "generic builtin or error-type restriction was bypassed") ["fn main(){}";entry]) [
    "use core.box;fn bad<T>(x:T)->Int{return core.box.new<Int>(x).into_inner();}","fn main(){bad<Int>(1);}";
    "fn bad<T,E>(x:Result<T,E>)->Result<T,Int>{let value=x?;return Result.Ok(value);}",
      "fn main(){bad<Int,Int>(Result<Int,Int>.Ok(1));}";
    "#global[bb]\nfn bad<T>(p:Ptr<T>){raw_store<Int>(p,0,1);}",
      "fn main(){let p=raw_alloc<Int>(1);bad<Int>(p);raw_free(p);}";
    "#global[bb]\nfn bad<T>(p:Ptr<T>)->Int{return raw_load_int(p,0);}",
      "fn main(){let p=raw_alloc<Int>(1);raw_store(p,0,1);bad<Int>(p);raw_free(p);}";
    "use std.iter;fn bad<T>(x:Vec<T>)->T{for item in x.iter(){return item+1;}panic(\"empty\");}",
      "fn main(){bad<Int>([1]);}";
    "fn bad<T>(x:T)->Int{return *x;}","fn main(){bad<Box<Int>>(box(1));}";
    "fn size(x:String)->Int{return 7;}fn bad<T>(x:T,len:fn(T)->Int)->Int{return len(x);}",
      "fn main(){bad<String>(\"x\",size);}";
    "fn seven(x:Int)->Int{return 7;}fn bad<T>(x:T,i64:fn(T)->Int)->Int{return i64(x);}",
      "fn main(){bad<Int>(1,seven);}";
    "fn text(x:Int)->String{return \"x\";}fn bad<T>(x:T,int_to_str:fn(T)->String)->String{return int_to_str(x);}",
      "fn main(){bad<Int>(1,text);}";
    "#global[bb]\nfn zero(p:Ptr<Int>,i:Int)->Int{return 0;}fn bad<T>(p:Ptr<T>,raw_load_int:fn(Ptr<T>,Int)->Int)->Int{return raw_load_int(p,0);}",
      "fn main(){let p=raw_alloc<Int>(1);raw_store(p,0,1);bad<Int>(p,zero);raw_free(p);}";
  ];
  let status,out,err=execute
    ("use std.convert;use core.box;"^
     "fn qualified<T>(parse_int:T,new:T)->Int{let value=std.convert.parse_int(\"1\");"^
     "let owned=core.box.new<Int>(2);return owned.into_inner()+match value{Result.Ok(n)=>n,Result.Err(_)=>0};}"^
     "struct Holder<T>{f:fn(T)->T}fn callback<T>(x:T,h:Holder<T>)->T{return h.f(x);}"^
     "struct Invoke<T>{value:T}impl<T> Invoke<T>{fn call(&self,cb:fn(T)->T)->T{return cb(self.value);}}"^
     "fn keep_error(x:std.convert.ParseIntError)->std.convert.ParseIntError{return x;}"^
     "fn inc(x:Int)->Int{return x+1;}fn pair<T>(x:T)->(I32,T){return (1,x);}"^
     "fn negative_pair<T>(x:T)->(I32,T){return (-1,x);}fn arithmetic_pair<T>(x:T)->(I32,T){return (1+2,x);}"^
     "fn float_pair<T>(x:T)->(T,F32){return (x,-1.0);}fn builtin_count<T>(arg_count:T)->Int{return arg_count();}"^
     "struct Wrap<I>{iter:I}impl<I> Wrap<I>{fn next(&mut self)->Option<Int>{return self.iter.next();}}"^
     "struct Pairs{done:Bool}impl Pairs{fn next(&mut self)->Option<(Int,Bool)>"^
     "{if self.done{return Option.None;}self.done=true;return Option.Some((9,true));}}"^
     "struct TupleWrap<I>{iter:I}impl<I> TupleWrap<I>{fn next(&mut self)->Option<(Int,Bool)>{return self.iter.next();}}"^
     "fn main(){println(qualified(0,0));println(qualified(inc,inc));println(callback<Int>(3,Holder<Int>{f:inc}));"^
     "let pair=pair(7);println(pair.0);println(pair.1);for n in Wrap{iter:0..3}{println(n);}"^
     "let negative=negative_pair(7);let arithmetic=arithmetic_pair(7);println(negative.0);println(arithmetic.0);"^
     "let floating=float_pair(7);println(floating.1);println(builtin_count(0));"^
     "let invoke=Invoke<std.convert.ParseIntError>{value:std.convert.ParseIntError.Empty};"^
     "println(match invoke.call(keep_error){std.convert.ParseIntError.Empty=>10,_=>0});"^
     "for (n,_) in TupleWrap{iter:Pairs{done:false}}{println(n);}}")in
  expect(status=0&&out="3\n3\n4\n1\n7\n0\n1\n2\n-1\n3\n-1.0\n0\n10\n9\n"&&err="")
    "qualified calls, callback fields, contextual tuple or structural item wrappers changed";
  let status,out,err=execute
    ("#global[bb]\nfn put<T>(p:Ptr<T>,x:T)->T{raw_store<T>(p,0,x);return raw_load<T>(p,0);}"^
     "fn owned<T>(x:T)->Box<T>{return box<T>(x);}fn main(){let p=raw_alloc<I32>(1);"^
     "println(put<I32>(p,7));raw_free<I32>(p);println(owned(8).into_inner());}")in
  expect(status=0&&out="7\n8\n"&&err="")"valid symbolic builtin signatures changed";
  List.iter(fun next->let d=check_error(
    "struct Wrong{n:Int}impl Wrong{"^next^"}"^
    "fn call<I>(x:I){x.next();}fn main(){call(Wrong{n:0});}")in
    expect(contains d.message "next(&mut self) -> Option") "invalid structural next signature accepted") [
      "fn next(&self)->Int{return 1;}";
      "fn next(&self)->Option<Int>{return Option.Some(1);}";
      "fn next(&mut self,n:Int)->Option<Int>{return Option.Some(n);}"]

let test_recursive_enum_layouts () =
  let cases = [
    "enum IntTree{Leaf,Node((IntTree,IntTree))}fn main(){let tree=IntTree.Leaf;}", "IntTree";
    "enum Tree<T>{Leaf,Node((Tree<T>,Tree<T>))}fn main(){let tree:Tree<I64>=Tree.Leaf;}", "Tree<I64>";
    "enum Unused{Done,Next(Unused)}fn main(){}", "Unused";
    "enum Left{End,Next(Right)}enum Right{End,Next(Left)}fn main(){}", "Left";
    "struct Box{value:Mixed}enum Mixed{Empty,Full(Box)}fn main(){}", "Box";
    "enum Growing<T>{End,Next(Growing<(T,T)>)}fn main(){let value:Growing<I64>=Growing.End;}", "Growing";
  ] in
  List.iter(fun(source,name)->
    let diagnostic=check_error source in
    expect(contains diagnostic.message "recursive value layout involving") "recursive enum layout diagnostic differs";
    expect(contains diagnostic.message name) "recursive enum layout diagnostic omitted the type";
    expect(diagnostic.span.file="test.xen" && diagnostic.span.line>0 && diagnostic.span.column>0)
      "recursive enum layout diagnostic omitted its source span")cases

let test_generic_argument_inference () =
  let declarations=
    "fn id<T>(x:T)->T{return x;}fn forward<T>(x:T)->T{return id(x);}"^
    "fn first<A,B>(a:A,b:B)->A{return a;}fn same<T>(a:T,b:T)->T{return a;}"^
    "fn contextual<T>(x:T,y:Option<I32>)->T{return x;}"^
    "fn from_option<T>(x:Option<T>,y:T)->T{return y;}"^
    "fn number()->I32{return 5;}struct Item{value:I32}"^
    "impl Item{fn get(&self)->I32{return self.value;}}" in
  let source=declarations^
    "fn main(){let x:I64=42;let y:String=\"hello\";"^
    "println(id(x));println(id<I64>(x));println(first(x,y));println(y);"^
    "println(id(id(i32(3))));println(id(id<I32>(4)));println(forward(number()));"^
    "println(same(i32(6),i32(7)));let alias:Int=8;println(same(alias,i64(9)));"^
    "let narrow:I32=id<I32>(10);println(narrow);println(contextual(11,Option.None));"^
    "println(from_option(Option.None,i32(12)));"^
    "let values=[i32(13),i32(14)];println(id(values[0]));println(id(values.get(1)));"^
    "println(id(values.len()));let copied=id(values);println(copied[0]);"^
    "let nested=id([id(i32(15))]);println(nested[0]);"^
    "let tuple=id((id(i32(16)),\"tuple\"));println(tuple.0);println(tuple.1);"^
    "let item=Item{value:17};println(id(item).value);println(id(item.get()));"^
    "let f=id(number);println(f());let mut file=id(open_read(\"/dev/null\"));"^
    "println(file.is_open());file.close();println(id(box(i32(18))).into_inner());}" in
  let status,out,err=execute source in
  if status<>0||err<>""||out<>"42\n42\n42\nhello\n3\n4\n5\n6\n8\n10\n11\n12\n13\n14\n2\n13\n15\n16\ntuple\n17\n17\n5\ntrue\n18\n" then
    fail "argument inference execution differs: status=%d stdout=%S stderr=%S"status out err;
  let create="fn create<T>()->T{panic(\"unused\");}" in
  List.iter(fun body->let d=check_error(create^"fn main(){"^body^"}") in
    expect(contains d.message "cannot infer type parameter 'T'") "return context inferred a generic parameter";
    expect(d.help=Some "specify all type arguments explicitly, for example: create<I64>()")
      "missing inference did not suggest an explicit call";
    expect(d.span.file="test.xen"&&d.span.line>0&&d.span.column>0) "inference diagnostic lost its span") [
      "let value=create();";"let value:I64=create();"];
  let unused=check_error "fn phantom<T,U>(x:T)->T{return x;}fn main(){phantom(i32(1));}" in
  expect(contains unused.message "cannot infer type parameter 'U'") "unused type parameter was guessed";
  expect(unused.help=Some "specify all type arguments explicitly, for example: phantom<I32, I64>(...)")
    "explicit call help omitted known or missing type arguments";
  List.iter(fun body->let d=check_error(declarations^"fn main(){"^body^"}") in
    expect(contains d.message "conflicting inference for type parameter 'T': I32 and I64")
      "conflicting argument types were converted or did not identify both types") [
      "same(i32(1),i64(2));";"same(i32(1),2);";"let value:I32=same(i32(1),2);"];
  List.iter(fun body->let d=check_error(declarations^"fn main(){"^body^"}") in
    expect(contains d.message "cannot infer type parameter 'T'") "ambiguous argument was guessed";
    expect(d.help<>None) "ambiguous call did not request explicit type arguments") [
      "let value:Option<I32>=id(Option.None);";"let value:Vec<I32>=id([]);"];
  List.iter(fun body->let d=check_error(declarations^"fn main(){"^body^"}") in
    expect(contains d.message "expected") "return context changed the inferred argument type") [
      "let value:I32=id(1);";"let values:Vec<Option<I8>>=id([Option.Some(13)]);"];
  let partial=check_error(declarations^"fn main(){first<I64>(1,\"x\");}") in
  expect(contains partial.message "expects 2 type arguments") "partial type arguments were accepted";
  let explicit=check_error(declarations^"fn main(){id<I32>(\"x\");}") in
  expect(contains explicit.message "expected I32"&&explicit.help=None) "explicit call did not use ordinary type checking";
  let program=Parser.parse ~file:"instances.xen"
    "fn id<T>(x:T)->T{return x;}fn main(){id(1);id<I64>(2);id<Int>(3);}" in
  let program=match Monomorph.run program with Ok p->p|Error d->fail "%s" d.message in
  expect(List.length(List.filter(fun(f:Ast.func)->f.name="id<I64>")program.functions)=1)
    "inferred and explicit calls did not reuse the same concrete instance";
  let status,out,err=execute
    ("struct Pair<T>{value:T}fn id<T>(x:T)->T{return x;}"^
     "fn wrap<T>(x:T)->Pair<T>{return id(Pair<T>{value:x});}"^
     "fn boxed<T>(x:T)->Box<T>{return id(box<T>(x));}"^
     "fn descend<T>(x:T)->T{if false{return id(descend(x));}return x;}"^
     "fn main(){println(id(Pair{value:19}).value);println(wrap(i32(20)).value);"^
     "println(boxed(i32(21)).into_inner());println(descend(i32(22)));}") in
  expect(status=0&&out="19\n20\n21\n22\n"&&err="")
    "direct inference used an aggregate template or a recursive template signature";
  let status,out,err=execute
    ("#global[bb]\nfn id<T>(x:T)->T{return x;}fn main(){let p=raw_alloc<I32>(1);"^
     "raw_store(p,0,i32(23));let same=id(p);println(id(raw_load(same,0)));"^
     "println(id(raw_load<I32>(same,0)));raw_free(same);}") in
  expect(status=0&&out="23\n23\n"&&err="") "direct inference lost raw builtin static types"

let test_unused_generic_struct_fields () =
  let unused =
    "struct Box<T>{value:T}" ^
    "enum Wrap<T>{Empty,Full(T)}" ^
    "struct Indirect{value:Box<Int>}" ^
    "struct Holder{option:Option<Int>,result:Result<Int,String>,user:Box<Int>,choice:Wrap<String>,indirect:Indirect,nested:Box<Box<Int>>,safe:Vec<Box<Int>>}" ^
    "fn main(){}" in
  let ast=Parser.parse ~file:"unused-generic-fields.xen" unused in
  let with_prelude=match Checker.add_prelude ast with
    | Ok program->program|Error d->fail "prelude rejected unused generic fields: %s" d.message in
  let monomorph=match Monomorph.run with_prelude with
    | Ok program->program|Error d->fail "monomorph rejected unused generic fields: %s" d.message in
  let holder=List.find(fun(d:Ast.struct_decl)->d.struct_name="Holder")monomorph.structs in
  let field name=(List.find(fun(f:Ast.struct_field)->f.field_name=name)holder.fields).field_type in
  expect(field "option"=Ast.Named "Option<I64>") "unused Option field was not made concrete";
  expect(field "result"=Ast.Named "Result<I64,String>") "unused Result field was not made concrete";
  expect(field "nested"=Ast.Named "Box<Box<I64>>") "nested generic field was not made concrete";
  List.iter(fun name->
    if not(List.exists(fun(d:Ast.struct_decl)->d.struct_name=name)monomorph.structs)then
      fail "missing generated aggregate %s" name)["Box<I64>";"Box<Box<I64>>";"Option<I64>";"Result<I64,String>"];
  (match Result.map Semantic_ir.program (Checker.check ast) with Ok _->()|Error d->fail "checker rejected unused generic fields: %s" d.message);
  let runtime=
    "struct Box<T>{value:T}struct Holder{value:Box<Box<String>>}" ^
    "fn main(){let h=Holder{value:Box<Box<String>>{value:Box<String>{value:\"managed\"}}};println(h.value.value.value);}" in
  let status,out,err=execute runtime in
  expect(status=0&&out="managed\n"&&err="") "generic field layout or managed lifecycle differs";
  List.iter(fun(source,needle)->
    let d=check_error source in
    expect(contains d.message needle) "generic struct field diagnostic differs";
    expect(d.span.file="test.xen"&&d.span.line>0&&d.span.column>0) "generic struct field diagnostic omitted its source span") [
    "struct Box<T>{value:T}struct Bad{value:Box<Int,String>}fn main(){}", "expects 1 type arguments";
    "struct Bad{value:Missing<Int>}fn main(){}", "unknown generic aggregate";
    "struct Box<T>{value:T}struct Loop{value:Box<Loop>}fn main(){}", "recursive value layout";
  ];
  List.iter(fun source->
    let raw=Parser.parse ~file:"raw-layout.xen" source in
    match Checker.check_internal ~entry:"main" raw with
    | Error d->
        expect(contains d.message "unresolved struct field type") "raw layout unresolved-type diagnostic differs";
        expect(d.span.file="raw-layout.xen"&&d.span.line>0&&d.span.column>0) "raw layout diagnostic omitted its source span"
    | Ok _->fail "raw layout accepted an unresolved struct field type") [
    "struct Box<T>{value:T}struct Bad{value:Box<Int>}fn main(){}";
    "struct Box<T>{value:T}struct Bad{value:Vec<Box<Int>>}fn main(){}";
    "struct Bad<T>{value:T}fn main(){}";
  ]

let test_match_binary_arm_result_type () =
  let source=
    "fn main(){let option=Option.Some(1);"^
    "let number=match option{Option.Some(value)=>1+1,Option.None=>0};"^
    "if number==2{println(number);}"^
    "let text=match option{Option.Some(value)=>\"yes\"+\"!\",Option.None=>\"no\"};"^
    "println(text);}" in
  let status,stdout,stderr=execute source in
  expect(status=0&&stderr=""&&stdout="2\nyes!\n")
    "binary match arm result type was not preserved"

let test_contextual_enums_and_if_chains () =
  let source=
    "fn take(x:Option<I32>)->Option<I32>{return x;}"^
    "fn id<T>(x:T)->T{return x;}"^
    "fn none()->Option<I32>{return Option.None;}"^
    "fn main(){"^
    "let a:Option<I32>=Option.None;let b=take(Option.None);"^
    "let c=id<Option<I32>>(Option.None);let d:Option<I32>=id<Option<I32>>(Option.None);"^
    "let m:Option<I32>=match true{true=>Option.None,false=>Option.Some(2)};"^
    "let n:Option<I32>=match false{true=>Option.Some(3),false=>Option.None};"^
    "let inferred=match true{true=>Option.None,false=>Option.Some(6)};"^
    "let x=if false{1}else if true{2}else{3};"^
    "let text=if true{\"yes\"}else{\"no\"};"^
    "let e:Option<I32>=if false{Option.None}else{Option.Some(4)};"^
    "let inferred_if=if true{Option.None}else{Option.Some(7)};"^
    "if false{println(0);}else if x==2{println(x);}else{println(9);}"^
    "if false{println(0);}else if false{println(0);}"^
    "println(text);println(match none(){Option.None=>i32(5),Option.Some(v)=>v});"^
    "println(match e{Option.Some(v)=>v,Option.None=>0});"^
    "println(match inferred{Option.Some(v)=>v,Option.None=>6});"^
    "println(match inferred_if{Option.Some(v)=>v,Option.None=>7});}" in
  let status,stdout,stderr=execute source in
  expect(status=0&&stderr=""&&stdout="2\nyes\n5\n4\n6\n7\n") "contextual enum or if-chain execution differs";
  let d=check_error "fn main(){let x=if true{1}else{\"x\"};}" in
  expect(contains d.message "expected Int") "if expression result mismatch diagnostic differs";
  let moved=check_error "fn main(){let mut a=open_read(\"/dev/null\");let b=open_read(\"/dev/null\");let f=if true{a}else{b};a.close();}" in
  expect(contains moved.message "moved") "if expression ownership branches were not merged";
  List.iter(fun(src,needle)->let _,message=syntax_error src in expect(contains message needle) "if expression syntax diagnostic differs") [
    ("fn main(){let x=if true{1};}","final else");
    ("fn main(){let x=if true{}else{1};}","must contain an expression");
    ("fn main(){let x=if true{let y=1;}else{1};}","single expression") ]

let test_contextual_enum_collections () =
  let tree_decl="enum Tree<T>{Leaf(T),Branch(Vec<Tree<T>>)}\n" in
  let sum_decl=
    "fn sum(tree:Tree<Int>)->Int{return match tree{"^
    "Tree.Leaf(n)=>n,Tree.Branch(xs)=>{let mut total=0;let mut i=0;"^
    "while i<xs.len(){total=total+sum(xs[i]);i=i+1;}total}};}\n" in
  let cases=[
    "direct", "let x:Tree<Int>=Tree.Leaf(1);println(sum(x));", "1\n";
    "collection", "let xs:Vec<Tree<Int>>=[Tree.Leaf(1),Tree.Leaf(2)];println(sum(xs[0])+sum(xs[1]));", "3\n";
    "recursive", "let x:Tree<Int>=Tree.Branch([Tree.Leaf(1)]);println(sum(x));", "1\n";
    "deep recursive", "let x:Tree<Int>=Tree.Branch([Tree.Leaf(3),Tree.Branch([Tree.Leaf(4),Tree.Leaf(5)])]);println(sum(x));", "12\n";
    "explicit control", "let x:Tree<Int>=Tree<Int>.Branch([Tree<Int>.Leaf(3),Tree<Int>.Branch([Tree<Int>.Leaf(4),Tree<Int>.Leaf(5)])]);println(sum(x));", "12\n";
    "explicit outer context", "let x=Tree<Int>.Branch([Tree.Leaf(3),Tree.Branch([Tree.Leaf(4)])]);println(sum(x));", "7\n";
    "typed local control", "let leaf:Tree<Int>=Tree.Leaf(3);let children:Vec<Tree<Int>>=[leaf];let x:Tree<Int>=Tree.Branch(children);println(sum(x));", "3\n";
    "nested vectors", "let xs:Vec<Vec<Tree<Int>>>=[[Tree.Leaf(1)],[Tree.Branch([Tree.Leaf(2)])],[]];println(sum(xs[0][0])+sum(xs[1][0]));println(xs[2].len());", "3\n0\n";
    "contextual empty payload", "let x:Tree<Int>=Tree.Branch([]);println(sum(x));", "0\n";
    "payload inference control", "let x=Tree.Leaf(6);println(sum(x));", "6\n";
  ] in
  List.iter(fun(name,body,output)->
    let status,stdout,stderr=execute(tree_decl^sum_decl^"fn main(){"^body^"}") in
    if not(status=0&&stderr=""&&stdout=output)then fail "contextual enum collection failed: %s" name)cases;
  (* Keep contextual and explicit forms equivalent as Vec/if nesting grows. *)
  for depth=0 to 5 do
    List.iter(fun explicit->
      let owner=if explicit then "Tree<Int>" else "Tree" in
      let rec expression n=if n=0 then owner^".Leaf(7)" else
        owner^".Branch([if true{"^expression(n-1)^"}else{"^owner^".Leaf(0)}])" in
      let status,stdout,stderr=execute(tree_decl^sum_decl^
        "fn main(){let x:Tree<Int>="^expression depth^";println(sum(x));}") in
      expect(status=0&&stderr=""&&stdout="7\n") "nested contextual/explicit enum forms differ")
      [false;true]
  done;
  let status,stdout,stderr=execute(tree_decl^
    "fn leaf(tree:Tree<I32>)->I32{return match tree{Tree.Leaf(n)=>n,Tree.Branch(_)=>0};}"^
    "fn first(tree:Tree<I32>)->I32{return match tree{Tree.Leaf(n)=>n,Tree.Branch(children)=>leaf(children[0])};}"^
    "fn main(){let xs:Vec<Vec<Tree<I32>>>=[[Tree.Branch([Tree.Leaf(17),Tree.Branch([])])]];"^
    "println(first(xs[0][0]));}") in
  expect(status=0&&stderr=""&&stdout="17\n") "nested enum/vector context did not constrain numeric payloads to I32";
  let status,stdout,stderr=execute
    ("fn value(x:Option<I8>)->I8{return match x{Option.Some(n)=>n,Option.None=>0};}"^
     "fn trees()->Vec<Option<I8>>{return [Option.Some(127),Option.None];}"^
     "fn take(xs:Vec<Option<I8>>){println(value(xs[0]));}"^
     "fn id<T>(x:T)->T{return x;}fn main(){take([Option.Some(12)]);"^
     "let xs:Vec<Option<I8>>=id<Vec<Option<I8>>>([Option.Some(13)]);"^
     "println(value(xs[0]));take(trees());}") in
  expect(status=0&&stderr=""&&stdout="12\n13\n127\n") "enum collection call/return or numeric context was lost";
  let status,stdout,stderr=execute
    ("fn show(x:Result<I32,String>){match x{Result.Ok(n)=>{println(n);},Result.Err(s)=>{println(s);}}}"^
     "fn main(){let xs:Vec<Result<I32,String>>=[Result.Ok(1),Result.Err(\"x\")];show(xs[0]);show(xs[1]);}") in
  expect(status=0&&stderr=""&&stdout="1\nx\n") "collection context did not propagate both enum type arguments";
  List.iter(fun source->
    let d=check_error source in
    expect(contains d.message "cannot infer type parameter") "unconstrained enum constructor was guessed";
    expect(d.span.file="test.xen"&&d.span.line>0) "enum inference error lost its source span") [
    "fn main(){let x=Option.None;}";
    tree_decl^"fn main(){let x=Tree.Branch([]);}";
    "enum Phantom<T>{Tag(Int)}fn main(){let x=Phantom.Tag(1);}";
    "fn main(){let x:Vec<Int>=[Option.None];}";
    "enum Two<A,B>{Empty}fn main(){let x:Option<Int>=Two.Empty;}";
    "enum Other<T>{Empty}fn main(){let x:Other<Int>=Option.None;}";
    "enum Other<A,B>{Empty}fn main(){let anchor:Other<Int,String>=Other.Empty;let x:Other<Int,String>=Option.None;}";
  ];
  let mismatch=check_error "fn main(){let xs:Vec<Option<Int>>=[Option<String>.Some(\"x\")];}" in
  expect(contains mismatch.message "expected Option<I64>, found Option<String>") "explicit enum type mismatch diagnostic differs";
  let range=check_error "fn main(){let xs:Vec<Option<I8>>=[Option.Some(128)];}" in
  expect(contains range.message "outside I8 range") "enum collection numeric context did not enforce I8 range"

let test_structural_match_patterns () =
  let source=
    "fn main(){"^
    "let nested=Option.Some((true,(1,\"ok\")));"^
    "println(match nested{Option.Some((true,(1,text)))=>text,Option.Some((true,(_,text)))=>text,Option.Some((false,pair))=>\"false\",Option.None=>\"none\"});"^
    "println(match (true,false){(true,false)=>1,(true,true)=>2,(false,_)=>3});"^
    "let b=false;println(match b{true=>1,false=>0});"^
    "let n:I8=i8(7);println(match n{7=>7,_=>0});"^
    "let f:F32=f32(1.5);println(match f{1.5=>1,_=>0});"^
    "let s=\"x\";println(match s{\"x\"=>1,_=>0});}" in
  let status,stdout,stderr=execute source in
  expect(status=0&&stderr=""&&stdout="ok\n1\n0\n7\n1\n1\n") "structural match execution differs";
  List.iter(fun(src,needle)->let d=check_error src in expect(contains d.message needle) "structural match diagnostic differs") [
    ("fn main(){println(match (1,2){(a,a)=>a});}","duplicate pattern binding");
    ("fn main(){println(match (1,2){(a,b,c)=>a});}","tuple pattern expects 2");
    ("fn main(){println(match true{1=>1,_=>0});}","literal pattern does not have type Bool");
    ("fn main(){println(match 1{1=>1});}","non-exhaustive");
    ("fn main(){println(match true{_=>1,true=>2});}","unreachable");
    ("fn main(){println(match true{});}","at least one arm") ];
  let file_source=
    "fn main(){let option=Option.Some(open_read(\"/dev/null\"));"^
    "let mut file=match option{Option.Some(file)=>file,Option.None=>open_read(\"/dev/null\")};file.close();"^
    "let none:Option<File>=Option.None;let mut other=match none{Option.Some(file)=>file,Option.None=>open_read(\"/dev/null\")};other.close();}" in
  let status,_,stderr=execute file_source in
  expect(status=0&&stderr="") "move-only enum payload match failed";
  let d=check_error("fn main(){let x=Option.Some(open_read(\"/dev/null\"));let f=match x{Option.Some(f)=>f,Option.None=>open_read(\"/dev/null\")};println(match x{Option.Some(_)=>1,Option.None=>0});}")in
  expect(contains d.message "moved") "move-only match did not consume its scrutinee"

let examples_root () =
  let candidates = ["examples"; Filename.concat ".." "examples"] in
  match List.find_opt (fun root -> Sys.file_exists (Filename.concat root "native_core.xen")) candidates with
  | Some root -> root
  | None -> fail "examples directory is not available to the test"

let check_example path =
  let programs = Project_loader.load path in
  let lowered = match programs with
    | [program] when program.Ast.imports = [] -> Checker.check program
    | entry :: _ ->
        let name = match entry.Ast.module_decl with Some (name, _) -> name | None -> assert false in
        Checker.check_project ~entry_module:name programs
    | [] -> assert false
  in
  match lowered with
  | Ok program -> program
  | Error diagnostic ->
      fail "example %s was rejected at line %d: %s" path diagnostic.span.line diagnostic.message

let execute_example path arguments =
  let lowered = check_example path in
  let executable = match Native_backend.generate lowered with
    | Ok executable -> executable
    | Error error -> fail "example backend rejected %s: %s" path error.message
  in
  let elf = Filename.temp_file "xen-example-test-" ".elf" in
  let stdout_path = Filename.temp_file "xen-example-test-" ".stdout" in
  let stderr_path = Filename.temp_file "xen-example-test-" ".stderr" in
  Fun.protect ~finally:(fun () -> Sys.remove elf; Sys.remove stdout_path; Sys.remove stderr_path) (fun () ->
    Native_backend.write elf executable;
    let stdout_fd = Unix.openfile stdout_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let stderr_fd = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let pid = Unix.create_process elf (Array.of_list (elf :: arguments)) Unix.stdin stdout_fd stderr_fd in
    Unix.close stdout_fd; Unix.close stderr_fd;
    let status = match snd (Unix.waitpid [] pid) with Unix.WEXITED value -> value | _ -> -1 in
    status, read_file stdout_path, read_file stderr_path)

let execute_example_to_stdout path arguments stdout_target =
  let lowered = check_example path in
  let executable = match Native_backend.generate lowered with
    | Ok executable -> executable
    | Error error -> fail "example backend rejected %s: %s" path error.message
  in
  let elf = Filename.temp_file "xen-example-test-" ".elf" in
  let stderr_path = Filename.temp_file "xen-example-test-" ".stderr" in
  Fun.protect ~finally:(fun () -> Sys.remove elf; Sys.remove stderr_path) (fun () ->
    Native_backend.write elf executable;
    let stdout_fd = Unix.openfile stdout_target [Unix.O_WRONLY] 0o600 in
    let stderr_fd = Unix.openfile stderr_path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
    let pid = Unix.create_process elf (Array.of_list (elf :: arguments)) Unix.stdin stdout_fd stderr_fd in
    Unix.close stdout_fd; Unix.close stderr_fd;
    let status = match snd (Unix.waitpid [] pid) with Unix.WEXITED value -> value | _ -> -1 in
    status, read_file stderr_path)

let test_example_suite () =
  let root = examples_root () in
  let runnable = [
    "native_core.xen", "10\n11\n13\n14\n-7\n";
    "basics.xen", "120\n2.5\n7\npositive\n";
    "strings_and_vectors.xen", "hello, Xen\n3\n[11, 20]\n20\n[1.5, 3.5]\n3.5\n1\n1.5\n";
    "structs_and_generics.xen", "Mina\nSeoul\n7\n";
    "enums_and_match.xen", "enabled 7\nvalue=9\nrecoverable error\n";
    "recursive_ast.xen", "10\n7\n9\n";
    "ownership_and_references.xen", "[1, 2]\nmoved once\nmoved once\n7\n7\n";
    "raw_memory_bb.xen", "42\nOK\n7\n";
    Filename.concat "modules" "app.xen", "Mina: admin\n";
  ] in
  List.iter (fun (relative, expected_stdout) ->
    let path = Filename.concat root relative in
    let status, stdout, stderr = execute_example path [] in
    if status <> 0 || stdout <> expected_stdout || stderr <> "" then
      fail "example %s execution differs: status=%d stdout=%S stderr=%S"
        relative status stdout stderr) runnable;
  let temporary_path = Filename.temp_file "xen-file-example-" ".txt" in
  Fun.protect ~finally:(fun () -> try Sys.remove temporary_path with Sys_error _ -> ()) (fun () ->
    let path = Filename.concat root "file_lifecycle.xen" in
    let status, stdout, stderr = execute_example path [temporary_path] in
    expect (status = 0 && stdout = "temporary Xen file\n" && stderr = "")
      "File lifecycle example execution differs";
    expect (read_file temporary_path = "temporary Xen file\n")
      "File lifecycle example did not write the argument path")

let test_error_examples () =
  let root = Filename.concat (examples_root ()) "errors" in
  let cases = [
    "non_exhaustive_match.xen", "non-exhaustive match";
    "unreachable_match.xen", "unreachable pattern";
    "invalid_enum_payload.xen", "enum variant payload expects one value";
    "duplicate_pattern_binding.xen", "duplicate pattern binding";
    "generic_type_operation.xen", "operation requires a concrete type";
    "recursive_enum_layout.xen", "recursive value layout involving";
    "recursive_struct_layout.xen", "recursive value layout involving";
    "use_after_move.xen", "use of moved File";
    "borrow_conflict.xen", "while it is borrowed";
    "raw_memory_outside_bb.xen", "requires #![bb]";
    "implicit_numeric_conversion.xen", "expected I8";
    "untyped_empty_vec.xen", "cannot infer";
    "immutable_vec_receiver.xen", "mutable local";
  ] in
  List.iter (fun (name, expected) ->
    let path = Filename.concat root name in
    let message =
      try
        let programs = Project_loader.load path in
        match programs with
        | [program] -> (match Checker.check program with
            | Error diagnostic -> diagnostic.message
            | Ok _ -> fail "error example %s unexpectedly compiled" name)
        | _ -> fail "error example %s unexpectedly loaded modules" name
      with
      | Lexer.Error (_, message) | Parser.Error (_, message) -> message
      | Project_loader.Error (_, message) -> message
    in
    if not (contains message expected) then
      fail "error example %s diagnostic differs: %s" name message) cases

let test_typed_raw_memory_and_syscalls () =
  let scalars="#![bb]\nfn main(){let a=raw_alloc<I8>(1);raw_store(a,0,i8(-8));println(raw_load(a,0));raw_free(a);let b=raw_alloc<U8>(1);raw_store(b,0,u8(8));println(raw_load(b,0));raw_free(b);let c=raw_alloc<I16>(1);raw_store(c,0,i16(-16));println(raw_load(c,0));raw_free(c);let d=raw_alloc<U16>(1);raw_store(d,0,u16(16));println(raw_load(d,0));raw_free(d);let e=raw_alloc<I32>(1);raw_store(e,0,i32(-32));println(raw_load(e,0));raw_free(e);let f=raw_alloc<U32>(1);raw_store(f,0,u32(32));println(raw_load(f,0));raw_free(f);let g=raw_alloc<I64>(1);raw_store(g,0,64);println(raw_load(g,0));raw_free(g);let h=raw_alloc<U64>(1);raw_store(h,0,u64(65));println(raw_load(h,0));raw_free(h);let i=raw_alloc<F32>(1);raw_store(i,0,f32(1.5));println(raw_load(i,0));raw_free(i);let j=raw_alloc<F64>(1);raw_store(j,0,2.5);println(raw_load(j,0));raw_free(j);let k=raw_alloc<Bool>(1);raw_store(k,0,true);println(raw_load(k,0));raw_free(k);let l=raw_alloc<Int>(1);raw_store(l,0,66);println(raw_load(l,0));raw_free(l);let m=raw_alloc<Float>(1);raw_store(m,0,3.5);println(raw_load(m,0));raw_free(m);}" in
  let status,out,err=execute scalars in
  if status<>0||out<>"-8\n8\n-16\n16\n-32\n32\n64\n65\n1.5\n2.5\ntrue\n66\n3.5\n"||err<>""then
    fail "typed scalar raw memory execution differs: status=%d stdout=%S stderr=%S" status out err;
  let source =
    "struct Padded{tag:U8,value:I64}\nstruct Nested{flag:Bool,item:Padded}\nstruct Box<T>{value:T}\n#![bb]\nfn main(){let bytes=raw_alloc<U8>(3);println(raw_load(bytes,0));raw_store(bytes,0,u8(79));raw_store(bytes,1,u8(75));raw_store(bytes,2,u8(10));syscall3(1,1,ptr_addr(bytes),3);let p=raw_alloc<Padded>(2);raw_store(p,1,Padded{tag:u8(7),value:42});println(raw_load(p,1).tag);println(raw_load<Padded>(p,1).value);let n=raw_alloc<Nested>(1);raw_store(n,0,Nested{flag:true,item:Padded{tag:u8(1),value:9}});println(raw_load(n,0).item.value);let b=raw_alloc<Box<F32>>(1);raw_store(b,0,Box<F32>{value:f32(2.5)});println(raw_load(b,0).value);assert(syscall0(39)>0);let address=syscall6(9,0,4096,3,34,-1,0);assert(address>0);println(syscall2(11,address,4096));raw_free(b);raw_free(n);raw_free(p);raw_free(bytes);}" in
  let status,out,err=execute source in
  if status<>0||out<>"0\nOK\n7\n42\n9\n2.5\n0\n"||err<>"" then
    fail "typed raw memory/syscall execution differs: status=%d stdout=%S stderr=%S" status out err;
  List.iter(fun(source,needle)->let status,_,stderr=execute source in
    if status<>1||not(contains stderr needle)then fail "typed raw runtime diagnostic differs: %S" stderr)[
    ("struct P{a:U8,b:I64}\n#![bb]\nfn main(){raw_alloc<P>(576460752303423488);}","size overflow");
    ("#![bb]\nfn main(){raw_alloc<U8>(-1);}","count must be non-negative")];
  List.iter(fun(source,needle)->let d=check_error source in if not(contains d.message needle)then
    fail "typed raw diagnostic differs: %s" d.message)[
    ("#![bb]\nfn main(){raw_alloc<String>(1);}","not raw-safe POD");
    ("#![bb]\nfn main(){let p=raw_alloc<U8>(1);raw_load<I8>(p,0);}","expected U8, found I8");
    ("fn main(){syscall0(39);}","requires #![bb]");
    ("#![bb]\nfn main(){raw_alloc(1);}","explicit type argument");
    ("#![bb]\nfn bad(p:Ptr<String>){}fn main(){}","not raw-safe POD")]

let test_inherent_methods_and_pointer_aggregates () =
  let source =
    "struct Counter{value:Int}\n" ^
    "impl Counter{fn get(&self)->Int{return self.value;}fn add(&mut self, n:Int){self.value=self.value+n;}}\n" ^
    "struct Box<T>{value:T}\nimpl<T> Box<T>{fn get(&self)->T{return self.value;}}\n" ^
    "fn main(){let mut c=Counter{value:2};c.add(3);println(c.get());let b=Box<Int>{value:9};println(b.get());}" in
  let status,out,err=execute source in
  if status<>0||out<>"5\n9\n"||err<>"" then
    fail "inherent method execution differs: status=%d stdout=%S stderr=%S" status out err;
  let immutable=check_error
    "struct C{x:Int}impl C{fn set(&mut self){self.x=1;}}fn main(){let c=C{x:0};c.set();}" in
  expect(contains immutable.message "mutable method receiver") "immutable method receiver diagnostic differs";
  let duplicate=check_error "struct C{x:Int}impl C{fn x(self){}fn x(self){}}fn main(){}" in
  expect(contains duplicate.message "duplicate function") "duplicate method diagnostic differs";
  let wrapped =
    "struct Raw{p:Ptr<Int>}\n#![bb]\nfn make()->Raw{return Raw{p:raw_alloc<Int>(1)};}\n" ^
    "#![bb]\nfn take(r:Raw){}#![bb]\nfn main(){let r=make();take(r);}" in
  ignore(compile wrapped);
  ()

let test_structural_for () =
  let source=
    "struct CounterRange{current:Int,finish:Int}\n" ^
    "impl CounterRange{fn next(&mut self)->Option<Int>{if self.current<self.finish{let value=self.current;self.current=self.current+1;return Option<Int>.Some(value);}return Option<Int>.None;}}\n" ^
    "fn main(){let iterator=CounterRange{current:0,finish:5};for value in iterator{if value==1{continue;}println(value);if value==3{break;}}}" in
  let status,out,err=execute source in
  if status<>0||out<>"0\n2\n3\n"||err<>"" then
    fail "structural for execution differs: status=%d stdout=%S stderr=%S" status out err

let test_int_range_for () =
  let source =
    "fn endpoint(label:String,value:Int)->Int{print(label);return value;}" ^
    "fn main(){for i in endpoint(\"L\",1)..endpoint(\"R\",4){println(i);}" ^
    "for i in 3..3{println(99);}for i in 4..2{println(98);}" ^
    "for i in 0..3{for j in 0..3{if j==1{continue;}if i==2{break;}print(i);println(j);}}" ^
    "for i in 9223372036854775806..9223372036854775807{println(i);}}" in
  let status,out,err=execute source in
  let expected="LR1\n2\n3\n00\n02\n10\n12\n9223372036854775806\n" in
  if status<>0||out<>expected||err<>"" then
    fail "Int range execution differs: status=%d stdout=%S stderr=%S" status out err;
  List.iter(fun(source,needle)->let d=check_error source in
    if not(contains d.message needle)then fail "range diagnostic differs: %s" d.message)[
    ("fn main(){for i in 0.0..2.0{println(i);}}","expected Int (I64), found Float (F64)");
    ("fn main(){let n:U8=u8(2);for i in n..n{println(i);}}","expected Int (I64), found U8")];
  let chained =
    try ignore(Parser.parse ~file:"<test>" "fn main(){for i in 0..1..2{}}" );fail "chained range parsed"
    with Parser.Error(_,message)->message in
  expect(contains chained "chained range") "chained range diagnostic differs"

let test_string_byte_bridge () =
  let source="fn main(){let text=\"A\\n\";let bytes=text.as_bytes();println(bytes.len());println(bytes.get(0));let data:Vec<U8>=[u8(65),u8(0),u8(255)];let raw=data.into_string();println(raw.len());}" in
  let status,out,err=execute source in
  if status<>0||out<>"2\n65\n3\n"||err<>"" then
    fail "String byte bridge execution differs: status=%d stdout=%S stderr=%S" status out err;
  let consumed=check_error "fn main(){let data:Vec<U8>=[u8(1)];let text=data.into_string();println(data.len());}" in
  expect(contains consumed.message "moved") "consumed Vec<U8> reuse diagnostic differs"

let test_std_env_and_string () =
  let env_source =
    "module env_test;use std.env;use std.iter;fn main(){let values=std.env.args();" ^
    "println(values.len());for value in values.iter(){let bytes=value.as_bytes();println(bytes.len());" ^
    "if bytes.len()>0{println(bytes.get(0));}}}" in
  let status,out,err=execute_args env_source [""; String.make 1 '\255' ^ "x"; "last"] in
  if status<>0||out<>"3\n0\n2\n255\n4\n108\n"||err<>"" then
    fail "std.env argument preservation differs: status=%d stdout=%S stderr=%S" status out err;
  let no_args =
    "module env_empty;use std.env;fn main(){println(std.env.args().len());}" in
  let status,out,err=execute no_args in
  if status<>0||out<>"0\n"||err<>"" then
    fail "std.env empty argument list differs: status=%d stdout=%S stderr=%S" status out err;
  let string_source =
    "module string_test;use std.iter;use std.string;fn dump(text:String){" ^
    "let tokens=std.string.split_ascii_whitespace(text);println(tokens.len());" ^
    "for token in tokens.iter(){let bytes=token.as_bytes();println(bytes.len());" ^
    "for index in 0..bytes.len(){println(bytes.get(index));}}}" ^
    "fn main(){println(std.string.is_ascii_whitespace(u8(9)));" ^
    "println(std.string.is_ascii_whitespace(u8(13)));println(std.string.is_ascii_whitespace(u8(32)));" ^
    "println(std.string.is_ascii_whitespace(u8(0)));dump(\"\");" ^
    "let extra:Vec<U8>=[u8(11),u8(12)];dump(\" \\t\\n\\r\"+extra.into_string());" ^
    "let binary:Vec<U8>=[u8(0),u8(128),u8(32),u8(255)];dump(binary.into_string());}" in
  let status,out,err=execute string_source in
  let expected="true\ntrue\ntrue\nfalse\n0\n0\n2\n2\n0\n128\n1\n255\n" in
  if status<>0||out<>expected||err<>"" then
    fail "std.string ASCII byte tokenization differs: status=%d stdout=%S stderr=%S" status out err;
  let long_source =
    "module string_long;use std.iter;use std.string;fn main(){let mut bytes:Vec<U8>=[];" ^
    "for i in 0..10000{let mut byte:U8=u8(i%256);if i%101==0{byte=u8(32);}" ^
    "bytes.push(byte);}" ^
    "let tokens=std.string.split_ascii_whitespace(bytes.into_string());" ^
    "let mut total=0;for token in tokens.iter(){total=total+token.as_bytes().len();}" ^
    "println(total);}" in
  let status,out,err=execute long_source in
  let preserved = ref 0 in
  for i=0 to 9999 do
    let byte=if i mod 101=0 then 32 else i mod 256 in
    if not((byte>=9&&byte<=13)||byte=32)then incr preserved
  done;
  let expected=string_of_int !preserved^"\n" in
  if status<>0||out<>expected||err<>"" then
    fail "std.string long tokenization differs: status=%d stdout=%S stderr=%S" status out err

let test_toolchain_modules () =
  let path=Filename.temp_file "xen-root-contract-" ".xen"in
  Fun.protect ~finally:(fun()->Sys.remove path)(fun()->
    let channel=open_out path in output_string channel "use core.intrinsics;fn main(){}";close_out channel;
    expect(List.length(Project_loader.load ~root:"/" path)=2) "absolute filesystem project root rejected an in-root entry");
  let ast=Parser.parse ~file:"uses.xen" "use std.fs; import util.model; use core.intrinsics; fn main(){}" in
  expect(List.map(fun d->d.Ast.import_origin)ast.imports=[Ast.Toolchain;Ast.Project;Ast.Toolchain])
    "parser lost dependency origins";
  expect((List.hd ast.imports).import_span.column=1) "use declaration lost source span";
  let _,duplicate=syntax_error "use std.fs; use std.fs; fn main(){}" in
  expect(contains duplicate "duplicate module dependency") "duplicate use was accepted";
  let status,stdout,_=execute
    ("use core.intrinsics; struct P{byte:U8,word:I64} "^
     "struct Box<T>{value:T} fn size<T>()->Int{return core.intrinsics.size_of<T>();}"^
     "fn main(){println(size<Int>());println(core.intrinsics.size_of<P>());"^
     "println(core.intrinsics.align_of<P>());println(size<Box<U8>>());"^
     "println(size<(U8,I64)>());println(size<Option<Int>>());"^
     "println(size<Result<Int,String>>());println(size<Unit>());}") in
  expect(status=0 && stdout="8\n16\n8\n1\n16\n16\n40\n0\n") "core layout query execution differs";
  List.iter(fun source->let d=check_error source in
    expect(contains d.message "type argument" && d.span.line=2) "intrinsic arity diagnostic differs")
    ["use core.intrinsics;\nfn main(){core.intrinsics.size_of();}";
     "use core.intrinsics;\nfn main(){core.intrinsics.size_of<Int,Int>();}";
     "use core.intrinsics;\nfn main(){core.intrinsics.size_of<Int>(1);}"];
  List.iter(fun(typ,message)->let d=check_error
      ("use core.intrinsics;\nfn main(){core.intrinsics.size_of<"^typ^">();}")in
    expect(d.span.line=2 && contains d.message message) "intrinsic type diagnostic differs")
    ["Missing","unknown type";"Ptr<String>","raw-safe POD"];
  let d=check_error "use std.string; fn main(){let xs=[1];xs.iter();}" in
  expect(contains d.message "use std.iter") "transitive stdlib iterator dependency became directly visible"

let test_bundled_std_import () =
  let root=Filename.temp_file "xen-stdlib-import-" "" in
  Sys.remove root;Unix.mkdir root 0o700;let app=Filename.concat root "app.xen" in
  let module_name="app" in
  let out=open_out_bin app in output_string out ("module "^module_name^";\nuse std.iter;\nfn main(){}\n");close_out out;
  Fun.protect ~finally:(fun()->Sys.remove app;Unix.rmdir root)(fun()->
    let programs=Project_loader.load app in
    expect(List.length programs=2) "bundled std.iter was not loaded";
    match Checker.check_project ~entry_module:module_name programs with
    | Ok _->()|Error d->fail "bundled std.iter rejected: %s" d.message)

let test_std_convert_and_sum_file () =
  let source =
    "module convert_test; use std.convert; " ^
    "fn describe(text:String)->String{return match std.convert.parse_int(text){" ^
    "Result.Ok(value)=>\"ok:\"+std.convert.format_int(value)," ^
    "Result.Err(error)=>match error{" ^
    "std.convert.ParseIntError.Empty=>\"empty\"," ^
    "std.convert.ParseIntError.InvalidDigit((index,byte))=>\"digit:\"+std.convert.format_int(index)+\":\"+std.convert.format_int(i64(byte))," ^
    "std.convert.ParseIntError.Overflow=>\"overflow\"}};}" ^
    "fn main(){println(std.convert.format_int(0));" ^
    "println(std.convert.format_int(9223372036854775807));" ^
    "println(std.convert.format_int(-9223372036854775808));" ^
    "println(describe(\"0\"));println(describe(\"+17\"));println(describe(\"-001\"));" ^
    "println(describe(\"\"));println(describe(\"+\"));println(describe(\"12x\"));" ^
    "println(describe(\"9223372036854775808\"));println(describe(\"-9223372036854775809\"));}" in
  let status,out,err=execute source in
  let expected=
    "0\n9223372036854775807\n-9223372036854775808\n" ^
    "ok:0\nok:17\nok:-1\nempty\nempty\ndigit:2:120\noverflow\noverflow\n" in
  if status<>0 || out<>expected || err<>"" then
    fail "std.convert boundary execution differs: status=%d stdout=%S stderr=%S" status out err;
  let input=Filename.temp_file "xen-sum-file-" ".txt" in
  Fun.protect ~finally:(fun()->if Sys.file_exists input then Sys.remove input)(fun()->
    let write contents=let channel=open_out_bin input in output_string channel contents;close_out channel in
    let sum_path=Filename.concat (examples_root ()) "sum_file.xen" in
    write "  10\t-3\r\n+5  ";
    let status,out,err=execute_example sum_path [input] in
    if status<>0 || out<>"12\n" || err<>"" then
      fail "sum_file valid execution differs: status=%d stdout=%S stderr=%S" status out err;
    write "";
    let status,out,err=execute_example sum_path [input] in
    if status<>0 || out<>"0\n" || err<>"" then
      fail "sum_file empty execution differs: status=%d stdout=%S stderr=%S" status out err;
    write "1 2x 3";
    let status,out,err=execute_example sum_path [input] in
    if status<>1 || out<>"" || not(contains err "invalid integer token 1 at byte 1 (value 120)") then
      fail "sum_file invalid digit failure differs: status=%d stdout=%S stderr=%S" status out err;
    write "1 9223372036854775808 2";
    let status,out,err=execute_example sum_path [input] in
    if status<>1 || out<>"" || not(contains err "integer overflow at token 1") then
      fail "sum_file parse failure differs: status=%d stdout=%S stderr=%S" status out err;
    Sys.remove input;
    let status,out,err=execute_example sum_path [input] in
    if status<>1 || out<>"" || not(contains err "open failed (errno 2)") then
      fail "sum_file missing-file recovery differs: status=%d stdout=%S stderr=%S" status out err;
    List.iter (fun arguments ->
      let status,out,err=execute_example sum_path arguments in
      if status<>1||out<>""||not(contains err "usage: sum_file <path>")then
        fail "sum_file usage differs: status=%d stdout=%S stderr=%S" status out err) [[];[input;input]];
    if Sys.file_exists "/dev/full" then begin
      write "1 2";
      let status,err=execute_example_to_stdout sum_path [input] "/dev/full" in
      if status<>1||not(contains err "write failed (errno 28)")then
        fail "sum_file stdout failure differs: status=%d stderr=%S" status err
    end)

let test_std_fs_io_and_copy_file () =
  let source=Filename.temp_file "xen-copy-source-" ".bin" in
  let destination=Filename.temp_file "xen-copy-destination-" ".bin" in
  let bytes=Bytes.init 9001(fun i->Char.chr((i*37)land 255))|>Bytes.to_string in
  let write path contents=let channel=open_out_bin path in output_string channel contents;close_out channel in
  write source bytes;write destination "old trailing bytes";
  let copy_path=Filename.concat(examples_root())"copy_file.xen" in
  Fun.protect ~finally:(fun()->List.iter(fun p->if Sys.file_exists p then Sys.remove p)[source;destination]) (fun()->
    let status,out,err=execute_example copy_path [source;destination] in
    if status<>0||out<>"copied 9001 bytes\n"||err<>"" then
      fail "copy_file success differs: status=%d stdout=%S stderr=%S" status out err;
    let channel=open_in_bin destination in
    let copied=really_input_string channel(in_channel_length channel)in close_in channel;
    expect(copied=bytes)"copy_file did not preserve binary bytes";
    Sys.remove source;
    let status,out,err=execute_example copy_path [source;destination] in
    if status<>1||out<>""||not(contains err "open failed (errno 2)")then
      fail "copy_file missing source differs: status=%d stdout=%S stderr=%S" status out err;
    if Sys.file_exists "/dev/full" then begin
      write source "x";
      let status,out,err=execute_example copy_path [source;"/dev/full"] in
      if status<>1||out<>""||not(contains err "write failed (errno 28)")then
        fail "copy_file /dev/full differs: status=%d stdout=%S stderr=%S" status out err
    end;
    List.iter(fun arguments->
      let status,out,err=execute_example copy_path arguments in
      if status<>1||out<>""||not(contains err "usage: copy_file <source> <destination>")then
        fail "copy_file usage differs: status=%d stdout=%S stderr=%S" status out err)[[];[source]];
    if Sys.file_exists "/dev/full" then begin
      write source "x";
      let status,err=execute_example_to_stdout copy_path [source;destination] "/dev/full" in
      if status<>1||not(contains err "write failed (errno 28)")then
        fail "copy_file stdout failure differs: status=%d stderr=%S" status err
    end);
  let root=Filename.temp_file "xen-io-probe-" "" in
  Sys.remove root;Unix.mkdir root 0o700;
  let probe=Filename.concat root "io_probe.xen" in
  let channel=open_out_bin probe in
  output_string channel
    ("module io_probe;use std.fs;use std.io;" ^
     "fn count(r:Result<Int,std.io.IoError>)->Int{return match r{Result.Ok(n)=>n,Result.Err(_)=>-1};}" ^
     "fn describe(r:Result<String,std.io.IoError>)->String{return match r{" ^
     "Result.Ok(_)=>\"unexpected\",Result.Err(e)=>std.io.describe_error(e)};}" ^
     "fn main(){println(count(std.io.write_stderr(\"ERR\")));println(describe(std.fs.read(\"bad\000path\")));}");
  close_out channel;
  Fun.protect ~finally:(fun()->Sys.remove probe;Unix.rmdir root)(fun()->
    let status,out,err=execute_example probe [] in
    if status<>0||out<>"3\ninvalid path: embedded NUL byte\n"||err<>"ERR"then
      fail "std.io stderr/NUL path differs: status=%d stdout=%S stderr=%S" status out err)

let test_word_count () =
  let input=Filename.temp_file "xen-word-count-" ".bin" in
  let path=Filename.concat(examples_root())"word_count.xen" in
  let write contents=let channel=open_out_bin input in output_string channel contents;close_out channel in
  Fun.protect ~finally:(fun()->if Sys.file_exists input then Sys.remove input)(fun()->
    write (" one\t"^String.make 1 '\000'^"two\nthree "^String.make 1 '\255');
    let status,out,err=execute_example path [input] in
    if status<>0||out<>"4\n"||err<>""then
      fail "word_count success differs: status=%d stdout=%S stderr=%S" status out err;
    List.iter(fun arguments->let status,out,err=execute_example path arguments in
      if status<>1||out<>""||not(contains err "usage: word_count <path>")then
        fail "word_count usage differs: status=%d stdout=%S stderr=%S" status out err)[[];[input;input]];
    Sys.remove input;
    let status,out,err=execute_example path [input] in
    if status<>1||out<>""||not(contains err "open failed (errno 2)")then
      fail "word_count missing file differs: status=%d stdout=%S stderr=%S" status out err;
    if Sys.file_exists "/dev/full" then begin
      write "one two";
      let status,err=execute_example_to_stdout path [input] "/dev/full" in
      if status<>1||not(contains err "write failed (errno 28)")then
        fail "word_count stdout failure differs: status=%d stderr=%S" status err
    end)

let test_std_iterator_factories () =
  let source =
    "module iterator_app;\nuse std.iter;\n" ^
    "fn main(){let values:Vec<Int>=[3,5,8];" ^
    "for (index,value) in values.iter().enumerate(){println(index);println(value);}" ^
    "let slice:Slice<Int>=values.as_slice();for value in slice.iter(){println(value);}" ^
    "let text=\"Aé\";for byte in text.iter(){println(byte);}}" in
  let status,out,err=execute source in
  if status<>0||out<>"0\n3\n1\n5\n2\n8\n3\n5\n8\n65\n195\n169\n"||err<>"" then
    fail "stdlib iterator execution differs: status=%d stdout=%S stderr=%S" status out err;
  let pointer =
    "module pointer_iterator;\nuse std.iter;\n#![bb]\n" ^
    "fn main(){let p:Ptr<Int>=raw_alloc<Int>(3);raw_store(p,0,4);raw_store(p,1,6);raw_store(p,2,9);" ^
    "for value in p.iter(){println(value);}raw_free(p);}" in
  let status,out,err=execute pointer in
  if status<>0||out<>"4\n6\n9\n"||err<>"" then
    fail "Ptr iterator execution differs: status=%d stdout=%S stderr=%S" status out err;
  let managed =
    "module managed_iterator; use std.iter; struct Item{name:String} " ^
    "fn main(){let words:Vec<String>=[\"a\",\"b\"];for word in words.iter(){println(word);}" ^
    "let items:Vec<Item>=[Item{name:\"c\"}];for item in items.iter(){println(item.name);}}" in
  let status,out,err=execute managed in
  if status<>0||out<>"a\nb\nc\n"||err<>"" then
    fail "managed stdlib iterator execution differs: status=%d stdout=%S stderr=%S" status out err;
  let missing=check_error "fn main(){let values:Vec<Int>=[1];for value in values.iter(){println(value);}}" in
  expect(contains missing.message "use std.iter") "missing std.iter import diagnostic differs";
  let move_only=check_error
    "module move_only_iterator; use std.iter; fn main(){let values:Vec<File>=[];values.iter();}" in
  expect(contains move_only.message "into_iter()") "move-only iterator diagnostic differs";
  let consumed=check_error
    "module consumed_iterator; use std.iter; struct R{n:Int} impl R{fn next(&mut self)->Option<Int>{return Option<Int>.None;}} fn main(){let r=R{n:0};let e=r.enumerate();println(r.n);}" in
  expect(contains consumed.message "moved") "enumerate source consumption diagnostic differs"

let test_std_iter_fold () =
  let prefix = "use std.iter; struct Counter{n:Int,end:Int} impl Counter{fn next(&mut self)->Option<Int>{if self.n==self.end{return Option<Int>.None;}let n=self.n;self.n=self.n+1;return Option<Int>.Some(n);}} " in
  let status,out,err=execute(prefix ^
    "fn step(a:Int,b:Int)->Int{return a*10+b;} fn main(){println(std.iter.fold(Counter{n:1,end:4},0,step));println(std.iter.fold(Counter{n:0,end:0},7,step));}")in
  expect(status=0&&out="123\n7\n"&&err="") "fold order or empty accumulator differs";
  let status,out,err=execute(prefix ^
    "fn step(a:Box<Int>,b:Int)->Box<Int>{return box(a.into_inner()+b);}fn main(){let total=std.iter.fold(Counter{n:1,end:4},box(0),step);println(total.into_inner());}")in
  expect(status=0&&out="6\n"&&err="") "fold move-only accumulator differs";
  let bad=check_error(prefix ^
    "fn step(a:Int,b:Int)->Bool{return true;}fn main(){std.iter.fold<Counter,Int,Int>(Counter{n:0,end:1},0,step);}")in
  expect(contains bad.message "expected") "fold callback mismatch was not rejected";
  let bad=check_error "use std.iter;struct R{n:Int}impl R{fn next(&self)->Option<Int>{return Option.None;}}fn step(a:Int,b:Int)->Int{return a+b;}fn main(){std.iter.fold(R{n:0},0,step);}"in
  expect(contains bad.message "next(&mut self)") "fold shared next receiver was accepted";
  let bad=check_error "use std.iter;struct R{n:Int}impl R{fn next(&mut self)->Option<Bool>{return Option.None;}}fn step(a:Int,b:Int)->Int{return a+b;}fn main(){std.iter.fold(R{n:0},0,step);}"in
  expect(contains bad.message "expected") "fold concrete item mismatch was accepted"

let test_semantic_expansion_places () =
  let status,out,err=execute
    "use std.mem;struct Inner{pair:(String,Box<Int>)}struct Outer{inner:Inner}#![explc]\nfn edit(x:&mut Outer){x.inner.pair.0=\"changed\";}#![explc]\nfn main(){let mut x=Outer{inner:Inner{pair:(\"old\",box(1))}};x.inner.pair.0=\"nested\";println(x.inner.pair.0);let first=x.inner.pair.1;x.inner.pair.1=box(2);println(first.into_inner());edit(&mut x);println(x.inner.pair.0);let mut xs:Vec<Box<Int>>=[box(3),box(4)];xs.swap(0,1);xs.swap(1,1);let old=xs.replace(0,box(5));println(old.into_inner());println(xs.pop().into_inner());let mut b=box(6);let previous=std.mem.replace(&mut b,box(7));println(previous.into_inner());println(b.into_inner());}"in
  expect(status=0&&out="nested\n1\nchanged\n4\n3\n6\n7\n"&&err="") "nested Place or owned exchange differs";
  let borrowed=check_error
    "struct Inner{n:Int}struct Outer{inner:Inner}#![explc]\nfn main(){let mut x=Outer{inner:Inner{n:1}};let r=&x;x.inner.n=2;println(r.inner.n);}"in
  expect(contains borrowed.message "borrowed") "nested parent loan conflict was accepted";
  let borrowed=check_error
    "#![explc]\nfn main(){let mut xs:Vec<Box<Int>>=[box(1)];let r=&xs[0];xs.replace(0,box(2));println(**r);}"in
  expect(contains borrowed.message "borrow") "Vec element loan did not block replacement";
  let status,out,err=execute
    "struct Inner{file:File}struct Outer{inner:Inner}fn fail()->Result<File,Int>{return Result.Err(1);}#![explc]\nfn edit(x:&mut Outer)->Result<Unit,Int>{x.inner.file=fail()?;return Result.Ok(());}#![explc]\nfn main(){let mut x=Outer{inner:Inner{file:open_read(\"/dev/null\")}};println(match edit(&mut x){Result.Err(_)=>true,_=>false});let mut file=x.inner.file;println(file.read());}"in
  expect(status=0&&out="true\n\n"&&err="") "nested RHS ? dropped the original File";
  let status,_,err=execute "fn main(){let mut xs=[1,2];xs.swap(0,2);}"in
  expect(status<>0&&contains err "index out of bounds") "Vec.swap bounds failure was not checked";
  let status,out,err=execute "struct Big{padding:(Int,Int,Int),key:String}#![explc]\nfn main(){let xs:Vec<Big>=[Big{padding:(1,2,3),key:\"first\"},Big{padding:(4,5,6),key:\"second\"}];let key=&xs[1].key;println(*key);}"in
  expect(status=0&&out="second\n"&&err="") "element followed by field used the field stride";
  let bad=check_error "#![explc]\nfn observe<T>(x:&T){}fn main(){observe<Unit>(0);}"in
  expect(contains bad.message "reference target") "generic Unit reference substitution was accepted";
  let bad=check_error "#![explc]\nfn observe<T>(x:&T){}fn main(){observe<&Int>(0);}"in
  expect(contains bad.message "reference target") "generic nested reference substitution was accepted"

let test_storage_review_regressions () =
  let status,out,err=execute
    "use core.intrinsics;struct R{n:Int}impl R{fn map(self,n:Int)->Int{return self.n+n;}}struct S{n:Int}impl S{fn make(self)->R{println(1);return R{n:self.n};}}#![explc]\nfn main(){let s=S{n:1};println(s.make().map(2));let mut x:Option<I32>=Option.Some(1);let old=core.intrinsics.replace<Option<I32>>(&mut x,Option.Some(2));println(match old{Option.Some(n)=>n,_=>0});let mut units:Vec<Unit>=[(),()];units.replace(1,());units.push(());units.set(0,());units.pop();println(units.len());}"in
  expect(status=0&&out="1\n3\n1\n2\n"&&err="") "receiver evaluation, Exchange context or zero-size replacement differs";
  let bad=check_error "struct R<T>{n:T}impl<T> R<T>{fn map(self,n:Int)->Int{return n;}}fn main(){let r=R<Int>{n:0};r.map(1,2);}"in
  expect(contains bad.message "expects 1") "generic method arity did not produce a diagnostic";
  let status,_,err=execute "fn main(){let mut units:Vec<Unit>=[()];units.replace(1,());}"in
  expect(status<>0&&contains err "index out of bounds") "zero-size replacement skipped bounds checking"

let test_function_value_storage () =
  let status,out,err=execute
    "use std.iter;use std.hashmap;fn first(n:Int)->Int{return n+1;}fn second(n:Int)->Int{return n+2;}fn select(n:Int)->fn(Int)->Int{return second;}#![explc]\nfn main(){let mut functions:Vec<fn(Int)->Int>=[first];let previous=functions.replace(0,second);println(previous(3));let current=functions.pop();println(current(3));println(functions.len());for callback in [1].into_iter().map(select){println(callback(3));}let mut map=std.hashmap.new<fn(Int)->Int>();map.insert(\"callback\",first);let key=\"callback\";let callback=match map.get_cloned(&key){Option.Some(callback)=>callback,Option.None=>second};println(callback(3));}"in
  expect(status=0&&out="4\n5\n0\n5\n4\n"&&err="") "function element replacement, adapter or HashMap storage differs";
  let status,_,err=execute "fn first(n:Int)->Int{return n+1;}fn main(){let mut functions:Vec<fn(Int)->Int>=[first];functions.replace(1,first);}"in
  expect(status<>0&&contains err "index out of bounds") "function element replacement skipped bounds checking"

let test_semantic_expansion_matching () =
  let status,out,err=execute
    "#![explc]\nfn observe<T>(value:&T)->Bool{return true;}#![explc]\nfn main(){let value:Option<(Box<Int>,Bool)>=Option.Some((box(8),true));println(match &value{Option.Some((ref item,true))=>**item,Option.Some((_,false))=>0,Option.None=>0});let owned=value;println(match owned{Option.Some((item,_))=>item.into_inner(),Option.None=>0});let items:Vec<Box<Int>>=[box(9)];let ref=&items[0];println(observe(ref));println(**ref);let text=\"abc\";let shared=&text;let bytes=shared.as_bytes();println(bytes.get(1));}"in
  expect(status=0&&out="8\n8\ntrue\n9\n98\n"&&err="") "shared matching or generic borrowing differs";
  let bad=check_error
    "#![explc]\nfn main(){let value:Option<Box<Int>>=Option.Some(box(1));match &value{Option.Some(item)=>{},Option.None=>{}};}"in
  expect(contains bad.message "ref bindings") "shared match accepted a consuming binding";
  let bad=check_error
    "#![explc]\nfn main(){let value:Option<Box<Int>>=Option.Some(box(1));let r=match &value{Option.Some(ref item)=>item,Option.None=>{panic(\"missing\");}};println(**r);}"in
  expect(contains bad.message "escape") "borrowed arm reference escaped through match result";
  let bad=check_error
    "#![explc]\nfn main(){let mut text=\"abc\";let shared=&text;let bytes=shared.as_bytes();text=\"changed\";println(bytes.get(0));}"in
  expect(contains bad.message "borrow") "shared String byte view lost its source loan"

let test_semantic_expansion_adapters () =
  let source=
    "use std.iter;fn twice(value:Int)->Int{return value*2;}#![explc]\nfn positive(value:&Int)->Bool{return *value>2;}fn sum(total:Int,value:Int)->Int{return total+value;}fn unbox(value:Box<Int>)->Int{return value.into_inner();}#![explc]\nfn keep(value:&Box<Int>)->Bool{return **value>1;}fn main(){let numbers=[1,2,3];for n in numbers.iter().map(twice).filter(positive){println(n);}let boxes:Vec<Box<Int>>=[box(1),box(2),box(3)];println(std.iter.fold(boxes.into_iter().filter(keep).map(unbox),0,sum));println(std.iter.collect<std.iter.IntoIter<Int>,Int>([4,5,6].into_iter()));}"in
  let status,out,err=execute source in
  expect(status=0&&out="4\n6\n5\n[4, 5, 6]\n"&&err="") "lazy adapter chain or consuming order differs";
  let bad=check_error "use std.iter;fn main(){let xs=[1];let it=xs.into_iter();println(xs);}"in
  expect(contains bad.message "moved") "cloneable Vec into_iter did not consume its source";
  let bad=check_error "use std.iter;fn id(x:Int)->Int{return x;}fn main(){let mut xs=[1];let it=xs.iter().map(id);xs.push(2);for n in it{println(n);}}"in
  expect(contains bad.message "borrow") "map chain lost its Slice loan";
  let status,out,err=execute "struct R{n:Int}impl R{fn map(&self,n:Int)->Int{return n+1;}}fn main(){let r=R{n:0};println(r.map(2));}"in
  expect(status=0&&out="3\n"&&err="") "inherent map method required iterator factory import";
  let status,out,err=execute "struct R{map:fn(Int)->Int}fn increment(n:Int)->Int{return n+1;}fn main(){let r=R{map:increment};println(r.map(2));}"in
  expect(status=0&&out="3\n"&&err="") "function-valued map field was intercepted by the factory";
  let status,out,err=execute
    "use std.iter;struct Source{n:Int}impl Source{fn next(&mut self)->Option<Int>{self.n=self.n+1;if self.n==2{return Option.None;}return Option.Some(self.n);}}fn noisy(n:Int)->Int{println(n);return n;}fn main(){let mut it=Source{n:0}.map(noisy);it.next();it.next();it.next();}"in
  expect(status=0&&out="1\n"&&err="") "lazy adapter did not latch first None";
  let status,out,err=execute_with_fd_limit 16
    "use std.iter;#![explc]\nfn reject(file:&File)->Bool{return false;}fn main(){let mut n=0;while n<100{let files:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];for file in files.into_iter().filter(reject){panic(\"unexpected\");}let remaining:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];for file in remaining.into_iter(){break;}n=n+1;}println(n);}"in
  expect(status=0&&out="100\n"&&err="") "filtered or unyielded File cleanup leaked"

let test_iterator_exit_cleanup () =
  let status,out,err=execute_with_fd_limit 16
    "use std.iter;fn fail()->Result<Int,Int>{return Result.Err(1);}fn identity(file:File)->File{return file;}fn early(){let files:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];for file in files.into_iter(){return;}}fn error()->Result<Unit,Int>{let files:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];for file in files.into_iter(){fail()?;}return Result.Ok(());}fn construct()->Result<Unit,Int>{let files:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];let adapter=files.into_iter().map(if fail()?==0{identity}else{identity});return Result.Ok(());}fn main(){let mut n=0;while n<100{early();assert(match error(){Result.Err(_)=>true,_=>false});assert(match construct(){Result.Err(_)=>true,_=>false});let files:Vec<File>=[open_read(\"/dev/null\"),open_read(\"/dev/null\")];for file in files.into_iter(){continue;}n=n+1;}let mut iterator=[3,4].into_iter();while true{println(match iterator.next(){Option.Some(v)=>v,_=>0});break;}println(match iterator.next(){Option.Some(v)=>v,_=>0});println(n);}"in
  expect(status=0&&out="3\n4\n100\n"&&err="") "iterator return/?/continue or staged adapter cleanup leaked"

let test_std_hashmap () =
  let status,out,err=execute
    "use std.hashmap;#![explc]\nfn size(value:&Box<Int>)->Int{return **value;}#![explc]\nfn main(){let mut map=std.hashmap.new<Int>();for n in 0..30{map.insert(int_to_str(n),n);}println(map.len());let key=\"5\";println(match map.get_cloned(&key){Option.Some(n)=>n,_=>-1});println(match map.insert(key,55){Option.Some(n)=>n,_=>-1});println(match map.remove(&key){Option.Some(n)=>n,_=>-1});println(map.contains_key(&key));println(map.keys().len());let mut boxes=std.hashmap.new<Box<Int>>();boxes.insert(\"a\",box(3));let a=\"a\";println(match std.hashmap.with_value(&boxes,&a,size){Option.Some(n)=>n,_=>-1});println(match boxes.insert(\"a\",box(4)){Option.Some(b)=>b.into_inner(),_=>-1});for (k,b) in boxes.into_iter(){println(k);println(b.into_inner());}map.clear();println(map.len());}"in
  expect(status=0&&out="30\n5\n5\n55\nfalse\n29\n3\n3\na\n4\n0\n"&&err="") "HashMap growth, replacement, removal or consuming entries differs";
  let status,out,err=execute
    "use std.hashmap;#![explc]\nfn main(){let mut map=std.hashmap.new<Int>();map.insert(\"a\",1);map.insert(\"i\",2);let a=\"a\";let i=\"i\";map.remove(&a);map.insert(\"q\",3);assert(map.contains_key(&i));let bytes:Vec<U8>=[0,255];let key=bytes.into_string();map.insert(key,4);assert(map.contains_key(&key));map.insert(\"\",5);let empty=\"\";assert(map.contains_key(&empty));println(map.len());let mut unit=std.hashmap.new<Unit>();unit.insert(\"present\",());let p=\"present\";assert(unit.contains_key(&p));unit.remove(&p);println(unit.len());}"in
  expect(status=0&&out="4\n0\n"&&err="") "HashMap collision, binary key or Unit value differs";
  let bad=check_error "use std.hashmap;#![explc]\nfn main(){let map=std.hashmap.new<Box<Int>>();let key=\"a\";map.get_cloned(&key);}"in
  expect(contains bad.message "cannot move") "HashMap get_cloned accepted a move-only value";
  let status,out,err=execute_with_fd_limit 16
    "use std.hashmap;#![explc]\nfn main(){let mut n=0;while n<100{let mut map=std.hashmap.new<File>();map.insert(\"a\",open_read(\"/dev/null\"));map.insert(\"a\",open_read(\"/dev/null\"));map.insert(\"b\",open_read(\"/dev/null\"));for i in 0..6{map.insert(int_to_str(i),open_read(\"/dev/null\"));}let a=\"a\";match map.remove(&a){Option.Some(file)=>{let mut f=file;f.read();},_=>{panic(\"missing\");}}for (key,file) in map.into_iter(){break;}n=n+1;}println(n);}"in
  expect(status=0&&out="100\n"&&err="") "HashMap File replacement/removal/early exit leaked or closed a returned value"

let test_hashmap_box_cleanup () =
  let status,out,err=execute_with_fd_limit ~memory_limit_kib:32768 16
    "use std.hashmap;#![explc]\nfn peek(value:&Box<Int>)->Int{return **value;}#![explc]\nfn main(){let mut iteration=0;while iteration<200{let mut map=std.hashmap.new<Box<Int>>();for n in 0..48{map.insert(int_to_str(n),box(n));}for n in 0..48{let key=int_to_str(n);assert(match std.hashmap.with_value(&map,&key,peek){Option.Some(value)=>value==n,_=>false});}for n in 0..24{let key=int_to_str(n);map.remove(&key);}for (key,value) in map.into_iter(){break;}iteration=iteration+1;}println(iteration);}"in
  expect(status=0&&out="200\n"&&err="") "HashMap rehash lost Box values or leaked allocations"

let test_named_function_values () =
  let source =
    "fn double(value:Int)->Int{return value*2;}" ^
    "fn apply<T,U>(f:fn(T)->U,value:T)->U{return f(value);}" ^
    "fn choose()->fn(Int)->Int{return double;}" ^
    "struct Holder{f:fn(Int)->Int}" ^
    "fn main(){let f:fn(Int)->Int=double;println(apply(f,21));" ^
    "let returned=choose();println(returned(3));let h=Holder{f:double};println(h.f(4));}" in
  let status,out,err=execute source in
  if status<>0||out<>"42\n6\n8\n"||err<>"" then
    fail "named function execution differs: status=%d stdout=%S stderr=%S" status out err;
  let arity=check_error "fn f(x:Int)->Int{return x;}fn main(){let g:fn(Int)->Int=f;g();}" in
  expect(contains arity.message "expects 1") "indirect arity diagnostic differs";
  let equality=check_error "fn f(x:Int)->Int{return x;}fn main(){let a= f;let b=f;println(a==b);}" in
  expect(contains equality.message "function values") "function equality diagnostic differs";
  let generic=check_error "fn id<T>(x:T)->T{return x;}fn main(){let f=id;}" in
  expect(contains generic.message "concrete function") "generic function reference diagnostic differs"

let test_review_regressions () =
  let status,out,err=execute
    "fn id<T>(x:T)->T{return x;}fn main(){let value:Int=7;if true{let value:Bool=false;}while false{let value:String=\"inner\";}{let value:F64=1.0;}#scope[bb]{let value:U8=1;}println(id(value));}" in
  expect(status=0&&out="7\n"&&err="") "lexical shadowing leaked into generic inference";
  let status,out,err=execute
    "struct Box<T>{value:T}enum Wrap<T>{One(T)}fn unbox<T>(x:Box<T>)->T{return x.value;}fn unwrap<T>(x:Wrap<T>)->T{return match x{Wrap.One(value)=>value};}fn main(){let box:Box<Int>=Box<Int>{value:8};let wrapped:Wrap<Int>=Wrap<Int>.One(9);println(unbox(box));println(unwrap(wrapped));}" in
  expect(status=0&&out="8\n9\n"&&err="") "generic inference did not recover concrete named type arguments";
  let status,out,err=execute "fn main(){let values=[1];let view=values.slice(0,100);println(view.len());}" in
  expect(status<>0&&out=""&&contains err "slice range out of bounds") "Vec.slice finish was not checked against current length";
  let status,out,err=execute
    "fn main(){let first=match true{true=>{if true{10}else{11}},false=>0};let second=match true{true=>{if true{println(20);}21},false=>0};println(first);println(second);}" in
  expect(status=0&&out="20\n10\n21\n"&&err="") "braced match arm if tail/statement parsing differs";
  List.iter(fun source->let d=check_error source in
    if not(contains d.message "borrow") then
      fail "call argument transient borrow conflict was accepted: %s (%s)" source d.message) [
    "#global[explc]\nfn take(view:Slice<Int>,values:&mut Vec<Int>){}fn main(){let mut values=[1];take(values.as_slice(),&mut values);}";
    "#global[explc]\nfn zero(value:Int)->Int{return value;}fn take(view:Slice<Int>,ignored:Int,values:&mut Vec<Int>){}fn main(){let mut values=[1];take(values.as_slice(),zero(0),&mut values);}";
    "#global[explc]\nfn take(view:Slice<Int>,values:&mut Vec<Int>){}fn main(){let mut values=[1];let f:fn(Slice<Int>,&mut Vec<Int>)->Unit=take;f(values.as_slice(),&mut values);}";
    "#global[explc]\nstruct Holder{f:fn(Slice<Int>,&mut Vec<Int>)->Unit}fn take(view:Slice<Int>,values:&mut Vec<Int>){}fn main(){let mut values=[1];let holder=Holder{f:take};holder.f(values.as_slice(),&mut values);}"];
  ignore(compile "struct Node{children:Vec<Node>}fn main(){let root=Node{children:[]};}");
  List.iter(fun source->let d=check_error source in expect(contains d.message "requires #![bb]") "pointer-bearing aggregate crossed a non-bb boundary")[
    "struct Raw{p:Ptr<Int>}fn take(value:Raw){}fn main(){}";
    "struct Raw{p:Ptr<Int>}fn take(value:(Int,Raw)){}fn main(){}";
    "struct Raw{p:Ptr<Int>}fn take(value:Vec<Vec<Raw>>){}fn main(){}"];
  let status,out,err=execute
    "struct Item{name:String}struct Holder{items:Vec<Vec<Item>>}fn main(){let a:Vec<Vec<Vec<String>>>=[[[\"a\"]]];let mut b=a;b.set(0,[[\"b\"]]);println(a[0][0][0]);println(b[0][0][0]);let x:Vec<Vec<Item>>=[[Item{name:\"x\"}]];let mut y=x;y.set(0,[Item{name:\"y\"}]);println(x[0][0].name);println(y[0][0].name);let h=Holder{items:[[Item{name:\"h\"}]]};let mut k=h;k.items.set(0,[Item{name:\"k\"}]);println(h.items[0][0].name);println(k.items[0][0].name);}" in
  expect(status=0&&out="a\nb\nx\ny\nh\nk\n"&&err="") "deep Vec clone/drop helpers lost element lifecycle";
  let status,out,err=execute
    "struct Box<T>{value:String}struct Box_I8_{value:String}fn pass<T>(x:Vec<T>)->Vec<T>{return x;}fn main(){let a=pass<Box<I8>>([Box<I8>{value:\"generic\"}]);let b=pass<Box_I8_>([Box_I8_{value:\"plain\"}]);println(a[0].value);println(b[0].value);}" in
  expect(status=0&&out="generic\nplain\n"&&err="") "concrete runtime type labels collided";
  let status,out,err=execute
    "struct Wide{a:I64,b:I64,c:I64,d:I64,e:I64,f:I64,g:I64,h:I64,i:I64,j:I64,k:I64,l:I64,m:I64,n:I64,o:I64,p:I64,q:I64,r:I64}fn main(){println(-i8(-128));println(-i16(-32768));println(-i32(-2147483648));let values=[Wide{a:1,b:0,c:0,d:0,e:0,f:0,g:0,h:0,i:0,j:0,k:0,l:0,m:0,n:0,o:0,p:0,q:0,r:0},Wide{a:2,b:0,c:0,d:0,e:0,f:0,g:0,h:0,i:0,j:0,k:0,l:0,m:0,n:0,o:0,p:0,q:0,r:0}];let s:Slice<Wide>=values.slice(1,2);println(s[0].a);}" in
  expect(status=0&&out="-128\n-32768\n-2147483648\n2\n"&&err="") "fixed-width negation or wide Slice stride differs";
  let status,out,err=execute
    "fn main(){let mut values:Vec<F32>=[];let mut i=0;while i<1024{values.push(f32(i));i=i+1;}println(values.pop());}" in
  expect(status=0&&out="1023.0\n"&&err="") "F32 Vec pop read across its allocation boundary";
  let status,out,err=execute
    "struct Views{view:Slice<Int>}fn main(){let first=[1];let second=[2,3];let mut views=Views{view:first.as_slice()};views.view=second.as_slice();println(views.view.len());println(views.view[1]);}" in
  expect(status=0&&out="2\n3\n"&&err="") "Slice field assignment lost its length word";
  List.iter(fun source->let d=check_error source in expect(contains d.message "while it is borrowed") "possible Slice owner mutation was accepted")[
    "struct Views{a:Slice<Int>,b:Slice<Int>}fn main(){let mut first=[1];let second=[2];let views=Views{a:first.as_slice(),b:second.as_slice()};first.push(3);println(views.a.len());}";
    "struct Views{a:Slice<Int>,b:Slice<Int>}fn main(){let first=[1];let mut second=[2];let views=Views{a:first.as_slice(),b:second.as_slice()};second.push(3);println(views.b.len());}";
    "fn main(){let mut first=[1];let second=[2];let mut view:Slice<Int>=second.as_slice();if true{view=first.as_slice();}first.push(3);println(view.len());}";
    "fn main(){let first=[1];let mut second=[2];let mut view:Slice<Int>=first.as_slice();let mut again=true;while again{view=second.as_slice();again=false;}second.push(3);println(view.len());}"];
  let status,out,err=execute "struct V{x:I64,y:I64}fn sum2(a:V,b:V)->I64{return a.x+a.y+b.x+b.y;}fn mixed(a:V,k:I64)->I64{return a.x+a.y+k;}fn main(){println(sum2(V{x:1,y:2},V{x:10,y:20}));println(mixed(V{x:1,y:2},100));}" in
  expect(status=0&&out="33\n103\n"&&err="") "aggregate parameters corrupted later argument registers";
  let copied_slice=check_error "fn main(){let mut v=[1];let a:Slice<Int>=v.as_slice();let b:Slice<Int>=a;v.push(2);println(b.len());}" in
  expect(contains copied_slice.message "while it is borrowed") "copied Slice lost its borrow provenance";
  let reassigned_slice=check_error "fn main(){let mut first=[1];let mut second=[2];let a:Slice<Int>=first.as_slice();let mut view:Slice<Int>=second.as_slice();view=a;first.push(3);println(view.len());}" in
  expect(contains reassigned_slice.message "while it is borrowed") "reassigned Slice lost its new borrow provenance";
  let status,out,err=execute "fn main(){let mut first=[1];let mut second=[2];let a:Slice<Int>=first.as_slice();let mut view:Slice<Int>=second.as_slice();view=a;second.push(3);println(view[0]);}" in
  expect(status=0&&out="1\n"&&err="") "reassigned Slice kept its stale borrow provenance";
  let status,out,err=execute "fn main(){let outer:I64=42;let option=Option.Some(1);println(match option{Option.Some(x)=>outer+x,Option.None=>0});}" in
  expect(status=0&&out="43\n"&&err="") "match lost its enclosing local";
  let status,out,err=execute "fn main(){let mut total:Int=0;let option:Option<Int>=Option.Some(5);let result=match option{Option.Some(value)=>{total=total+value;true},Option.None=>false};println(total);println(result);let mut statement_total:Int=0;match Option.Some(4){Option.Some(value)=>{statement_total=statement_total+value},Option.None=>{}};println(statement_total);}" in
  expect(status=0&&out="5\ntrue\n4\n"&&err="") "match did not preserve outer local assignments";
  let status,out,err=execute "fn main(){let mut result:Option<Int>=Option<Int>.None;let flag:Bool=true;let ignored=match flag{true=>{result=Option<Int>.Some(42);1},false=>0};let value=match result{Option.Some(v)=>v,Option.None=>-1};println(value);}" in
  expect(status=0&&out="42\n"&&err="") "match lost an outer aggregate assignment";
  let status,out,err=execute "fn main(){let mut result:Option<String>=Option<String>.None;let ignored=match true{true=>{result=Option<String>.Some(\"updated\");1},false=>0};let value=match result{Option.Some(v)=>v,Option.None=>\"missing\"};println(value);}" in
  expect(status=0&&out="updated\n"&&err="") "match lost an outer managed aggregate assignment";
  let status,_,err=execute "#![bb]\nfn main(){let pid=match true{true=>syscall0(39),false=>0};assert(pid>0);}" in
  expect(status=0&&err="") "match did not preserve bb mode";
  let status,_,err=execute "fn main(){#scope[bb]{let pid=match true{true=>syscall0(39),false=>0};assert(pid>0);}}" in
  expect(status=0&&err="") "match did not preserve lexical bb mode";
  let status,out,err=execute "fn pair()->(U8,U16){return (1,2);}fn main(){let mut x:(U8,U16)=(3,4);println(x.0);x.1=9;println(x.1);println(pair().1);let nested:((Int,Int),(Int,Int))=((5,6),(7,8));println(nested.1.0);}" in
  expect(status=0&&out="3\n9\n2\n7\n"&&err="") "public tuple indexing or assignment differs";
  List.iter(fun(source,needle)->let d=check_error source in expect(contains d.message needle)"tuple access diagnostic differs")[
    ("fn main(){let p=(1,2);println(p.2);}","out of range");
    ("fn main(){let x:Int=1;println(x.0);}","tuple index access requires a tuple receiver");
    ("fn main(){let p=(1,2);println(p.999999999999999999999999999999);}","too large")];
  List.iter(fun(source,needle)->let _,message=syntax_error source in expect(contains message needle)"tuple syntax diagnostic differs")[
    ("fn main(){let p=(1,2);println(p.01);}","leading zeros");
    ("fn main(){let p=(1,2);println(p.__item_0);}","compiler-private")];
  List.iter(fun src->let d=check_error src in expect(contains d.message "concrete type") "generic type-specific operation was accepted")[
    "fn bad<T>(x:T)->Int{return len(x);}fn main(){}";
    "fn bad<T>(x:T)->Int{return x.len();}fn main(){}";
    "fn bad<T>(x:T)->T{return x[0];}fn main(){}"];
  let status,out,err=execute "fn pass<T>(x:T)->T{return x;}fn main(){println(pass(8));}" in
  expect(status=0&&out="8\n"&&err="") "generic forwarding was rejected";
  let status,out,err=execute "fn main(){println([[f32(-0.0)]]==[[f32(0.0)]]);let a=f32(0.0)/f32(0.0);println([[a]]==[[a]]);println([[f64(-0.0)]]==[[f64(0.0)]]);let b=f64(0.0)/f64(0.0);println([[b]]==[[b]]);}" in
  expect(status=0&&out="true\nfalse\ntrue\nfalse\n"&&err="") "nested float Vec equality lost IEEE semantics";
  let status,out,err=execute "struct S{x:String,v:Vec<Int>,f:File}impl S{fn replace(&mut self){self.x=\"new\";self.v=[2];self.f=open_read(\"/dev/null\");}}fn main(){let mut s=S{x:\"old\",v:[1],f:open_read(\"/dev/null\")};s.replace();println(s.x);println(s.v[0]);}" in
  expect(status=0&&out="new\n2\n"&&err="") "method field replacement corrupted the new value";
  let status,out,err=execute_with_fd_limit 64 "struct S{f:File,text:String,values:Vec<Int>}impl S{fn replace(&mut self){self.f=open_read(\"/dev/null\");self.text=\"next\";self.values=[2];}}fn main(){let mut s=S{f:open_read(\"/dev/null\"),text:\"start\",values:[1]};let mut i=0;while i<200{s.replace();i=i+1;}let extra=open_read(\"/dev/null\");println(extra.is_open());println(s.text);println(s.values[0]);}" in
  expect(status=0&&out="true\nnext\n2\n"&&err="") "repeated managed field replacement leaked or double-dropped the old value";
  let status,out,err=execute "struct P{x:String}enum E{Empty,Full(P)}fn main(){let e:E=E.Empty;println(match e{E.Empty=>1,E.Full(_)=>0});}" in
  expect(status=0&&out="1\n"&&err="") "concrete struct inactive enum payload failed";
  let private_tag=check_error "fn main(){let value=Option.Some(1);println(value.__tag);}" in
  expect(contains private_tag.message "private") "enum representation tag remained public";
  let status,out,err=execute "struct Node<T>{value:T,children:Vec<Node<T>>}struct A<T>{items:Vec<B<T>>}struct B<T>{owner:A<T>}struct Box<T>{value:T}struct Nested<T>{children:Vec<Box<Nested<T>>>}enum Tree<T>{Leaf(T),Branch(Vec<Tree<T>>)}fn main(){let mut roots:Vec<Node<Int>>=[];roots.push(Node<Int>{value:1,children:[Node<Int>{value:2,children:[]}]});println(roots[0].children[0].value);let mut mutual:Vec<A<Int>>=[];mutual.push(A<Int>{items:[B<Int>{owner:A<Int>{items:[]}}]});println(mutual[0].items[0].owner.items.len());let mut nested:Vec<Nested<Int>>=[];nested.push(Nested<Int>{children:[Box<Nested<Int>>{value:Nested<Int>{children:[]}}]});println(nested[0].children[0].value.children.len());let trees:Vec<Tree<String>>=[];println(trees.len());}" in
  expect(status=0&&out="2\n0\n0\n0\n"&&err="") "Vec-bounded recursive generic execution differs";
  let growing=check_error "struct Growing<T>{children:Vec<Growing<(T,T)>>}fn main(){let values:Vec<Growing<Int>>=[];}" in
  expect(contains growing.message "generic recursion keeps expanding its type arguments") "expanding generic recursion diagnostic differs";
  List.iter(fun source->let d=check_error source in expect(contains d.message "recursive value layout")"non-Vec recursive generic boundary was accepted") [
    "struct Direct<T>{next:Direct<T>}fn main(){let values:Vec<Direct<Int>>=[];}";
    "struct ThroughSlice<T>{next:Slice<ThroughSlice<T>>}fn main(){let values:Vec<ThroughSlice<Int>>=[];}";
    "struct ThroughPtr<T>{next:Ptr<ThroughPtr<T>>}fn main(){let values:Vec<ThroughPtr<Int>>=[];}"];
  let status,out,err=execute_with_fd_limit 64 "fn batch(){let mut outer:Vec<Vec<File>>=[];let mut i=0;while i<20{let mut inner:Vec<File>=[];let mut j=0;while j<3{inner.push(open_read(\"/dev/null\"));j=j+1;}outer.push(inner);i=i+1;}}fn main(){let mut round=0;while round<20{batch();round=round+1;}let f=open_read(\"/dev/null\");println(f.is_open());}" in
  expect(status=0&&out="true\n"&&err="") "nested Vec<File> did not close inner file descriptors"

let test_result_try () =
  let status,out,err=execute
    "struct Box<T>{value:T}fn forward<T,E>(x:Result<T,E>)->Result<T,E>{let value=x?;return Result.Ok(value);}fn chain(x:Result<Box<Int>,String>)->Result<Int,String>{return Result.Ok(x?.value);}fn nested(x:Result<Result<Int,String>,String>)->Result<Int,String>{return Result.Ok(x??);}fn control()->Result<Int,Int>{let skipped=false&&Result<Bool,Int>.Err(9)?;let mut i=0;while Result<Bool,Int>.Ok(i<2)?{i=i+1;}let n=if true{Result<Int,Int>.Ok(i)?}else{0};return Result.Ok(n);}fn arm(flag:Bool)->Result<String,Int>{let owned=\"cleanup\";let value=match flag{true=>Result<String,Int>.Err(7)?,false=>Result<String,Int>.Ok(\"ok\")?};return Result.Ok(value);}fn main(){let a:Result<Int,String>=forward(Result<Int,String>.Ok(4));println(match a{Result.Ok(v)=>v,Result.Err(_)=>-1});let b:Result<Int,String>=chain(Result<Box<Int>,String>.Ok(Box<Int>{value:8}));println(match b{Result.Ok(v)=>v,Result.Err(_)=>-1});let n:Result<Int,String>=nested(Result<Result<Int,String>,String>.Ok(Result<Int,String>.Ok(6)));println(match n{Result.Ok(v)=>v,Result.Err(_)=>-1});let c:Result<Int,Int>=control();println(match c{Result.Ok(v)=>v,Result.Err(_)=>-1});let d:Result<String,Int>=arm(false);println(match d{Result.Ok(v)=>v,Result.Err(_)=>\"bad\"});let e:Result<String,Int>=arm(true);println(match e{Result.Ok(_)=>-1,Result.Err(x)=>x});let v:Result<Vec<Int>,String>=forward(Result<Vec<Int>,String>.Ok([3,4]));println(match v{Result.Ok(xs)=>xs[1],Result.Err(_)=>-1});}" in
  if status<>0||out<>"4\n8\n6\n2\nok\n7\n4\n"||err<>""then
    fail "Result ? execution differs: status=%d stdout=%S stderr=%S" status out err;
  let status,out,err=execute_with_fd_limit 64
    "fn pass(x:Result<Int,File>)->Result<Int,File>{let n=x?;return Result.Ok(n);}fn use(x:Result<File,Int>)->Result<Bool,Int>{let f=x?;return Result.Ok(f.is_open());}fn main(){let mut i=0;while i<200{let r=pass(Result<Int,File>.Err(open_read(\"/dev/null\")));println(match r{Result.Ok(_)=>false,Result.Err(f)=>f.is_open()});i=i+1;}println(match use(Result<File,Int>.Ok(open_read(\"/dev/null\"))){Result.Ok(v)=>v,Result.Err(_)=>false});let extra=open_read(\"/dev/null\");println(extra.is_open());}" in
  expect(status=0&&String.length out>0&&err=""&&contains out "true\ntrue\n") "Result ? leaked or double-closed File payloads";
  let status,out,err=execute "fn step()->Result<Int,String>{return Result.Ok(1);}fn f(flag:Bool)->Result<Unit,String>{match flag{true=>{let x=step()?;},false=>{}};return Result.Ok(());}fn main(){let r:Result<Unit,String>=f(true);println(match r{Result.Ok(_)=>1,Result.Err(_)=>0});}" in
  expect(status=0&&out="1\n"&&err="") "Result ? failed to promote Unit-valued match arms";
  List.iter(fun(source,needle)->let d=check_error source in expect(contains d.message needle)"Result ? diagnostic differs") [
    ("fn f()->Result<Int,String>{let x=1?;return Result.Ok(x);}fn main(){}","? operand must be Result");
    ("fn f(){let x=Result<Int,String>.Ok(1)?;}fn main(){}","current function return type must be Result");
    ("fn f()->Result<Int,Int>{let x=Result<Int,String>.Ok(1)?;return Result.Ok(x);}fn main(){}","expected String, found Int")]

let test_narrow_scalar_slot_regression () =
  let source =
    "#global[explc]\n" ^
    "fn first(values:&Vec<Int>)->Int{return values.get(0);}\n" ^
    "fn main(){let a:U32=148;let b:U32=0;let sum:U32=a+b;println(sum);" ^
    "let divisor:U32=1;println(a/divisor);println(a%divisor);" ^
    "let mut values:Vec<Int>=[-2];println(first(&values));values.push(-10);println(values.len());}" in
  let status,out,err=execute source in
  expect(status=0 && out="148\n148\n0\n-2\n2\n" && err="")
    "narrow scalar locals overlapped a following Vec descriptor"

let test_semantic_cfg () =
  List.iter(fun source->let d=check_error source in
    if not(contains d.message "unsupported Vec element type")then
      fail "borrowed aggregate restriction diagnostic differs: %s\n%s"d.message source) [
    "struct V{s:Slice<Int>}fn main(){let mut a=[1];let v=[V{s:a.as_slice()}];a.push(2);println(v[0].s[0]);}";
    "struct V{s:Slice<Int>}fn main(){let mut a=[1];let v:Vec<V>=[V{s:a.as_slice()}];a.push(2);println(v[0].s[0]);}";
    "struct V{s:Slice<Int>}struct Hidden{items:Vec<V>}fn main(){}";
  ];
  let checked_error source =
    let previous=Sys.signal Sys.sigalrm (Sys.Signal_handle(fun _->fail "semantic fixed point timed out"))in
    ignore(Unix.alarm 10);
    Fun.protect ~finally:(fun()->ignore(Unix.alarm 0);Sys.set_signal Sys.sigalrm previous)
      (fun()->check_error source)in
  List.iter(fun(label,source)->
    let d=checked_error source in
    if not(contains d.message "borrow"||contains d.message "moved")then fail "%s lifetime diagnostic differs: %s"label d.message)[
    "conditional Slice","fn main(){let mut v=[1];let s:Slice<Int>=if true{v.as_slice()}else{v.as_slice()};v.push(2);println(s[0]);}";
    "copied reference","#![explc]\nfn main(){let mut x=1;let r=&x;let q=r;x=2;println(*q);}";
    "aliased mutable parameters","#global[explc]\nfn bad(a:&mut Vec<Int>,b:&mut Vec<Int>){let s=a.as_slice();b.push(2);println(s[0]);}fn main(){let mut v=[1];let r=&mut v;let q=r;bad(r,q);}";
    "copied aggregate","struct View{items:Slice<Int>}fn main(){let mut v=[1];let a=View{items:v.as_slice()};let b=a;v.push(2);println(b.items[0]);}";
    "loop borrow","#![explc]\nfn main(){let mut x=1;let r=&x;let mut i=0;while i<2{println(*r);x=2;i=i+1;}}";
    "loop Slice fixed point","fn main(){let first=[1];let mut second=[2];let mut view:Slice<Int>=first.as_slice();let mut again=true;while again{view=second.as_slice();again=false;}second.push(3);println(view.len());}";
    "inner owner escape","fn main(){let a=[1];let mut s=a.as_slice();{let inner=[2];s=inner.as_slice();}println(s[0]);}";
    "mutable receiver provenance","struct View{items:Slice<Int>}impl View{fn replace(&mut self,s:Slice<Int>){self.items=s;}}fn main(){let a=[1];let mut b=[2];let mut v=View{items:a.as_slice()};v.replace(b.as_slice());b.push(3);println(v.items[0]);}";
    "nested replacement summary","struct View{items:Slice<Int>}struct Holder{view:View}impl Holder{fn replace(&mut self,s:Slice<Int>){self.view=View{items:s};}}fn main(){let a=[1];let mut b=[2];let mut h=Holder{view:View{items:a.as_slice()}};h.replace(b.as_slice());b.push(3);println(h.view.items[0]);}";
    "call input snapshot","struct Views{a:Slice<Int>,b:Slice<Int>}impl Views{fn rotate(&mut self,s:Slice<Int>){let old=self.a;self.a=s;self.b=old;}}fn main(){let mut first=[1];let second=[2];let third=[3];let mut v=Views{a:first.as_slice(),b:second.as_slice()};v.rotate(third.as_slice());first.push(4);println(v.b[0]);}";
    "callee-created loan","struct View{items:Slice<Int>}impl View{#![explc]\nfn set(&mut self,r:&mut Vec<Int>){self.items=r.as_slice();}}#![explc]\nfn main(){let mut a=[1];let b=[2];let mut v=View{items:b.as_slice()};let r=&mut a;v.set(r);r.push(3);println(v.items[0]);}";
    "repeated field move","struct Pair{left:File,right:File}fn take(f:File){}fn main(){let p=Pair{left:open_read(\"/dev/null\"),right:open_read(\"/dev/null\")};take(p.left);take(p.left);}";
    "partial move whole use","struct Pair{left:File,right:File}fn take(f:File){}fn all(p:Pair){}fn main(){let p=Pair{left:open_read(\"/dev/null\"),right:open_read(\"/dev/null\")};take(p.left);all(p);}";
    "mutable field extraction","struct Holder{file:File}impl Holder{fn extract(&mut self)->File{return self.file;}}fn main(){let mut h=Holder{file:open_read(\"/dev/null\")};let a=h.extract();let b=h.extract();}";
    "conditional field reinitialization","struct Holder{file:File}impl Holder{fn extract(&mut self)->File{return self.file;}fn refill(&mut self,flag:Bool){if flag{self.file=open_read(\"/dev/null\");}}fn bad(&mut self){let a=self.extract();self.refill(false);let b=self.extract();}}fn main(){let mut h=Holder{file:open_read(\"/dev/null\")};h.bad();}";
    "conditional replacement","struct View{items:Slice<Int>}impl View{fn replace(&mut self,s:Slice<Int>,flag:Bool){if flag{self.items=s;}}}fn main(){let mut a=[1];let b=[2];let mut v=View{items:a.as_slice()};v.replace(b.as_slice(),true);a.push(3);println(v.items[0]);}";
    "callee owner escape","struct View{items:Slice<Int>}impl View{fn bad(&mut self){let inner=[1];self.items=inner.as_slice();}}fn main(){let a=[1];let mut v=View{items:a.as_slice()};v.bad();println(v.items[0]);}";
    "indirect summary","#![explc]\nfn grow(v:&mut Vec<Int>,n:Int){v.push(n);}#![explc]\nfn main(){let mut b=[2];let s=b.as_slice();let f:fn(&mut Vec<Int>,Int)->Unit=grow;f(&mut b,3);println(s[0]);}";
    "merged receiver versus independent Slice","#![explc]\nfn main(){let mut v=[1];let s=v.as_slice();let r:&mut Vec<Int>=if true{&mut v}else{&mut v};r.push(2);println(s[0]);}";
    "merged reference versus independent mutable loan","#global[explc]\nfn exercise(c:Bool){let mut a=1;let independent=&mut a;let r=if c{&mut a}else{&mut a};*r=2;println(*independent);}fn main(){exercise(true);}";
    "merged copied mutable arguments","#global[explc]\nfn both(a:&mut Vec<Int>,b:&mut Vec<Int>){a.push(1);b.push(2);}fn main(){let mut v=[0];let r:&mut Vec<Int>=if true{&mut v}else{&mut v};let q=r;both(r,q);}";
  ];
  let shared=checked_error "struct Holder{file:File}impl Holder{fn extract(&self)->File{return self.file;}}fn main(){let h=Holder{file:open_read(\"/dev/null\")};let a=h.extract();}"in
  expect(contains shared.message "shared reference") "shared receiver allowed a field move";
  let lexical=checked_error "fn main(){match true{true=>{while false{break;}},false=>{break;}}}"in
  expect(contains lexical.message "break outside loop") "match arm leaked its loop context";
  List.iter(fun(label,source,expected)->let status,out,err=execute source in
    if status<>0||out<>expected||err<>""then fail "%s execution differs: %d %S %S"label status out err)[
    "last borrow use","#![explc]\nfn main(){let mut x=1;let r=&x;let q=r;println(*q);x=2;println(x);}","1\n2\n";
    "same-owner mutable alternatives","#global[explc]\nfn exercise(c:Bool){let mut a=1;let r=if c{&mut a}else{&mut a};let q=r;*q=2;println(*q);a=3;println(a);}fn main(){exercise(true);exercise(false);}","2\n3\n2\n3\n";
    "same-owner merged receivers and calls","#global[explc]\nfn grow(v:&mut Vec<Int>){v.push(3);}fn exercise(c:Bool){let mut a=[1];let r:&mut Vec<Int>=if c{&mut a}else{&mut a};r.push(2);grow(r);let f:fn(&mut Vec<Int>)->Unit=grow;f(r);println(r.len());a.push(4);println(a.len());}fn main(){exercise(true);exercise(false);}","4\n5\n4\n5\n";
    "shared parameter aliases","#global[explc]\nfn add(a:&Int,b:&Int)->Int{return *a+*b;}fn main(){let n=3;let r=&n;let q=r;println(add(r,q));}","6\n";
    "definite overwrite","struct View{items:Slice<Int>}impl View{fn replace(&mut self,s:Slice<Int>){self.items=s;}}fn main(){let mut a=[1];let b=[2];let mut v=View{items:a.as_slice()};v.replace(b.as_slice());a.push(3);println(v.items[0]);}","2\n";
    "nested definite overwrite","struct View{items:Slice<Int>}struct Holder{view:View}impl Holder{fn replace(&mut self,s:Slice<Int>){self.view=View{items:s};}}fn main(){let mut a=[1];let b=[2];let mut h=Holder{view:View{items:a.as_slice()}};h.replace(b.as_slice());a.push(3);println(h.view.items[0]);}","2\n";
    "recursive definite overwrite","struct View{items:Slice<Int>}impl View{fn replace(&mut self,s:Slice<Int>,n:Int){if n==0{self.items=s;return;}self.replace(s,n-1);}}fn main(){let mut a=[1];let b=[2];let mut v=View{items:a.as_slice()};v.replace(b.as_slice(),3);a.push(3);println(v.items[0]);}","2\n";
    "mutual recursive overwrite","struct View{items:Slice<Int>}impl View{fn left(&mut self,s:Slice<Int>,n:Int){if n==0{self.items=s;return;}self.right(s,n-1);}fn right(&mut self,s:Slice<Int>,n:Int){if n==0{self.items=s;return;}self.left(s,n-1);}}fn main(){let mut a=[1];let b=[2];let mut v=View{items:a.as_slice()};v.left(b.as_slice(),4);a.push(3);println(v.items[0]);}","2\n";
    "field last use","struct View{items:Slice<Int>,count:Int}fn main(){let mut a=[1];let v=View{items:a.as_slice(),count:7};println(v.items[0]);a.push(2);println(v.count);}","1\n7\n";
    "call snapshot replacement","struct Views{a:Slice<Int>,b:Slice<Int>}impl Views{fn rotate(&mut self,s:Slice<Int>){let old=self.a;self.a=s;self.b=old;}}fn main(){let first=[1];let mut second=[2];let third=[3];let mut v=Views{a:first.as_slice(),b:second.as_slice()};v.rotate(third.as_slice());second.push(4);println(v.a[0]);println(v.b[0]);}","3\n1\n";
    "field reinitialization","struct Pair{left:File,right:File}fn take(f:File){}fn main(){let mut p=Pair{left:open_read(\"/dev/null\"),right:open_read(\"/dev/null\")};take(p.left);take(p.right);p.left=open_read(\"/dev/null\");let f=p.left;println(f.is_open());}","true\n";
    "branch move reinitialization","fn take(f:File){}fn main(){let mut f=open_read(\"/dev/null\");if true{take(f);f=open_read(\"/dev/null\");}println(f.is_open());}","true\n";
    "terminating match arm","fn choose(flag:Bool)->Int{let n=match flag{true=>{return 7;},false=>3};return n+1;}fn main(){println(choose(true));println(choose(false));}","7\n4\n";
    "all match arms terminate","fn choose(flag:Bool)->Int{match flag{true=>{return 7;},false=>{return 3;}}}fn main(){println(choose(true));println(choose(false));}","7\n3\n";
    "owned match arm result","fn main(){println(match true{true=>{let text=\"o\"+\"k\";text},false=>\"bad\"});}","ok\n";
    "observed owned if result","fn main(){let text=\"o\"+\"k\";println(if true{text}else{\"bad\"});println(text);}","ok\nok\n";
    "managed shared getter","struct Box<T>{value:T}impl<T> Box<T>{fn get(&self)->T{return self.value;}}fn main(){let b=Box<String>{value:\"o\"+\"k\"};println(b.get());println(b.get());println(b.value);}","ok\nok\nok\n";
    "Unit value storage","fn id(x:Unit)->Unit{return x;}fn main(){println(()==());println(id(())==());println(()!=());}","true\ntrue\nfalse\n";
    "definite field reinitialization","struct Holder{file:File}impl Holder{fn extract(&mut self)->File{return self.file;}fn refill(&mut self){self.file=open_read(\"/dev/null\");}}fn main(){let mut h=Holder{file:open_read(\"/dev/null\")};let a=h.extract();h.refill();let b=h.extract();println(a.is_open());println(b.is_open());}","true\ntrue\n";
    "match loop exits","fn main(){let mut i=0;while i<4{match i{0=>{i=i+1;continue;},3=>{break;},_=>{println(i);}}i=i+1;}println(i);}","1\n2\n3\n";
    "many match locals","fn main(){let a=1;let b=2;let c=3;let d=4;let e=5;let f=6;let g=7;let h=8;println(match true{true=>a+b+c+d+e+f+g+h,false=>0});}","36\n";
  ];
  let pending="fn consume(file:File,n:Int){}fn fail()->Result<Int,Int>{return Result.Err(7);}fn run()->Result<Int,Int>{consume(open_read(\"/dev/null\"),fail()?);return Result.Ok(0);}struct Holder{file:File,n:Int}fn partial()->Result<Int,Int>{let h=Holder{file:open_read(\"/dev/null\"),n:fail()?};return Result.Ok(h.n);}fn main(){let mut i=0;while i<300{let a=run();let b=partial();i=i+1;}let f=open_read(\"/dev/null\");println(f.is_open());}"in
  let status,out,err=execute_with_fd_limit 32 pending in
  if status<>0||out<>"true\n"||err<>""then fail "pending argument/aggregate cleanup differs: %d %S %S"status out err;
  let condition="fn condition(n:Int)->Vec<File>{if n<200{return [open_read(\"/dev/null\")];}return [];}fn main(){let mut n=0;while len(condition(n))>0{n=n+1;if n%2==0{continue;}}println(n);}"in
  let status,out,err=execute_with_fd_limit 32 condition in
  if status<>0||out<>"200\n"||err<>""then fail "loop condition cleanup differs: %d %S %S"status out err;
  let extracted="struct Holder{file:File}impl Holder{fn extract(&mut self)->File{return self.file;}}fn main(){let mut h=Holder{file:open_read(\"/dev/null\")};let mut f=h.extract();h.file=open_read(\"/dev/null\");f.close();let moved=h.extract();println(moved.is_open());}"in
  let status,out,err=execute extracted in
  if status<>0||out<>"true\n"||err<>""then fail "extracted File was double closed: %d %S %S"status out err;
  let refill="struct Holder{file:File}impl Holder{fn refill(&mut self){self.file=open_read(\"/dev/null\");}}fn round(){let mut h=Holder{file:open_read(\"/dev/null\")};let first=h.file;h.refill();}fn main(){let mut i=0;while i<300{round();i=i+1;}let f=open_read(\"/dev/null\");println(f.is_open());}"in
  let status,out,err=execute_with_fd_limit 32 refill in
  if status<>0||out<>"true\n"||err<>""then fail "callee did not restore caller field drop state: %d %S %S"status out err;
  let program=match Checker.check(Parser.parse ~file:"ir.xen" "fn main(){let mut n=0;while n<3{n=n+1;}println(n);}")with Ok p->p|Error d->fail "%s"d.message in
  let raw=Semantic_ir.program program in Semantic_ir.verify raw;
  let f=List.hd raw.functions in
  expect(Array.exists(fun(b:Semantic_ir.block)->match b.terminator with Semantic_ir.Branch _->true|_->false)f.blocks) "CFG contains no branch";
  expect(contains(Semantic_ir.dump raw)"jump b") "internal CFG printer omitted edges"


let test_owning_box () =
  let cases=[
    "named box function", "fn box(n:Int)->Int{return n+1;}fn main(){println(box(3));}","4\n";
    "generic box function", "fn box<T>(n:T)->T{return n;}fn main(){println(box<Int>(3));println(box(4));}","3\n4\n";
    "local box function value", "fn add(n:Int)->Int{return n+2;}fn main(){let box=add;let value=box(3);println(match value{5=>\"yes\",_=>\"no\"});}","yes\n";
    "module box shadow", "use core.box;fn box<T>(n:T)->T{return n;}fn answer(n:Int)->Bool{return n==3;}fn main(){let box=answer;let value=box(3);println(match value{true=>1,false=>0});let owned=core.box.new(7);println(owned.into_inner());}","1\n7\n";
    "scalar ABI", "fn pass(x:Box<Int>)->Box<Int>{return x;}fn main(){let x=pass(box(7));println(x.into_inner());let b=box(true);println(b.into_inner());let f=box(f32(2.5));println(f.into_inner());let u=box(());u.into_inner();}","7\ntrue\n2.5\n";
    "managed extraction", "fn main(){let x=box(\"o\"+\"k\");println(x.into_inner());let xs=box([\"a\",\"b\"]);let ys=xs.into_inner();println(ys[1]);let nested=box(box(8));println(nested.into_inner().into_inner());}","ok\nb\n8\n";
    "recursive AST", "enum Expr{Num(Int),Name(String),Add(Binary)}struct Binary{left:Box<Expr>,right:Box<Expr>}fn eval(x:Expr)->Int{return match x{Expr.Num(n)=>n,Expr.Name(s)=>len(s),Expr.Add(b)=>eval(b.left.into_inner())+eval(b.right.into_inner())};}fn main(){let x=Expr.Add(Binary{left:box(Expr.Add(Binary{left:box(Expr.Num(3)),right:box(Expr.Name(\"xen\"))})),right:box(Expr.Num(4))});println(eval(x));}","10\n";
    "mutual generic", "struct A<T>{value:T,next:Option<Box<B<T>>>}struct B<T>{back:A<T>}fn pass<T>(x:Box<T>)->Box<T>{return x;}fn main(){let a=A<Int>{value:1,next:Option<Box<B<Int>>>.Some(box(B<Int>{back:A<Int>{value:2,next:Option<Box<B<Int>>>.None}}))};let b=match a.next{Option.Some(b)=>b,Option.None=>{return;}};println(pass(b).into_inner().back.value);}","2\n";
    "Box Vec storage", "fn main(){let mut xs:Vec<Box<String>>=[];xs.push(box(\"first\"));xs.push(box(\"second\"));xs.set(0,box(\"replace\"));let ys=xs;let mut zs=ys;println(zs.pop().into_inner());println(zs.pop().into_inner());}","second\nreplace\n";
    "borrow and replace", "#global[explc]\nstruct P{a:Int,text:String}fn read(p:&P)->Int{return p.a;}fn replace(p:&mut P){*p=P{a:9,text:\"new\"};}fn main(){let mut b=box(P{a:7,text:\"old\"});let r=&*b;println(read(r));let m=&mut *b;replace(m);let after=b.as_ref();println(after.text);println(b.into_inner().a);}","7\nnew\n9\n";
    "nested boxed borrow", "#global[explc]\nstruct Inner{value:Int}struct Outer{inner:Box<Inner>}fn update(p:&mut Inner){p.value=12;}fn main(){let mut b=box(Outer{inner:box(Inner{value:1})});let o=b.as_mut();let i=o.inner.as_mut();update(i);let after=b.as_ref();let item=after.inner.as_ref();println(item.value);}","12\n";
    "generic Box identities", "use core.box;struct Box<T>{value:T}struct Wrap<T>{value:T}fn main(){let a=Wrap<Box<Int>>{value:Box<Int>{value:4}};let b=Wrap<core.box.Box<Int>>{value:core.box.new(7)};println(a.value.value);println(b.value.into_inner());}","4\n7\n";
    "user Box identity", "use core.box;use core.intrinsics;struct Box<T>{value:T}fn main(){let inline=Box<Int>{value:3};let owned:core.box.Box<Int>=core.box.new(8);println(inline.value);println(owned.into_inner());println(core.intrinsics.size_of<core.box.Box<String>>());println(core.intrinsics.align_of<core.box.Box<String>>());}","3\n8\n8\n8\n";
  ]in
  List.iter(fun(label,source,wanted)->let status,out,err=execute source in
    if status<>0||out<>wanted||err<>""then fail "Box %s differs: %d %S %S"label status out err)cases;
  let bad=[
    "struct N{next:N}fn main(){}","recursive value layout";
    "struct A{b:B}struct B{a:A,extra:Box<A>}fn main(){}","recursive value layout";
    "struct A<T>{b:B<T>}struct B<T>{a:A<T>,extra:Box<A<T>>}fn main(){let v:Vec<A<Int>>=[];}","recursive value layout";
    "struct Growing<T>{next:Box<Growing<(T,T)>>}fn main(){let v:Vec<Growing<Int>>=[];}","generic recursion keeps expanding";
    "struct Box<T>{value:T}struct N{next:Box<N>}fn main(){}","recursive value layout";
    "fn main(){let x:Option<Box<Int>>=Option<Box<Int>>.None;let b=x.__payload_Some;println(b.into_inner());}","private";
    "#![explc]\nfn main(){let x:Option<Box<Int>>=Option<Box<Int>>.None;let r=(x.__payload_Some).as_ref();println(*r);}","private";
    "fn main(){let mut x:Option<Box<Int>>=Option<Box<Int>>.None;x.__payload_Some=box(1);}","private";
    "#global[explc]\nfn edit(x:&mut Option<Box<Int>>){x.__payload_Some=box(1);}fn main(){}","private";
    "fn main(){let b=box();}","box expects 1 argument";
    "fn main(){let b=box<Int,String>(1);}","box expects 1 type argument";
    "fn main(){let a=box(1);let b=a;println(a.into_inner());}","use of moved";
    "fn add<T>(x:Box<T>)->T{return x.into_inner()+1;}fn main(){println(add(box(2)));}","unconstrained type parameter";
    "#![explc]\nfn main(){let a=box(1);let r=a.as_ref();let b=a;println(*r);}","while it is borrowed";
    "#![explc]\nfn main(){let mut a=box(1);let r=a.as_ref();a=box(2);println(*r);}","while it is borrowed";
    "#![explc]\nfn main(){let a=box(1);let m=a.as_mut();}","mutable Box borrow";
    "#global[explc]\nfn edit(b:&Box<Int>){let r=b.as_mut();}fn main(){}","shared reference";
    "#![explc]\nfn main(){let a=box(1);let r=a.as_ref();*r=2;}","shared reference";
    "#![explc]\nfn main(){let r=box(1).as_ref();}","local owner";
    "#![explc]\nfn main(){let mut b=box(box(1));let r=b.as_mut();let x=*r;}","cannot move";
    "#global[explc]\nstruct P{f:File}fn take(p:&mut P)->File{let f=p.f;p.f=open_read(\"/dev/null\");return f;}fn main(){let mut b=box(P{f:open_read(\"/dev/null\")});let r=b.as_mut();let f=take(r);}","borrowed Box contents";
    "#global[explc]\nstruct P{f:File}fn take(p:&mut P)->File{return p.f;}fn main(){let mut b=box(P{f:open_read(\"/dev/null\")});let r=b.as_mut();let f=take(r);}","borrowed Box contents";
    "#global[explc]\nfn escape()->&Int{let b=box(1);return b.as_ref();}fn main(){}","references cannot be returned";
    "fn main(){let mut xs=[box(1)];let y=xs[0];}","move-only";
    "fn main(){let xs=[1];let b=box(xs.as_slice());}","unsupported Box element";
    "#![bb]\nfn main(){let p=raw_alloc<Int>(1);let b=box(p);}","unsupported Box element";
  ]in
  List.iter(fun(source,wanted)->let d=check_error source in
    if not(contains d.message wanted)then fail "Box diagnostic differs: %S, expected %S\n%s"d.message wanted source)bad;
  List.iter(fun(source,wanted)->
    let checked=match Checker.check(Parser.parse ~file:"box-ir.xen"source)with Ok p->p|Error d->fail "%s"d.message in
    let raw=Semantic_ir.program checked in
    let functions=List.map(fun(f:Semantic_ir.func)->
      let candidate=ref None in
      Array.iter(fun(b:Semantic_ir.block)->List.iter(fun(op:Semantic_ir.operation)->match op.node with
        |Semantic_ir.Acquire(v,_,p)when p.typ=String||(match p.typ with Box _->true|_->false)->if !candidate=None then candidate:=Some v.id
        |_->())b.operations)f.blocks;
      match !candidate with None->f|Some id->
        let locals=Array.mapi(fun i(l:Semantic_ir.local)->if i=id then {l with owned=false}else l)f.locals in
        let blocks=Array.map(fun(b:Semantic_ir.block)->{b with operations=List.map(fun(op:Semantic_ir.operation)->match op.node with
          |Semantic_ir.Acquire(v,_,p)when v.id=id->{op with node=Semantic_ir.Acquire(v,Semantic_ir.Read,p)}|_->op)b.operations})f.blocks in
        {f with locals;blocks})raw.functions in
    try ignore(Semantic_analysis.check{raw with functions});fail "IR allowed consuming an observed Box operand"
    with Semantic_ir.Invalid(_,message)->expect(contains message wanted)"Box IR consuming contract diagnostic differs") [
      "fn main(){let a=box(1);let n=a.into_inner();println(n);}","Box extraction consumes";
      "fn main(){let a=\"owned\";let b=box(a);}","Box construction consumes";
    ];
  let recursive_borrow="#global[explc]\nstruct N{value:Int,child:Box<N>}fn walk(n:&N){println(n.value);walk(n.child.as_ref());}fn edit(n:&mut N){n.value=2;edit(n.child.as_mut());}fn main(){}"in
  (match Checker.check(Parser.parse ~file:"box-summary.xen" recursive_borrow)with
   |Ok _->()|Error d->fail "recursive boxed borrow summary failed: %s"d.message);
  let allocation_loop="fn main(){let mut i=0;while i<20000{let mut b=box([\"a\"+\"b\",\"c\"]);b=box([\"next\"]);let v=b.into_inner();let nested=box(box(i));let n=nested.into_inner().into_inner();assert(n==i);i=i+1;}println(i);}"in
  let status,out,err=execute_with_fd_limit ~memory_limit_kib:32768 32 allocation_loop in
  if status<>0||out<>"20000\n"||err<>""then fail "Box mapping cleanup differs: %d %S %S"status out err;
  let lifecycle="enum Tree{Empty,Leaf(File),Branch(Box<Pair>)}struct Pair{left:Tree,right:Tree}fn leaf()->Tree{return Tree.Leaf(open_read(\"/dev/null\"));}fn tree()->Box<Tree>{return box(Tree.Branch(box(Pair{left:leaf(),right:leaf()})));}fn fail()->Result<Int,Int>{return Result.Err(7);}fn pending(b:Box<Tree>,n:Int){}fn early()->Result<Int,Int>{pending(tree(),fail()?);return Result.Ok(0);}fn main(){let mut sentinel=open_read(\"/dev/null\");let mut i=0;while i<300{let mut root=tree();root=tree();let taken=root.into_inner();let empty=box(Tree.Empty);let a=early();{let nested=tree();}i=i+1;if i%2==0{let next=tree();continue;}if i==300{let last=tree();break;}}println(len(sentinel.read()));let file=box(open_read(\"/dev/null\"));let mut f=file.into_inner();println(len(f.read()));}"in
  let status,out,err=execute_with_fd_limit 32 lifecycle in
  if status<>0||out<>"0\n0\n"||err<>""then fail "recursive Box cleanup differs: %d %S %S"status out err

let test_tuple_let () =
  let source="fn pair<T>(a:T,b:T)->(T,T){return(a,b);}fn first<T>(p:(T,T))->T{let(a,_)=p;return a;}fn first_annotated<T>(p:(T,T))->T{let(a,_):(T,T)=p;return a;}fn made()->(Int,(String,Int)){print(\"once\");return(1,(\"hi\",9));}fn main(){let mut(a,(b,_)):(Int,(String,Int))=made();a=3;b=\"bye\";println(a);println(b);let x=5;{let(x,y)=(x+1,x+2);println(x+y);}println(x);println(first(pair(7,8)));println(first<Int>((9,10)));println(first(pair(\"yes\",\"no\")));println(first_annotated<String>((\"text\",\"skip\")));println(first(pair(box(11),box(12))).into_inner());println(first_annotated<Box<Int>>((box(13),box(14))).into_inner());println(match true{_=>{let(c,d)=pair(5,6);c+d}});let __tuple_owner_1=15;let(_,n)=(box(0),__tuple_owner_1);println(n);let _=box(0);}" in
  let status,out,err=execute source in
  if status<>0||out<>"once3\nbye\n13\n5\n7\n9\nyes\ntext\n11\n13\n11\n15\n"||err<>""then fail "tuple let execution differs: %d %S %S"status out err;
  List.iter(fun(typ,a,b,show,expected)->
    let source=Printf.sprintf "fn take<T>(p:(T,T))->T{let(a,_)=p;return a;}fn main(){let p=(%s,%s);let(x,_)= (take(p),0);println(%s);let y=match true{_=>{let(a,b)= (take(p),0);a}};println(%s);let z=match true{_=>{let(a,b)= (take<%s>(p),0);a}};println(%s);}" a b (show "x") (show "y") typ (show "z") in
    let status,out,err=execute source in
    if status<>0||out<>expected||err<>""then fail "tuple generic probe differs: %d %S %S"status out err)
    ["Int","1","2",(fun n->n),"1\n1\n1\n";
     "String","\"one\"","\"two\"",(fun n->n),"one\none\none\n"];
  List.iter(fun explicit->
    let take=if explicit then "take<Box<Int>>" else "take" in
    let source="fn take<T>(p:(T,T))->T{let(a,_)=p;return a;}fn main(){let p=(box(1),box(2));let y=match true{_=>{let(a,b)= ("^take^"(p),0);a}};println(y.into_inner());}" in
    let status,out,err=execute source in
    if status<>0||out<>"1\n"||err<>""then fail "tuple Box generic probe differs: %d %S %S"status out err)[false;true];
  List.iter(fun(typ,a,b,show,expected)->List.iter(fun explicit->
    let take=if explicit then "take<"^typ^">" else "take" in
    let id=if explicit then "id<"^typ^">" else "id" in
    let source=Printf.sprintf "fn take<T>(p:(T,T))->T{let(a,_)=p;return a;}fn id<T>(x:T)->T{return x;}fn main(){{let p=((%s,%s),(%s,%s));let(a,b)=(%s(p.0),0);println(%s);}{let p=((%s,%s),(%s,%s));let y=match true{_=>{let(a,b)=(%s(p.0),0);a}};println(%s);}{let p=(%s,%s);let y=match true{_=>{let(a,b)=(%s(match true{_=>{let(c,d)=p;c}}),0);a}};println(%s);}}"
      a b a b take (show "a") a b a b take (show "y") a b id (show "y") in
    let status,out,err=execute source in
    if status<>0||out<>expected||err<>""then fail "nested tuple generic probe differs: %d %S %S"status out err)[false;true])
    ["Int","1","2",(fun n->n),"1\n1\n1\n";
     "String","\"one\"","\"two\"",(fun n->n),"one\none\none\n";
     "Box<Int>","box(1)","box(2)",(fun n->n^".into_inner()"),"1\n1\n1\n"];
  List.iter(fun(source,message)->let d=check_error source in
    if not(contains d.message message)then fail "tuple let diagnostic differs: %s"d.message)[
    "fn main(){let(a,a)=(1,2);}","duplicate pattern binding";
    "fn main(){let a=1;let(a,b)=(2,3);}","duplicate local";
    "fn main(){let(a,b,c)=(1,2);}","tuple pattern expects 2 elements";
    "struct __Tuple<T>{a:T,b:Int}fn main(){let(a,b)=__Tuple<Int>{a:1,b:2};}","tuple pattern cannot match";
    "struct P{a:Int,b:Int}fn main(){let(a,b)=P{a:1,b:2};}","tuple pattern cannot match";
    "fn main(){let(a,(b,c))=(1,2);}","tuple pattern cannot match";
    "fn main(){let(a,b):(Int,Int)=(1,\"bad\");}","expected Int (I64)";
    "fn main(){let(a,b)=(1,2);a=3;}","immutable local";
    "fn main(){let(a,b)=(a,2);}","cannot infer tuple element type";
    "fn main(){let p=(box(1),box(2));let(a,_)=p;println(p.0.into_inner());}","moved";
    "fn unused<T>(p:(T,T)){let(a,a)=p;}fn main(){}","duplicate pattern binding";
    "fn unused<T>(p:T){let(a,b)=p;}fn main(){}","unconstrained type parameter";
    "fn unused<T>(p:(T,T)){let(a,b)=p;println(a);}fn main(){}","unconstrained type parameter";
  ];
  List.iter(fun p->let _,m=syntax_error("fn main(){let "^p^"=(1,2);}")in
    if not(contains m "let pattern supports")then fail "refutable let pattern diagnostic differs: %s"m)
    ["(1,x)";"Option.Some(x)";"true"];
  let source="fn main(){let v=[8];let(view,_)= (v.as_slice(),0);println(view[0]);}" in
  let status,out,err=execute source in
  if status<>0||out<>"8\n"||err<>""then fail "tuple Slice provenance differs: %d %S %S"status out err;
  let source="fn bad()->Result<Int,Int>{return Result.Err(7);}fn early()->Result<Int,Int>{let(a,b)=(open_read(\"/dev/null\"),bad()?);return Result.Ok(b);}fn inside()->Result<Int,Int>{let(a,b):(File,Int)=(open_read(\"/dev/null\"),match true{_=>{return Result.Err(8);}});return Result.Ok(b);}fn main(){let mut i=0;while i<300{let mut(kept,(_,last))=(open_read(\"/dev/null\"),(open_read(\"/dev/null\"),open_read(\"/dev/null\")));assert(kept.is_open());assert(last.is_open());let _=early();let _=inside();i=i+1;if i%2==0{continue;}if i==299{break;}}println(i);}" in
  let status,out,err=execute_with_fd_limit 32 source in
  if status<>0||out<>"299\n"||err<>""then fail "tuple File cleanup differs: %d %S %S"status out err;
  let source="fn main(){let mut i=0;while i<20000{let(a,(_,(b,_)))=(box([i,i+1]),(box([0,1]),(box(\"ok\"),box([2,3]))));assert(a.into_inner()[0]==i);assert(b.into_inner()==\"ok\");let(_,_)=(\"hello\",[1,2,3]);i=i+1;}println(i);}" in
  let status,out,err=execute_with_fd_limit ~memory_limit_kib:32768 32 source in
  if status<>0||out<>"20000\n"||err<>""then fail "tuple Box/managed cleanup differs: %d %S %S"status out err

let () =
  test_tuple_let ();
  test_owning_box ();
  test_semantic_diagnostic_notes ();
  test_semantic_cfg ();
  test_fixup ();
  test_backward_and_rip_fixups ();
  test_elf ();
  test_end_to_end ();
  test_checker ();
  test_diagnostic_ux ();
  test_control_flow_and_arity ();
  test_lexical_blocks_and_cleanup ();
  test_modes ();
  test_mode_scopes ();
  test_calls_and_runtime ();
  test_feedback_patch ();
  test_call_depth ();
  test_float_literals_and_checker ();
  test_float_execution_and_calls ();
  test_float_conversions_and_print ();
  test_string_literals_and_checker ();
  test_string_execution_and_abi ();
  test_string_builtins_and_moves ();
  test_vec_checker ();
  test_nested_vec_mutation ();
  test_pr4_review_regressions ();
  test_vec_execution_and_abi ();
  test_generic_vec_storage_and_lifecycle ();
  test_slice_checker_and_execution ();
  test_generic_scalar_vec ();
  test_remaining_builtins ();
  test_reference_parser_and_checker ();
  test_reference_execution_and_abi ();
  test_aggregate_references ();
  test_shared_reborrow_and_coercion ();
  test_file_checker ();
  test_file_execution ();
  test_ptr_checker_and_execution ();
  test_typed_raw_memory_and_syscalls ();
  test_inherent_methods_and_pointer_aggregates ();
  test_structural_for ();
  test_int_range_for ();
  test_string_byte_bridge ();
  test_std_env_and_string ();
  test_bundled_std_import ();
  test_toolchain_modules ();
  test_std_convert_and_sum_file ();
  test_std_fs_io_and_copy_file ();
  test_word_count ();
  test_std_iterator_factories ();
  test_std_iter_fold ();
  test_semantic_expansion_places ();
  test_storage_review_regressions ();
  test_function_value_storage ();
  test_semantic_expansion_matching ();
  test_semantic_expansion_adapters ();
  test_iterator_exit_cleanup ();
  test_std_hashmap ();
  test_hashmap_box_cleanup ();
  test_named_function_values ();
  test_review_regressions ();
  test_result_try ();
  test_named_structs ();
  test_fixed_width_numeric_types ();
  test_narrow_scalar_slot_regression ();
  test_qualified_generic_imports ();
  test_generics_enums_and_match ();
  test_generic_body_contract ();
  test_generic_argument_inference ();
  test_recursive_enum_layouts ();
  test_unused_generic_struct_fields ();
  test_match_binary_arm_result_type ();
  test_contextual_enums_and_if_chains ();
  test_contextual_enum_collections ();
  test_structural_match_patterns ();
  test_modules_and_imports ();
  test_example_suite ();
  test_error_examples ();
  print_endline "native core tests passed"
