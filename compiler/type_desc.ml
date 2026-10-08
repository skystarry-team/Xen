(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

type abi = Gp | Xmm32 | Xmm64 | Indirect
type drop = No_drop | Drop_string | Drop_vec | Drop_file | Drop_box | Drop_struct
type t = {
  size : int; alignment : int; trivial_copy : bool; move_only : bool;
  drop : drop; equality : bool; abi : abi;
}

let canonical = function Int -> I64 | Float -> F64 | t -> t
let rec canonicalize = function
  | Box t -> Box (canonicalize t)
  | Vec t -> Vec (canonicalize t) | Slice t -> Slice (canonicalize t) | Ptr t -> Ptr (canonicalize t)
  | Ref (m,t) -> Ref (m,canonicalize t)
  | Apply (n,xs) -> Apply(n,List.map canonicalize xs)
  | Tuple xs -> Tuple(List.map canonicalize xs)
  | Function (xs,r) -> Function(List.map canonicalize xs,canonicalize r)
  | t -> canonical t

let is_signed_int t = match canonical t with I8|I16|I32|I64 -> true | _ -> false
let is_unsigned_int t = match canonical t with U8|U16|U32|U64 -> true | _ -> false
let is_integer t = is_signed_int t || is_unsigned_int t
let is_float t = match canonical t with F32|F64 -> true | _ -> false
let is_numeric t = is_integer t || is_float t
let bits t = match canonical t with
  | I8|U8 -> 8 | I16|U16 -> 16 | I32|U32|F32 -> 32
  | I64|U64|F64 -> 64 | _ -> invalid_arg "Type_desc.bits"
let align_up n a = ((n + a - 1) / a) * a

let rec describe ?(named=(fun _ -> invalid_arg "named type descriptor unavailable")) typ =
  match canonical typ with
  | I8|U8|Bool -> {size=1;alignment=1;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Gp}
  | I16|U16 -> {size=2;alignment=2;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Gp}
  | I32|U32 -> {size=4;alignment=4;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Gp}
  | F32 -> {size=4;alignment=4;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Xmm32}
  | I64|U64 -> {size=8;alignment=8;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Gp}
  | F64 -> {size=8;alignment=8;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Xmm64}
  | File|Ref _ -> {size=8;alignment=8;trivial_copy=true;move_only=(typ=File);drop=(if typ=File then Drop_file else No_drop);equality=false;abi=Gp}
  | Function _ -> {size=8;alignment=8;trivial_copy=true;move_only=false;drop=No_drop;equality=false;abi=Gp}
  | Ptr _ -> {size=16;alignment=8;trivial_copy=true;move_only=false;drop=No_drop;equality=false;abi=Indirect}
  | Box _ -> {size=8;alignment=8;trivial_copy=false;move_only=true;drop=Drop_box;equality=false;abi=Gp}
  | String -> {size=24;alignment=8;trivial_copy=false;move_only=false;drop=Drop_string;equality=true;abi=Indirect}
  (* A Vec descriptor has a fixed representation.  Element ownership and
     equality are properties of operations on the Vec, not of its layout;
     chasing them here makes valid Node -> Vec<Node> layouts recursive. *)
  | Vec _ ->
      {size=24;alignment=8;trivial_copy=false;move_only=false;drop=Drop_vec;equality=false;abi=Indirect}
  | Slice _ -> {size=16;alignment=8;trivial_copy=true;move_only=false;drop=No_drop;equality=false;abi=Indirect}
  | Named n -> named n
  | Apply (n,args) -> named (string_of_typ (Apply(n,args)))
  | Tuple elements ->
      let offset=ref 0 and alignment=ref 1 and trivial=ref true and move=ref false in
      List.iter(fun t->let d=describe ~named t in offset:=align_up !offset d.alignment+d.size;
        alignment:=max !alignment d.alignment;trivial:=!trivial&&d.trivial_copy;move:=!move||d.move_only)elements;
      {size=align_up !offset !alignment;alignment= !alignment;trivial_copy= !trivial;
       move_only= !move;drop=(if !trivial then No_drop else Drop_struct);equality=false;abi=Indirect}
  | Type_var n -> invalid_arg ("unresolved type variable "^n)
  | Unit -> {size=0;alignment=1;trivial_copy=true;move_only=false;drop=No_drop;equality=true;abi=Gp}
  | Int|Float -> assert false

let min_signed bits = if bits=64 then Int64.min_int else Int64.neg (Int64.shift_left 1L (bits-1))
let max_signed bits = if bits=64 then Int64.max_int else Int64.sub (Int64.shift_left 1L (bits-1)) 1L
let max_unsigned bits = if bits=64 then Int64.minus_one else Int64.sub (Int64.shift_left 1L bits) 1L
