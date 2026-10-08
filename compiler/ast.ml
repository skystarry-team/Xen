(* SPDX-License-Identifier: Apache-2.0 *)
type span = { file : string; line : int; column : int }

type typ =
  | Int | Float (* source compatibility aliases; checked IR canonicalizes these *)
  | I8 | U8 | I16 | U16 | I32 | U32 | I64 | U64 | F32 | F64
  | Bool | String | File | Box of typ | Vec of typ | Slice of typ | Ptr of typ | Ref of bool * typ
  | Named of string | Type_var of string | Apply of string * typ list | Tuple of typ list | Unit
  | Function of typ list * typ
type mode = Explc | Jit | Bb
type intrinsic = Size_of | Align_of

type expr = { node : expr_node; span : span }
and expr_node =
  | Int_lit of string
  | Float_lit of float
  | String_lit of string
  | Bool_lit of bool
  | Var of string
  | Unary of string * expr
  | Binary of string * expr * expr
  | Call of string * expr list
  | Generic_call of string * typ list * expr list
  | Intrinsic of intrinsic * typ list * expr list
  | Vec_lit of expr list
  | Index of expr * expr
  | Method of expr * string * expr list
  | Borrow of bool * expr
  | Struct_lit of string * (string * expr * span) list
  | Generic_struct_lit of string * typ list * (string * expr * span) list
  | Field of expr * string
  | Tuple_index of expr * string
  | Try of expr
  | Tuple_lit of expr list
  | Variant_lit of string * typ list * string * expr option
  | Match of expr * match_arm list
  | If_expr of expr * expr * expr
  | Match_control of string * typ * expr * (pattern * expr * stmt list * expr option) list
and pattern = { pattern_node : pattern_node; pattern_span : span }
and pattern_node =
  | Wildcard_pattern | Binding_pattern of string
  | Literal_pattern of expr | Tuple_pattern of pattern list
  | Variant_pattern of string * string * pattern option
and match_arm = { pattern : pattern; body : stmt list; tail : expr option; arm_span : span }
and stmt = { node : stmt_node; span : span }
and stmt_node =
  | Let of bool * string * typ option * expr
  | Let_pattern of bool * pattern * typ option * expr
  | Assign of string * expr
  | Field_assign of string * string * expr
  | Index_assign of expr * expr * expr
  | Deref_assign of expr * expr
  | Expr of expr
  | Return of expr option
  | If of expr * stmt list * stmt list
  | While of expr * stmt list
  | For of pattern * expr * stmt list
  | Block of stmt list
  | Scope of mode list * stmt list
  | Break
  | Continue

type param = { name : string; typ : typ; span : span }
type struct_field = { field_name : string; field_type : typ; field_span : span }
type struct_decl = { struct_name : string; type_params : string list; fields : struct_field list; struct_span : span }
type enum_variant = { variant_name : string; payload : typ option; variant_span : span }
type enum_decl = { enum_name : string; type_params : string list; variants : enum_variant list; enum_span : span }
type module_origin = Project | Toolchain
type import_decl = { import_name : string; import_span : span; import_origin : module_origin; import_alias : (string * span) option }
type func = {
  name : string;
  is_test : bool;
  type_params : string list;
  mode_set : mode list;
  params : param list;
  return_type : typ;
  body : stmt list;
  span : span;
}
type program = {
  module_decl : (string * span) option;
  imports : import_decl list;
  global_mode_set : mode list;
  structs : struct_decl list;
  enums : enum_decl list;
  functions : func list;
}

let rec string_of_typ = function
  | Int -> "Int" | Float -> "Float" | Bool -> "Bool" | String -> "String" | File -> "File"
  | I8 -> "I8" | U8 -> "U8" | I16 -> "I16" | U16 -> "U16"
  | I32 -> "I32" | U32 -> "U32" | I64 -> "I64" | U64 -> "U64"
  | F32 -> "F32" | F64 -> "F64"
  | Box element -> "core.box.Box<" ^ string_of_typ element ^ ">"
  | Vec element -> "Vec<" ^ string_of_typ element ^ ">" | Unit -> "Unit"
  | Slice element -> "Slice<" ^ string_of_typ element ^ ">"
  | Ptr element -> "Ptr<" ^ string_of_typ element ^ ">"
  | Ref (mutable_, target) -> "&" ^ (if mutable_ then "mut " else "") ^ string_of_typ target
  | Named name -> name
  | Type_var name -> name
  | Apply (name, args) -> name ^ "<" ^ String.concat "," (List.map string_of_typ args) ^ ">"
  | Tuple xs -> "(" ^ String.concat ", " (List.map string_of_typ xs) ^ ")"
  | Function (params,result) ->
      "fn(" ^ String.concat ", " (List.map string_of_typ params) ^ ") -> " ^ string_of_typ result
let string_of_mode = function Explc -> "explc" | Jit -> "jit" | Bb -> "bb"
