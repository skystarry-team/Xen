(* SPDX-License-Identifier: Apache-2.0 *)
type local_id = int
type value_id = local_id
type block_id = int
type scope_id = int
type function_id = int
type struct_field = {
  name : string;
  typ : Ast.typ;
  offset : int;
  owner_size : int;
}
type struct_layout = {
  name : string;
  fields : struct_field list;
  size : int;
  alignment : int;
  managed : bool;
}
type acquisition = Read | Copy | Clone | Move
type value = { id : value_id; typ : Ast.typ; span : Ast.span; }
type projection = Field of struct_field | Element of value | Deref
type place = {
  root : local_id;
  projections : projection list;
  typ : Ast.typ;
  span : Ast.span;
}
type local = {
  id : local_id;
  name : string;
  typ : Ast.typ;
  span : Ast.span;
  scope : scope_id;
  owned : bool;
  temporary : bool;
  parameter : int option;
}
type scope = {
  id : scope_id;
  parent : scope_id option;
  mode_set : Ast.mode list;
  span : Ast.span;
  declarations : local_id list;
}
type rvalue =
    Int_lit of int64
  | Float_lit of float
  | String_lit of string
  | Bool_lit of bool
  | Unary of string * value
  | Binary of string * value * value
  | Call of string * value list
  | Function_address of string
  | Indirect_call of value * value list
  | Box_new of value | Box_take of value
  | Raw_alloc of Ast.typ * value
  | Raw_load of Ast.typ * value * value
  | Raw_store of Ast.typ * value * value * value
  | Raw_free of Ast.typ * value
  | Ptr_addr of Ast.typ * value
  | Ptr_len of value
  | Syscall of value list
  | Vec_lit of value list
  | Index of value * value
  | Vec_get of value * value
  | Vec_len of value
  | Slice_make of value * value * value
  | Slice_len of value
  | Slice_get of value * value
  | Vec_set of value * value * value
  | Vec_push of value * value
  | Vec_pop of value
  | Exchange of value * value | Vec_swap of value * value * value
  | Vec_replace of value * value * value
  | File_read of value
  | File_write of value * value
  | File_close of value
  | File_is_open of value
  | Struct_lit of struct_layout * (struct_field * value) list
type operation_node =
    Storage_live of local_id
  | Storage_dead of local_id
  | Acquire of value * acquisition * place
  | Borrow of value * bool * bool * place
  | Eval of value * rvalue
  | Initialize of place * value
  | Replace of place * value
  | Drop of place
  | Forget of place
  | Logical_call_enter of function_id
  | Logical_call_exit of function_id
  | Drop_flag of place * bool
type operation = {
  node : operation_node;
  span : Ast.span;
  scope : scope_id;
}
type terminator =
    Branch of value * block_id * block_id
  | Jump of block_id
  | Return of value option
  | Stop
type block = {
  id : block_id;
  scope : scope_id;
  operations : operation list;
  terminator : terminator;
}
type func = {
  id : function_id;
  name : string;
  mode_set : Ast.mode list;
  params : local_id list;
  return_type : Ast.typ;
  locals : local array;
  scopes : scope array;
  blocks : block array;
  entry : block_id;
  span : Ast.span;
}
type program = {
  layouts : struct_layout list;
  enums : Ast.enum_decl list;
  functions : func list;
  entry : string;
}
(* Only the semantic pipeline creates a checked program; backend callers
   cannot construct the wrapper directly. *)
type checked_program
val program : checked_program -> program
val place_of_value : value -> place
val value_of_local : local -> value
val rvalue_uses : rvalue -> value list
val place_uses : place -> local_id list
val uses : operation -> local_id list
val defines : operation -> value_id list
val successors : terminator -> block_id list
val terminator_uses : terminator -> value_id list
exception Invalid of Ast.span * string
val verify : program -> unit
val checked : program -> checked_program
val string_of_place : place -> string
val dump : program -> string
