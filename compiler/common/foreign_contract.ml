(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
let scalar t=Type_desc.is_numeric t
let argument = function Ptr _->true|t->scalar t
let validate symbol result inputs =
  let ident c=(c>='a'&&c<='z')||(c>='A'&&c<='Z')||c='_'in
  if symbol.library="" || String.contains symbol.library '\000' then Error "extern_call requires a nonempty library without NUL"
  else if symbol.symbol="" || not(ident symbol.symbol.[0]) ||
    not(String.for_all(fun c->ident c||(c>='0'&&c<='9'))symbol.symbol)then Error "extern_call requires a C symbol name"
  else if symbol.symbol="__libc_start_main" || String.starts_with ~prefix:"__xen_" symbol.symbol then Error "extern_call symbol is reserved by the runtime"
  else if List.length inputs>6 then Error "extern_call supports at most six non-variadic C arguments"
  else if not(List.for_all argument inputs)then Error "extern_call arguments must be numeric scalars or Ptr<T>"
  else if result<>Unit && not(scalar result)then Error "extern_call result must be a numeric scalar or Unit (return pointer addresses as Int/U64)"
  else Ok ()
let register signatures symbol result inputs =
  let signature=symbol.library,result,inputs in
  match Hashtbl.find_opt signatures symbol.symbol with
  |None->Hashtbl.add signatures symbol.symbol signature;Ok()
  |Some previous when previous=signature->Ok()
  |Some _->Error("extern_call has conflicting library or C signature for symbol '"^symbol.symbol^"'")
