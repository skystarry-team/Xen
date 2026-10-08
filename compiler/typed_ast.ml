(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

type transfer = Direct | Copy | Clone | Move
type struct_field = Semantic_ir.struct_field = { name : string; typ : typ; offset : int; owner_size : int }
type struct_layout = Semantic_ir.struct_layout = { name : string; fields : struct_field list; size : int; alignment : int; managed : bool }
type expr = { node : expr_node; typ : typ; span : span; transfer : transfer; mode_set : mode list }
and expr_node =
  | Int_lit of int64 | Float_lit of float | String_lit of string | Bool_lit of bool | Var of string
  | Unary of string * expr | Binary of string * expr * expr
  | Call of string * expr list
  | Function_address of string | Indirect_call of expr * expr list
  | Box_new of expr | Box_take of expr | Box_borrow of bool * expr
  | Raw_alloc of typ * expr | Raw_load of typ * expr * expr
  | Raw_store of typ * expr * expr * expr | Raw_free of typ * expr
  | Ptr_addr of typ * expr | Ptr_len of expr | Syscall of expr list
  | Vec_lit of expr list | Index of expr * expr
  | Vec_len of expr | Vec_get of expr * expr
  | Slice_make of expr * expr * expr | Slice_len of expr | Slice_get of expr * expr
  | Address of string | Field_address of expr * struct_field | Deref of expr
  | Shared_reborrow of expr
  | Vec_set of expr * expr * expr | Vec_push of expr * expr | Vec_pop of expr
  | File_read of expr | File_write of expr * expr | File_close of expr | File_is_open of expr
  | Struct_lit of struct_layout * (struct_field * expr) list
  | Field of expr * struct_field
  | Try of expr * struct_layout * struct_field * struct_field * struct_layout * struct_field * struct_field
  | If_expr of expr * expr * expr
  | Match_control of string * expr * (Ast.pattern * expr * block * expr option) list

and block = { mode_set : mode list; statements : stmt list; terminated : bool }
and stmt = { node : stmt_node; span : span }
and stmt_node =
  | Let_pattern of expr * (string * struct_field list * span) list
  | Let of string * expr | Assign of string * expr | Field_assign of string * struct_field * expr
  | Ref_field_assign of expr * struct_field * expr | Expr of expr
  | Vec_set_stmt of expr * expr * expr | Ref_set of expr * expr
  | Return of expr option | If of expr * block * block
  | While of expr * block | Block of block | Scope of block | Break | Continue

type func = {
  name : string; mode_set : mode list; params : param list; return_type : typ;
  body : block; span : span;
}
type program = { enums : Ast.enum_decl list; layouts : struct_layout list; functions : func list; entry : string }
