(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

exception Error of span * string

let read_file path =
  let channel=open_in_bin path in
  Fun.protect ~finally:(fun()->close_in channel)
    (fun()->really_input_string channel (in_channel_length channel))

let module_path root name =
  Filename.concat root (String.concat Filename.dir_sep (String.split_on_char '.' name)^".xen")

type module_root = Project_root | Std_root | Core_root
let namespace name = match List.hd(String.split_on_char '.' name) with
  | "std"->Std_root | "core"->Core_root | _->Project_root

let dependency_root dependency =
  let root=namespace dependency.import_name in
  (match dependency.import_origin,root with
   | Project,(Std_root|Core_root)->raise(Error(dependency.import_span,
       "toolchain module '"^dependency.import_name^"' requires use, not import"))
   | Toolchain,Project_root->raise(Error(dependency.import_span,
       "unknown use root in '"^dependency.import_name^"'; use accepts only std.* or core.*"))
   | _->()); root

let executable_directory () =
  (* Linux is Xen's sole host/target. This also handles PATH and symlink launches. *)
  let executable=try Unix.readlink "/proc/self/exe" with Unix.Unix_error _->Sys.executable_name in
  Filename.dirname executable

let stdlib_candidates () =
  let directory=executable_directory () in
  let parent=Filename.dirname directory in
  let development=
    if Filename.basename directory="dist" && Filename.basename parent="compiler" then
      [Filename.concat directory "../../stdlib"]
    else if List.mem(Filename.basename directory)["compiler";"tests";"benchmarks"] &&
      Filename.basename parent="default" && Filename.basename(Filename.dirname parent)="_build" then
      [Filename.concat directory "../../../stdlib"]
    else [] in
  [Filename.concat directory "../lib/xen";
   Filename.concat directory "../stdlib"] @ development

let stdlib_root span =
  let valid root=Sys.is_directory root &&
    Sys.file_exists(Filename.concat root "std") && Sys.is_directory(Filename.concat root "std") in
  let valid root=try valid root with Sys_error _->false in
  match Sys.getenv_opt "XEN_STDLIB_ROOT" with
  | Some root when valid root->root
  | Some root->raise(Error(span,"invalid XEN_STDLIB_ROOT '"^root^"'; expected a directory containing std/"))
  | None->let candidates=stdlib_candidates () in
      (match List.find_opt valid candidates with Some root->root | None->
        raise(Error(span,"bundled stdlib not found; searched: "^String.concat ", " candidates^
          "; reinstall the toolchain or set XEN_STDLIB_ROOT for development")))

let load_graph ~project_root ~expected entry =
  let states:(string,[`Visiting|`Done])Hashtbl.t=Hashtbl.create 16 in
  let order=ref [] in
  let parse path = Parser.parse ~file:path (read_file path) in
  let rec visit dependency =
    let requested=dependency.import_name and at=dependency.import_span in
    let root=dependency_root dependency in
    match Hashtbl.find_opt states requested with
    | Some `Done->()
    | Some `Visiting->raise(Error(at,"module dependency cycle involving '"^requested^"'"))
    | None->
        let program=match root with
          | Core_root->if not(Core_modules.contains requested)then
                raise(Error(at,"unknown core module '"^requested^"'"));
              Core_modules.program requested at
          | Project_root|Std_root->
              let base=if root=Std_root then stdlib_root at else project_root in
              let path=module_path base requested in
              if not(Sys.file_exists path) || Sys.is_directory path then
                raise(Error(at,(if root=Std_root then "std module" else "import file")^
                  " not found for module '"^requested^"': "^path));
              parse path in
        Hashtbl.add states requested `Visiting;
        (match program.module_decl with
         | None->raise(Error(at,"loaded file must declare module "^requested^";"))
         | Some(actual,span) when actual<>requested->raise(Error(span,"module '"^actual^"' does not match path; expected '"^requested^"'"))
         | Some _->());
        List.iter(fun dependency->
          ignore(dependency_root dependency);
          if dependency.import_name=requested then raise(Error(dependency.import_span,"module cannot depend on itself"));
          if root=Std_root && dependency.import_origin=Project then
            raise(Error(dependency.import_span,"bundled std modules cannot import project modules"));
          visit dependency)program.imports;
        Hashtbl.replace states requested `Done;order:=program::!order in
  List.iter(fun dependency->ignore(dependency_root dependency))entry.imports;
  (match entry.module_decl with Some(name,span) when namespace name<>Project_root->
     raise(Error(span,"module namespace '"^List.hd(String.split_on_char '.' name)^".*' is reserved for the toolchain"))|_->());
  if entry.imports=[] then [entry] else begin
    let actual=match entry.module_decl with
      | None->if List.exists(fun i->i.import_origin=Project)entry.imports then
          raise(Error((List.find(fun i->i.import_origin=Project)entry.imports).import_span,
            "an entry file using import must declare module "^expected^";")); "$entry"
      | Some(actual,span)->if actual<>expected then raise(Error(span,
          "entry module '"^actual^"' does not match path; expected '"^expected^"'")); actual in
    Hashtbl.add states actual `Visiting;
    List.iter(fun dependency->
      if dependency.import_name=actual then raise(Error(dependency.import_span,"module cannot depend on itself"));
      visit dependency)entry.imports;
    Hashtbl.replace states actual `Done;
    entry :: List.rev !order
  end

let load ?root entry_path =
  let entry=Parser.parse ~file:entry_path (read_file entry_path)in
  let project_root=Option.value ~default:(Filename.dirname entry_path)root in
  let expected=match root with None->Filename.basename entry_path |> Filename.remove_extension
    |Some root->let absolute_root=Unix.realpath root in
        let prefix=if absolute_root="/"then "/"else absolute_root^"/" and path=Unix.realpath entry_path in
        if not(String.starts_with ~prefix path)then
          raise(Error({file=entry_path;line=1;column=1},"entry is outside project root"));
        let relative=String.sub path(String.length prefix)(String.length path-String.length prefix)in
        String.map(fun c->if c='/'then '.'else c)(Filename.remove_extension relative)in
  load_graph ~project_root ~expected entry

let load_toolchain name =
  let span={file="<xen test "^name^">";line=1;column=1}in
  let entry={ (Core_modules.program "$tests" span) with
    imports=[{import_name=name;import_origin=Toolchain;import_span=span;import_alias=None}]}in
  load_graph ~project_root:"." ~expected:"$tests" entry
