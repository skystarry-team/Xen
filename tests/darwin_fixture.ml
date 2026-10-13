(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Internal prototype artifact for future VM validation; intentionally does not
   alter CLI support or infer execution success from generating a Mach-O. *)
module B = Xen_darwin_arm64.Darwin_backend
let () =
  if Array.length Sys.argv<>3 then failwith "usage: darwin_fixture SOURCE OUTPUT";
  let programs=Project_loader.load ~target:B.description.target Sys.argv.(1) in
  let checked=match programs with
    |[ast] when ast.Ast.imports=[]->Checker.check ast
    |entry::_->Checker.check_project
        ~entry_module:(Option.fold ~none:"$entry" ~some:fst entry.Ast.module_decl) programs
    |[]->assert false in
  match checked with
  |Error error->failwith error.Checker.message
  |Ok checked->match B.generate checked with
    |Error error->failwith error.Backend_intf.message
    |Ok image->B.write Sys.argv.(2) image
