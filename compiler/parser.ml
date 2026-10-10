(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
open Lexer

exception Error of span * string
type state = { tokens : token array; mutable position : int; mutable pending_eq : bool;
  mutable import_names : string list }
let known_structs : (string, unit) Hashtbl.t = Hashtbl.create 16
let known_enums : (string, unit) Hashtbl.t = Hashtbl.create 16
let current_type_params : (string, unit) Hashtbl.t = Hashtbl.create 8

let peek state =
  state.tokens.(min state.position (Array.length state.tokens - 1))
let bump state =
  let token = peek state in
  if state.position < Array.length state.tokens - 1 then
    state.position <- state.position + 1;
  token
let fail state message = raise (Error ((peek state).span, message))
let accept state kind =
  if kind = Eq && state.pending_eq then (state.pending_eq <- false; true)
  else if (peek state).kind = kind then (ignore (bump state); true) else false
let expect state kind name = if not (accept state kind) then fail state ("expected " ^ name)
let identifier state = match bump state with
  | { kind = Ident name; span } -> name, span | _ -> fail state "expected identifier"
let expression span node : Ast.expr = { node; span }
let statement span node : Ast.stmt = { node; span }

let dotted_name state =
  let first, span = identifier state in
  let rec loop parts =
    if accept state Dot then let part, _ = identifier state in loop (part :: parts)
    else String.concat "." (List.rev parts), span
  in loop [first]

let normalize_modes modes =
  List.filter (fun mode -> List.mem mode modes) [Explc; Jit; Bb]

let parse_mode_list state ~context =
  expect state Lbracket "[";
  if (peek state).kind = Rbracket then fail state (context ^ " mode list cannot be empty");
  let rec modes seen =
    let name, name_span = identifier state in
    let mode = match name with
      | "explc" -> Explc | "jit" -> Jit | "bb" -> Bb
      | _ -> raise (Error (name_span, "unknown " ^ context ^ " mode '" ^ name ^ "'"))
    in
    if List.mem mode seen then raise (Error (name_span, "duplicate " ^ context ^ " mode '" ^ name ^ "'"));
    if accept state Comma then
      if (peek state).kind = Rbracket then fail state ("trailing comma in " ^ context ^ " mode list")
      else modes (mode :: seen)
    else (expect state Rbracket "]"; normalize_modes (List.rev (mode :: seen)))
  in modes []

let rec parse_type_arguments state =
  if not (accept state Lt) then [] else
  let rec loop acc =
    let t = parse_type state in
    if accept state Comma then loop (t :: acc)
    else (if accept state Gt_eq then state.pending_eq <- true else expect state Gt ">"; List.rev (t :: acc))
  in loop []
and parse_type state = match bump state with
  | { kind = Fn; _ } ->
      expect state Lparen "(";
      let rec params acc =
        if accept state Rparen then List.rev acc else
        let t=parse_type state in
        if accept state Comma then params(t::acc)
        else(expect state Rparen ")";List.rev(t::acc)) in
      let params=params [] in expect state Arrow "->";
      Function(params,parse_type state)
  | { kind = Amp; _ } ->
      let mutable_ = accept state Mut in
      let target = parse_type state in
      (match target with
       | Int | Float | I8 | U8 | I16 | U16 | I32 | U32 | I64 | U64 | F32 | F64
       | Bool | String | File | Box _ | Vec _ | Slice _ | Ptr _
       | Named _ | Apply _ | Tuple _ -> Ref (mutable_, target)
       | Function _ -> fail state "function references are not supported"
       | Type_var _ -> Ref (mutable_, target)
       | Ref _ -> fail state "reference-to-reference types are not supported"
       | Unit -> fail state "Unit cannot be referenced")
  | { kind = Ident "Int"; _ } -> Int
  | { kind = Ident "Float"; _ } -> Float
  | { kind = Ident "I8"; _ } -> I8 | { kind = Ident "U8"; _ } -> U8
  | { kind = Ident "I16"; _ } -> I16 | { kind = Ident "U16"; _ } -> U16
  | { kind = Ident "I32"; _ } -> I32 | { kind = Ident "U32"; _ } -> U32
  | { kind = Ident "I64"; _ } -> I64 | { kind = Ident "U64"; _ } -> U64
  | { kind = Ident "F32"; _ } -> F32 | { kind = Ident "F64"; _ } -> F64
  | { kind = Ident "Bool"; _ } -> Bool
  | { kind = Ident "String"; _ } -> String
  | { kind = Ident "File"; _ } -> File
  | { kind = Ident "Unit"; _ } -> Unit
  | { kind = Lparen; _ } ->
      if accept state Rparen then Unit else
      let first = parse_type state in
      if not (accept state Comma) then (expect state Rparen ")"; first) else
      let rec rest acc =
        let t = parse_type state in
        if accept state Comma then rest (t :: acc)
        else (expect state Rparen ")"; Tuple (List.rev (t :: acc)))
      in rest [first]
  | { kind = Ident "Vec"; _ } ->
      expect state Lt "<";
      let element = parse_type state in
      if accept state Gt_eq then state.pending_eq <- true else expect state Gt ">";
      Vec element
  | { kind = Ident "Slice"; _ } ->
      expect state Lt "<";
      let element = parse_type state in
      if accept state Gt_eq then state.pending_eq <- true else expect state Gt ">";
      Slice element
  | { kind = Ident "Ptr"; _ } ->
      expect state Lt "<";
      let element = parse_type state in
      if accept state Gt_eq then state.pending_eq <- true else expect state Gt ">";
      Ptr element
  | { kind = Ident name; _ } ->
      let rec rest parts = if accept state Dot then let n,_=identifier state in rest(n::parts)
        else String.concat "." (List.rev parts) in
      let name = rest [name] in
      if Hashtbl.mem current_type_params name then Type_var name else
      let args = parse_type_arguments state in
      if args=[] then Named name else Apply (name,args)
  | _ -> fail state "expected type"

let rec parse_pattern state =
  let token=bump state in
  let pattern_node = match token.kind with
  | Ident "ref" when (match (peek state).kind with Ident _|Mut->true|_->false) ->
      let name,_=identifier state in Ref_binding_pattern name
  | Ident "_" -> Wildcard_pattern
  | Int_lit s -> Literal_pattern(expression token.span(Int_lit s))
  | Float_lit s -> Literal_pattern(expression token.span(Float_lit(float_of_string s)))
  | String_lit s -> Literal_pattern(expression token.span(String_lit s))
  | True -> Literal_pattern(expression token.span(Bool_lit true))
  | False -> Literal_pattern(expression token.span(Bool_lit false))
  | Lparen ->
      let first=parse_pattern state in expect state Comma ",";
      let rec items acc = let p=parse_pattern state in if accept state Comma then items(p::acc)
        else(expect state Rparen ")";Tuple_pattern(List.rev(p::acc))) in items[first]
  | Ident first ->
      if accept state Dot then let second,_=identifier state in
        let rec qualified parts =
          if accept state Dot then let part,_=identifier state in qualified(part::parts)
          else List.rev parts in
        let parts=qualified[second;first] in
        let variant=List.hd(List.rev parts) in
        let owner=String.concat "." (List.rev(List.tl(List.rev parts))) in
        let payload=if accept state Lparen then let p=parse_pattern state in expect state Rparen ")";Some p else None in
        Variant_pattern(owner,variant,payload)
      else Binding_pattern first
  | _ -> raise(Error(token.span,"expected pattern")) in
  {pattern_node;pattern_span=token.span}

let parse_statement_hook : (state -> Ast.stmt) ref = ref (fun state->fail state "statement parser unavailable")

let rec parse_expr state = range state
and range state =
  let (start : Ast.expr) = logical_or state in
  if accept state Dot_dot then begin
    let (finish : Ast.expr) = logical_or state in
    if (peek state).kind = Dot_dot then
      raise (Error ((peek state).span, "chained range expressions are not supported"));
    expression start.span (Struct_lit ("Range", [
      "current", start, start.span;
      "finish", finish, finish.span;
    ]))
  end else start
and logical_or state = binary_left state logical_and [Or_or, "||"]
and logical_and state = binary_left state equality [And_and, "&&"]
and equality state = binary_left state comparison [Eq_eq, "=="; Bang_eq, "!="]
and comparison state = binary_left state additive
    [Lt, "<"; Lt_eq, "<="; Gt, ">"; Gt_eq, ">="]
and additive state = binary_left state multiplicative [Plus, "+"; Minus, "-"]
and multiplicative state = binary_left state unary [Star, "*"; Slash, "/"; Percent, "%"]
and binary_left state next operators =
  let rec loop (left : Ast.expr) =
    match List.find_opt (fun (kind, _) -> (peek state).kind = kind) operators with
    | None -> left
    | Some (_, operator) ->
        ignore (bump state);
        loop (expression left.span (Binary (operator, left, next state)))
  in
  loop (next state)
and unary state =
  let token = peek state in
  match token.kind with
  | Minus ->
      ignore (bump state);
      expression token.span (Unary ("-", unary state))
  | Bang -> ignore (bump state); expression token.span (Unary ("!", unary state))
  | Star -> ignore (bump state); expression token.span (Unary ("*", unary state))
  | Amp ->
      ignore (bump state);
      let mutable_ = accept state Mut in
      expression token.span (Borrow (mutable_, unary state))
  | _ -> postfix state
and postfix state =
  let rec loop (value : Ast.expr) =
    if accept state Lbracket then
      let index = parse_expr state in expect state Rbracket "]";
      loop (expression value.span (Index (value, index)))
    else if accept state Question then loop (expression value.span (Try value))
    else match (peek state).kind with
      | Dot ->
          let dot = bump state in
          (match (peek state).kind with
          | Int_lit digits ->
              ignore (bump state);
              if String.length digits > 1 && digits.[0] = '0' then
                raise (Error (dot.span, "tuple index cannot contain leading zeros"));
              loop (expression dot.span (Tuple_index (value, digits)))
          | _ -> let name, name_span = identifier state in
          if String.length name >= 7 && String.sub name 0 7 = "__item_" then
            raise (Error (name_span, "tuple representation fields are compiler-private; use '.N' tuple access"));
          if (peek state).kind <> Lparen then loop (expression value.span (Field (value, name))) else begin expect state Lparen "(";
          let rec arguments values =
            if accept state Rparen then List.rev values
            else let argument = parse_expr state in
              if accept state Comma then arguments (argument :: values)
              else (expect state Rparen ")"; List.rev (argument :: values))
          in loop (expression value.span (Method (value, name, arguments []))) end)
      | _ -> value
  in loop (primary state)
and primary state =
  let token = bump state in
  let arguments () =
    let rec values acc =
      if accept state Rparen then List.rev acc
      else let value=parse_expr state in
        if accept state Comma then values(value::acc)
        else (expect state Rparen ")";List.rev(value::acc))
    in values [] in
  let struct_fields () =
    let rec fields values =
      if accept state Rbrace then List.rev values
      else let field, span=identifier state in expect state Colon ":";let value=parse_expr state in
        if accept state Comma then
          (if (peek state).kind=Rbrace then(ignore(bump state);List.rev((field,value,span)::values))
           else fields((field,value,span)::values))
        else(expect state Rbrace "}";List.rev((field,value,span)::values))
    in fields [] in
  match token.kind with
  | If ->
      let condition=parse_expr state in
      let branch label =
        expect state Lbrace "{";
        if (peek state).kind=Rbrace then raise(Error((peek state).span,label^" branch must contain an expression"));
        (match (peek state).kind with Let|Return|While|For|Break|Continue|Hash|Lbrace->
          raise(Error((peek state).span,"if expression branches must contain a single expression"))|_->());
        let value=parse_expr state in
        if accept state Semi then raise(Error(value.span,"if expression branches must contain a single expression"));
        if (peek state).kind<>Rbrace then raise(Error((peek state).span,"if expression branches must contain a single expression"));
        expect state Rbrace "}";value in
      let yes=branch "if" in
      if not(accept state Else) then raise(Error(token.span,"if expression requires a final else branch"));
      let no=if (peek state).kind=If then primary state else branch "else" in
      expression token.span(If_expr(condition,yes,no))
  | Match ->
      let value=parse_expr state in expect state Lbrace "{";
      let rec arms acc =
        if accept state Rbrace then List.rev acc else
        let pattern=parse_pattern state in expect state Fat_arrow "=>";
        let body,tail = if accept state Lbrace then
          let rec block statements =
            if accept state Rbrace then List.rev statements,None else
            match (peek state).kind with
            | If ->
                let saved_position=state.position and saved_pending_eq=state.pending_eq in
                (try
                   let value=parse_expr state in
                   if (peek state).kind<>Rbrace then raise(Error((peek state).span,"if expression is not the match arm tail"));
                   expect state Rbrace "}";List.rev statements,Some value
                 with Error _->
                   state.position<-saved_position;state.pending_eq<-saved_pending_eq;
                   block((!parse_statement_hook state)::statements))
            | Let|Return|While|For|Break|Continue|Hash|Lbrace -> block((!parse_statement_hook state)::statements)
            | _ -> let e=parse_expr state in
                if accept state Eq then
                  let value=parse_expr state in ignore(accept state Semi);
                  let assigned=match e.node with
                    |Var n->Assign(n,value)|Field({node=Var n;_},f)->Field_assign(n,f,value)
                    |Tuple_index({node=Var n;_},i)->Field_assign(n,"__item_"^i,value)
                    |Field _|Tuple_index _->Place_assign(e,value)
                    |Index(a,b)->Index_assign(a,b,value)|Unary("*",r)->Deref_assign(r,value)
                    |_->raise(Error(e.span,"assignment target must be a local variable, dereference, or vector element")) in
                  block(statement e.span assigned::statements)
                else if accept state Semi then block(statement e.span(Expr e)::statements)
                else (expect state Rbrace "}";List.rev statements,Some e) in block []
        else [],Some(parse_expr state) in
        let arm={pattern;body;tail;arm_span=pattern.pattern_span} in
        if accept state Comma then arms(arm::acc)
        else(expect state Rbrace "}";List.rev(arm::acc)) in
      expression token.span(Match(value,arms []))
  | Int_lit digits -> expression token.span (Int_lit digits)
  | Float_lit digits ->
      let value = float_of_string digits in
      (match classify_float value with
       | FP_infinite | FP_nan -> raise (Error (token.span, "float literal is outside finite Float range"))
       | _ -> expression token.span (Float_lit value))
  | String_lit bytes -> expression token.span (String_lit bytes)
  | True -> expression token.span (Bool_lit true)
  | False -> expression token.span (Bool_lit false)
  | Ident name ->
      (* A dotted sequence followed by '(' or '{' is retained as a qualified
         declaration reference. Other dotted sequences remain ordinary field
         and method postfix expressions. *)
      let saved=state.position in
      let rec probe parts =
        if (peek state).kind = Dot && state.position + 1 < Array.length state.tokens &&
           (match state.tokens.(state.position + 1).kind with Ident _ -> true | _ -> false)
        then (ignore (bump state); let part,_=identifier state in probe(part::parts))
        else List.rev parts in
      let parts=probe [name] in
      let type_args =
        if (peek state).kind=Lt then
          let before=state.position in
          try let xs=parse_type_arguments state in
            (match (peek state).kind with Lparen|Lbrace|Dot->xs|_->state.position<-before;[])
          with Error _ -> state.position<-before;[]
        else [] in
      (* A generic argument list can follow the final component of a qualified
         path (module.name<T>), or precede an enum variant (Option<T>.Some).
         Probe the suffix again after parsing type arguments for the latter. *)
      let parts=probe (List.rev parts) in
      let full=String.concat "." parts in
      let prefix = String.concat "." (List.rev (List.tl (List.rev parts))) in
      let owner_parts=if List.length parts>=2 then List.rev(List.tl(List.rev parts))else[] in
      let enum_part=match List.rev owner_parts with x::_->x|[]->name in
      if List.length parts >= 2 && (Hashtbl.mem known_enums name ||
        (not(List.mem prefix state.import_names) && String.length enum_part>0 && Char.uppercase_ascii enum_part.[0]=enum_part.[0])) then
        let variant=List.hd(List.rev parts) in
        let enum_name=String.concat "." (List.rev(List.tl(List.rev parts))) in
        let payload=if accept state Lparen then
          let xs=arguments() in match xs with [x]->Some x|_->raise(Error(token.span,"enum variant payload expects one value"))
          else None in
        expression token.span (Variant_lit(enum_name,type_args,variant,payload))
      else if (List.length parts=1 || List.mem prefix state.import_names) && accept state Lparen then let xs=arguments() in
        expression token.span (if type_args=[] then Call(full,xs) else Generic_call(full,type_args,xs))
      else if (List.length parts=1 || List.mem prefix state.import_names) && (type_args<>[] || Hashtbl.mem known_structs name || List.mem prefix state.import_names) && accept state Lbrace then let fs=struct_fields() in
        expression token.span (if type_args=[] then Struct_lit(full,fs) else Generic_struct_lit(full,type_args,fs))
      else if List.length parts > 1 && List.mem prefix state.import_names then
        expression token.span (Var full)
      else if type_args<>[] || List.mem prefix state.import_names then
        raise(Error(token.span,"expected generic call, aggregate literal, or enum variant"))
      else (state.position<-saved;expression token.span (Var name))
  | Lparen ->
      if accept state Rparen then expression token.span (Tuple_lit []) else
      let first=parse_expr state in
      if not(accept state Comma) then (expect state Rparen ")";first) else
      let rec elements acc = let value=parse_expr state in
        if accept state Comma then elements(value::acc)
        else(expect state Rparen ")";expression token.span(Tuple_lit(List.rev(value::acc)))) in
      elements [first]
  | Lbracket ->
      let rec elements values =
        if accept state Rbracket then List.rev values
        else let value = parse_expr state in
          if accept state Comma then elements (value :: values)
          else (expect state Rbracket "]"; List.rev (value :: values))
      in expression token.span (Vec_lit (elements []))
  | Dot -> raise (Error (token.span, "float literal must have digits before the decimal point"))
  | _ -> fail state "expected expression"

let optional_semi state = ignore (accept state Semi)

let rec parse_statement state =
  let start = (peek state).span in
  match (peek state).kind with
  | Lbrace -> statement start (Block (parse_block state))
  | Hash ->
      ignore (bump state);
      let keyword, _ = identifier state in
      if keyword <> "scope" then fail state "expected scope after #";
      let modes = parse_mode_list state ~context:"scope" in
      statement start (Scope (modes, parse_block state))
  | Let ->
      ignore (bump state); let mutable_ = accept state Mut in
      let pattern=parse_pattern state in
      let rec irrefutable p=match p.pattern_node with
        |Binding_pattern _|Wildcard_pattern->()
        |Tuple_pattern ps->List.iter irrefutable ps
        |_->raise(Error(p.pattern_span,"let pattern supports bindings, _, and nested tuples")) in
      irrefutable pattern;
      let annotation = if accept state Colon then Some (parse_type state) else None in
      expect state Eq "=";
      let value = parse_expr state in optional_semi state;
      statement start (match pattern.pattern_node with
        |Binding_pattern name->Let(mutable_,name,annotation,value)
        |_->Let_pattern(mutable_,pattern,annotation,value))
  | Return ->
      ignore (bump state);
      if accept state Semi || (peek state).kind = Rbrace then statement start (Return None)
      else let value = parse_expr state in optional_semi state; statement start (Return (Some value))
  | If ->
      ignore (bump state); let condition = parse_expr state in let yes = parse_block state in
      let no = if accept state Else then
        if (peek state).kind=If then [parse_statement state] else parse_block state
        else [] in statement start (If (condition, yes, no))
  | While ->
      ignore (bump state); let condition = parse_expr state in
      statement start (While (condition, parse_block state))
  | For ->
      ignore(bump state);let pattern=parse_pattern state in expect state In "in";
      let iterator=parse_expr state in statement start(For(pattern,iterator,parse_block state))
  | Break -> ignore (bump state); optional_semi state; statement start Break
  | Continue -> ignore (bump state); optional_semi state; statement start Continue
  | _ ->
      let left = parse_expr state in
      if accept state Eq then match left.node with
        | Var name -> let value = parse_expr state in optional_semi state; statement start (Assign (name, value))
        | Field ({node=Var name;_}, field) -> let value=parse_expr state in optional_semi state; statement start (Field_assign(name,field,value))
        | Tuple_index ({node=Var name;_}, index) -> let value=parse_expr state in optional_semi state; statement start (Field_assign(name,"__item_"^index,value))
        | Field _ | Tuple_index _ -> let value=parse_expr state in optional_semi state; statement start (Place_assign(left,value))
        | Index (receiver, index) -> let value = parse_expr state in optional_semi state;
            statement start (Index_assign (receiver, index, value))
        | Unary ("*", reference) -> let value = parse_expr state in optional_semi state;
            statement start (Deref_assign (reference, value))
        | _ -> raise (Error (left.span, "assignment target must be a local variable, dereference, or vector element"))
      else (optional_semi state; statement start (Expr left))
and parse_block state =
  expect state Lbrace "{";
  let rec statements values =
    if accept state Rbrace then List.rev values
    else if (peek state).kind = Eof then fail state "unterminated block"
    else statements (parse_statement state :: values)
  in statements []

let () = parse_statement_hook := parse_statement

let parse_param state =
  let name, span = identifier state in expect state Colon ":";
  { name; typ = parse_type state; span }

let parse_type_params state =
  if not(accept state Lt) then [] else
  let rec params seen acc =
    let name,span=identifier state in
    if List.mem name seen then raise(Error(span,"duplicate type parameter '"^name^"'"));
    if accept state Comma then params(name::seen)(name::acc)
    else (expect state Gt ">";List.rev(name::acc)) in
  params [] []

let with_type_params params f =
  Hashtbl.clear current_type_params;List.iter(fun n->Hashtbl.add current_type_params n())params;
  Fun.protect ~finally:(fun()->Hashtbl.clear current_type_params) f

let parse_attribute state =
  let span = (peek state).span in
  expect state Hash "#"; expect state Bang "!"; expect state Lbracket "[";
  if (peek state).kind = Rbracket then fail state "mode attribute cannot be empty";
  let rec modes seen =
    let name, name_span = identifier state in
    let mode = match name with
      | "explc" -> Explc | "jit" -> Jit | "bb" -> Bb
      | _ -> raise (Error (name_span, "unknown function mode '" ^ name ^ "'"))
    in
    if List.mem mode seen then raise (Error (name_span, "duplicate function mode '" ^ name ^ "'"));
    if accept state Comma then
      if (peek state).kind = Rbracket then fail state "trailing comma in mode attribute"
      else modes (mode :: seen)
    else (expect state Rbracket "]"; List.rev (mode :: seen))
  in
  let modes = modes [] in
  if (peek state).span.line = span.line then fail state "function declaration must start on a new line after mode attribute";
  modes

let parse_func state =
  let rec attributes modes =
    if (peek state).kind = Hash then
      let added = parse_attribute state in
      (match List.find_opt (fun mode -> List.mem mode modes) added with
       | Some mode -> raise (Error ((peek state).span,
           "duplicate function mode '" ^ string_of_mode mode ^ "'"))
       | None -> attributes (added @ modes))
    else modes
  in
  let mode_set = normalize_modes (attributes []) in
  let is_test=match (peek state).kind with Ident "test"->ignore(bump state);true|_->false in
  let span = (peek state).span in expect state Fn "fn";
  let name, _ = identifier state in
  let type_params=parse_type_params state in
  with_type_params type_params (fun()->
  expect state Lparen "(";
  let rec params values =
    if accept state Rparen then List.rev values
    else let param = parse_param state in
      if accept state Comma then params (param :: values)
      else (expect state Rparen ")"; List.rev (param :: values))
  in
  let params = params [] in
  let return_type = if accept state Arrow then parse_type state else Unit in
  { name; is_test; type_params; mode_set; params; return_type; body = parse_block state; span })

let method_symbol owner name = "__method$" ^ owner ^ "$" ^ name

let parse_impl state =
  let impl_span=(peek state).span in let keyword,_=identifier state in
  if keyword<>"impl" then assert false;
  let type_params=parse_type_params state in
  with_type_params type_params (fun () ->
    let owner_type=parse_type state in
    let owner_name=match owner_type with Named n|Apply(n,_)->n|_->
      raise(Error(impl_span,"impl owner must be a named struct type")) in
    expect state Lbrace "{";
    let rec methods out =
      if accept state Rbrace then List.rev out else
      let rec attributes modes = if (peek state).kind=Hash then attributes(parse_attribute state @ modes)else normalize_modes modes in
      let mode_set=attributes [] in
      let span=(peek state).span in expect state Fn "fn";let name,_=identifier state in
      expect state Lparen "(";
      let receiver_span=(peek state).span in
      let receiver_type =
        if accept state Amp then let mutable_=accept state Mut in
          let self,_=identifier state in if self<>"self" then raise(Error(receiver_span,"method receiver must be self"));
          Ref(mutable_,owner_type)
        else let self,_=identifier state in if self<>"self" then raise(Error(receiver_span,"method receiver must be self"));owner_type in
      let rec params acc =
        if accept state Rparen then List.rev acc
        else (expect state Comma ",";let p=parse_param state in params(p::acc)) in
      let params={name="self";typ=receiver_type;span=receiver_span}::params [] in
      let return_type=if accept state Arrow then parse_type state else Unit in
      let body=parse_block state in
      methods({name=method_symbol owner_name name;is_test=false;type_params;mode_set;params;return_type;body;span}::out) in
    methods [])

let parse_struct state =
  let struct_span=(peek state).span in let keyword,_=identifier state in
  if keyword<>"struct" then raise(Error(struct_span,"expected struct declaration or function"));
  let struct_name,_=identifier state in let type_params=parse_type_params state in
  with_type_params type_params (fun()->expect state Lbrace "{";
  let rec fields values = if accept state Rbrace then List.rev values else
    let field_name,field_span=identifier state in expect state Colon ":";
    let field_type=parse_type state in
    if accept state Comma then (if (peek state).kind=Rbrace then (ignore(bump state);List.rev({field_name;field_type;field_span}::values)) else fields({field_name;field_type;field_span}::values))
    else (expect state Rbrace "}";List.rev({field_name;field_type;field_span}::values)) in
  {struct_name;type_params;fields=fields [];struct_span})

let parse_enum state =
  let enum_span=(peek state).span in let keyword,_=identifier state in
  if keyword<>"enum" then assert false;
  let enum_name,_=identifier state in let type_params=parse_type_params state in
  with_type_params type_params (fun()->expect state Lbrace "{";
    let rec variants seen acc =
      if accept state Rbrace then List.rev acc else
      let variant_name,variant_span=identifier state in
      if List.mem variant_name seen then raise(Error(variant_span,"duplicate variant '"^variant_name^"'"));
      let payload=if accept state Lparen then let t=parse_type state in expect state Rparen ")";Some t else None in
      let item={variant_name;payload;variant_span} in
      if accept state Comma then variants(variant_name::seen)(item::acc)
      else(expect state Rbrace "}";List.rev(item::acc)) in
    {enum_name;type_params;variants=variants [] [];enum_span})

let parse ~file source =
  Hashtbl.clear known_structs;
  Hashtbl.clear known_enums;
  let state = { tokens = Array.of_list (Lexer.lex ~file source); position = 0; pending_eq = false; import_names=[] } in
  let module_decl =
    match (peek state).kind with
    | Ident "module" -> let _, keyword_span=identifier state in let name,_=dotted_name state in
        expect state Semi ";"; Some(name,keyword_span)
    | _ -> None in
  let rec parse_imports seen values = match (peek state).kind with
    | Ident ("import" | "use" as keyword) ->
        let _, import_span=identifier state in let name,_=dotted_name state in
        let import_alias=match (peek state).kind with
          | Ident "as"->ignore(bump state);Some(identifier state)
          | _->None in
        expect state Semi ";";
        if List.mem name seen then raise(Error(import_span,"duplicate module dependency '"^name^"'"));
        let import_origin=if keyword="use" then Toolchain else Project in
        parse_imports (name::seen) ({import_name=name;import_span;import_origin;import_alias}::values)
    | _ -> List.rev values in
  let imports=parse_imports [] [] in
  state.import_names <- List.concat_map (fun i->i.import_name::
    (match i.import_alias with None->[]|Some(n,_)->[n])) imports;
  let global_mode_set =
    if (peek state).kind = Hash && state.position + 1 < Array.length state.tokens &&
       state.tokens.(state.position + 1).kind <> Bang then begin
      let span = (peek state).span in ignore (bump state);
      let keyword, _ = identifier state in
      if keyword <> "global" then fail state "expected global after #";
      let modes = parse_mode_list state ~context:"global" in
      if (peek state).span.line = span.line then fail state "function declaration must start on a new line after global mode declaration";
      modes
    end else []
  in
  (* Struct names are collected before parsing bodies so field types may refer forward. *)
  let scan=ref state.position in while !scan < Array.length state.tokens do
    match state.tokens.(!scan).kind with
    | Ident "struct" when !scan+1<Array.length state.tokens -> (match state.tokens.(!scan+1).kind with Ident n->Hashtbl.replace known_structs n ()|_->()); incr scan
    | Ident "enum" when !scan+1<Array.length state.tokens -> (match state.tokens.(!scan+1).kind with Ident n->Hashtbl.replace known_enums n ()|_->()); incr scan
    | _->incr scan done;
  let rec declarations structs enums functions =
    if (peek state).kind = Eof then List.rev structs,List.rev enums,List.rev functions
    else if (peek state).kind = Hash && state.position + 1 < Array.length state.tokens &&
            state.tokens.(state.position + 1).kind <> Bang then
      fail state "#global must be the first declaration and may appear only once"
    else match (peek state).kind with
      |Ident "struct"->declarations(parse_struct state::structs)enums functions
      |Ident "enum"->declarations structs(parse_enum state::enums)functions
      |Ident "impl"->declarations structs enums(List.rev_append(parse_impl state)functions)
      |_->declarations structs enums(parse_func state::functions) in
  let structs,enums,functions=declarations [] [] [] in
  let aliases=List.filter_map(fun i->i.import_alias)imports in
  let root n=List.hd(String.split_on_char '.' n) in
  let roots=["std";"core"] @ List.map(fun i->root i.import_name)imports @
    (match module_decl with None->[]|Some(n,_)->[root n]) in
  let reserved=["Int";"Float";"I8";"U8";"I16";"U16";"I32";"U32";"I64";"U64";
    "F32";"F64";"Bool";"String";"File";"Unit";"Vec";"Slice";"Ptr";"Box";"Option";"Result";"Range";"_"] in
  let top=List.map(fun d->d.struct_name)structs @ List.map(fun d->d.enum_name)enums @ List.map(fun f->f.name)functions in
  let seen=Hashtbl.create 8 in
  List.iter(fun(n,span)->
    if Hashtbl.mem seen n then raise(Error(span,"duplicate module alias '"^n^"'"));
    if List.mem n (roots@reserved@top) then raise(Error(span,"module alias '"^n^"' conflicts with a declaration or reserved name"));
    Hashtbl.add seen n ())aliases;
  let binding name span=if Hashtbl.mem seen name then
    raise(Error(span,"binding '"^name^"' conflicts with module alias")) in
  let rec pattern p=match p.pattern_node with
    |Binding_pattern n|Ref_binding_pattern n->binding n p.pattern_span
    |Tuple_pattern ps->List.iter pattern ps
    |Variant_pattern(_,_,p)->Option.iter pattern p
    |Wildcard_pattern|Literal_pattern _->() in
  let rec expr (e:expr)=match e.node with
    |Match(x,arms)->expr x;List.iter(fun a->pattern a.pattern;List.iter stmt a.body;Option.iter expr a.tail)arms
    |Unary(_,x)|Borrow(_,x)|Field(x,_)|Tuple_index(x,_)|Try x->expr x
    |Binary(_,a,b)|Index(a,b)->expr a;expr b
    |Call(_,xs)|Generic_call(_,_,xs)|Intrinsic(_,_,xs)|Vec_lit xs|Tuple_lit xs->List.iter expr xs
    |Method(r,_,xs)->expr r;List.iter expr xs
    |Struct_lit(_,fs)|Generic_struct_lit(_,_,fs)->List.iter(fun(_,x,_)->expr x)fs
    |Variant_lit(_,_,_,x)->Option.iter expr x
    |If_expr(c,a,b)->List.iter expr[c;a;b]
    |Match_control _->assert false
    |Int_lit _|Float_lit _|String_lit _|Bool_lit _|Var _->()
  and stmt (s:stmt)=match s.node with
    |Let(_,n,_,x)->binding n s.span;expr x
    |Let_pattern(_,p,_,x)->pattern p;expr x
    |Assign(_,x)|Field_assign(_,_,x)|Expr x->expr x
    |Index_assign(a,b,c)->List.iter expr[a;b;c]|Deref_assign(a,b)|Place_assign(a,b)->expr a;expr b
    |Return x->Option.iter expr x
    |If(c,a,b)->expr c;List.iter stmt(a@b)|While(c,b)->expr c;List.iter stmt b
    |For(p,x,b)->pattern p;expr x;List.iter stmt b
    |Block b|Scope(_,b)->List.iter stmt b|Break|Continue->() in
  List.iter(fun f->List.iter(fun(p:param)->binding p.name p.span)f.params;
    List.iter(fun n->binding n f.span)f.type_params;List.iter stmt f.body)functions;
  List.iter(fun d->List.iter(fun n->binding n d.struct_span)d.type_params)structs;
  List.iter(fun d->List.iter(fun n->binding n d.enum_span)d.type_params)enums;
  { module_decl; imports; global_mode_set; structs; enums; functions }
