(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

(* Resolve names once, before monomorphization. Later phases see identities. *)
let contains name = List.mem name ["core.intrinsics"; "core.box"]
let intrinsic = function
  | "core.intrinsics.size_of" -> Some Size_of
  | "core.intrinsics.align_of" -> Some Align_of
  | "core.intrinsics.replace" -> Some Exchange
  | _ -> None
let name = function Size_of -> "size_of" | Align_of -> "align_of" | Exchange -> "replace"
let program module_name span =
  {module_decl=Some(module_name,span); imports=[]; global_mode_set=[];
   structs=[]; enums=[]; functions=[]}
