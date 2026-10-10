(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

(* IDs are dense within a function, and survive every analysis/cleanup pass. *)
type local_id = int
type value_id = local_id
type block_id = int
type scope_id = int
type function_id = int
type struct_field = { name : string; typ : typ; offset : int; owner_size : int }
type struct_layout = { name : string; fields : struct_field list; size : int; alignment : int; managed : bool }
type acquisition = Read | Copy | Clone | Move
type value = { id : value_id; typ : typ; span : span }
type projection = Field of struct_field | Element of value | Deref
type place = { root : local_id; projections : projection list; typ : typ; span : span }
type local = { id : local_id; name : string; typ : typ; span : span; scope : scope_id;
               owned : bool; temporary : bool; parameter : int option }
type scope = { id : scope_id; parent : scope_id option; mode_set : mode list;
               span : span; declarations : local_id list }
(* Operands are storage IDs, never nested expressions. *)
type rvalue =
  | Int_lit of int64 | Float_lit of float | String_lit of string | Bool_lit of bool
  | Unary of string * value | Binary of string * value * value
  | Call of string * value list | Function_address of string | Indirect_call of value * value list
  | Box_new of value | Box_take of value
  | Raw_alloc of typ * value | Raw_load of typ * value * value
  | Raw_store of typ * value * value * value | Raw_free of typ * value
  | Ptr_addr of typ * value | Ptr_len of value | Syscall of value list
  | Vec_lit of value list | Index of value * value | Vec_get of value * value | Vec_len of value
  | Slice_make of value * value * value | Slice_len of value | Slice_get of value * value
  | Vec_set of value * value * value | Vec_push of value * value | Vec_pop of value
  | Exchange of value * value | Vec_swap of value * value * value
  | Vec_replace of value * value * value
  | File_read of value | File_write of value * value | File_close of value | File_is_open of value
  | Struct_lit of struct_layout * (struct_field * value) list

type operation_node =
  | Storage_live of local_id | Storage_dead of local_id
  | Acquire of value * acquisition * place
  (* Reserved implicit mutable receivers allow observations while arguments
     are evaluated; activation happens at the mutating operation/call. *)
  | Borrow of value * bool * bool * place
  | Eval of value * rvalue
  | Initialize of place * value | Replace of place * value
  | Drop of place | Forget of place
  | Logical_call_enter of function_id
  | Logical_call_exit of function_id
  | Drop_flag of place * bool
  (* Call effects can reinitialize a caller field whose drop flag was cleared
     by an earlier move. These updates are elaborated from semantic summaries. *)

type operation = { node : operation_node; span : span; scope : scope_id }
type terminator = Branch of value * block_id * block_id | Jump of block_id
                | Return of value option | Stop

type block = { id : block_id; scope : scope_id; operations : operation list; terminator : terminator }
type func = { id : function_id; name : string; mode_set : mode list; params : local_id list;
              return_type : typ; locals : local array; scopes : scope array;
              blocks : block array; entry : block_id; span : span }
type program = { layouts : struct_layout list; enums : enum_decl list; functions : func list; entry : string }
(* The constructor is exposed only to the semantic pipeline, via this module's
   checked factory. Native_backend cannot accept a frontend tree. *)
type checked_program = Checked of program
let program (Checked p) = p

let place_of_value (v:value) = {root=v.id;projections=[];typ=v.typ;span=v.span}
let value_of_local (l:local) : value = {id=l.id;typ=l.typ;span=l.span}
let rvalue_uses = function
  | Int_lit _|Float_lit _|String_lit _|Bool_lit _|Function_address _ -> []
  | Box_new x|Box_take x|Unary(_,x)|Raw_alloc(_,x)|Raw_free(_,x)|Ptr_addr(_,x)|Ptr_len x|Vec_len x|Slice_len x
  | Vec_pop x|File_read x|File_close x|File_is_open x -> [x]
  | Binary(_,a,b)|Raw_load(_,a,b)|Index(a,b)|Vec_get(a,b)|Slice_get(a,b)|Vec_push(a,b)|File_write(a,b)|Exchange(a,b) -> [a;b]
  | Raw_store(_,a,b,c)|Slice_make(a,b,c)|Vec_set(a,b,c)|Vec_swap(a,b,c)|Vec_replace(a,b,c) -> [a;b;c]
  | Call(_,xs)|Syscall xs|Vec_lit xs -> xs
  | Indirect_call(c,xs) -> c::xs
  | Struct_lit(_,fs) -> List.map snd fs
let place_uses p = p.root :: List.filter_map(function Element v->Some v.id|_->None)p.projections
let uses op = match op.node with
  | Acquire(_,_,p)|Borrow(_,_,_,p)|Drop p|Forget p|Drop_flag(p,_) -> place_uses p
  | Eval(_,r) -> List.map(fun(v:value)->v.id)(rvalue_uses r)
  | Initialize(p,v)|Replace(p,v) -> v.id :: (if p.projections=[] then [] else place_uses p)
  | Storage_live _|Storage_dead _|Logical_call_enter _|Logical_call_exit _ -> []
let defines op = match op.node with
  | Acquire(v,_,_)|Borrow(v,_,_,_)|Eval(v,_) -> [v.id]
  | Initialize(p,_)|Replace(p,_) when p.projections=[] -> [p.root]
  | Storage_live id|Storage_dead id -> [id]
  | _ -> []
let successors = function Branch(_,a,b)->List.sort_uniq compare [a;b]|Jump b->[b]|Return _|Stop->[]
let terminator_uses = function Branch(v,_,_)|Return(Some v)->[v.id]|_->[]

exception Invalid of span * string
let verify program =
  let bad span s = raise(Invalid(span,"Semantic IR: "^s)) in
  let program_span={file="<ir>";line=1;column=1}in
  let names=Hashtbl.create 16 in
  List.iter(fun(f:func)->if Hashtbl.mem names f.name then bad f.span "duplicate function name";
    Hashtbl.add names f.name ())program.functions;
  if not(Hashtbl.mem names program.entry)then bad program_span "unknown program entry";
  let layout span name=match List.find_opt(fun(l:struct_layout)->l.name=name)program.layouts with
    |Some l->l|None->bad span "unknown aggregate layout"in
  let rec linear seen = function
    |File|Box _->true|Vec t->linear seen t
    |Named n when not(List.mem n seen)->List.exists(fun(f:struct_field)->match f.typ with
        Ptr _->true|t->linear(n::seen)t)(layout {file="<ir>";line=1;column=1} n).fields
    |_->false in
  let rec owns = function String|Vec _|File|Box _->true|Named n->List.exists(fun(f:struct_field)->owns f.typ)
      (layout {file="<ir>";line=1;column=1} n).fields|_->false in
  List.iteri(fun fid (f:func)->
    if f.id<>fid then bad f.span "unstable function ID";
    let local span id = if id<0||id>=Array.length f.locals then bad span "unknown local" else f.locals.(id) in
    let value (v:value) = let l=local v.span v.id in if l.typ<>v.typ then bad v.span "operand type differs from storage" in
    let rec concrete span = function
      |Int|Float|Type_var _|Apply _|Tuple _->bad span "non-concrete storage type"
      |Named n->ignore(layout span n)
      |Box t|Vec t|Slice t|Ptr t|Ref(_,t)->concrete span t
      |Function(ps,r)->List.iter(concrete span)(r::ps)|_->()in
    let place (p:place) =
      let l=local p.span p.root in
      let typ=List.fold_left(fun typ->function
        | Field field -> (match typ with Named n->
            let layout=layout p.span n in
            if not(List.mem field layout.fields)then bad p.span "invalid field projection";field.typ
          |_->bad p.span "field projection on non-aggregate")
        | Deref -> (match typ with Ref(_,t)|Box t->t|_->bad p.span "deref projection on non-reference or Box")
        | Element v -> value v;if v.typ<>I64 then bad v.span "index must be I64";
            (match typ with Vec t|Slice t->t|_->bad p.span "index projection on non-collection"))l.typ p.projections in
      if typ<>p.typ then bad p.span "place type differs from projection" in
    Array.iteri(fun id(l:local)->if id<>l.id then bad l.span "unstable local ID";
      concrete l.span l.typ;
      if l.scope<0||l.scope>=Array.length f.scopes then bad l.span "unknown local scope")f.locals;
    if Array.length f.scopes=0 then bad f.span "missing root scope";
    let declared=Array.make(Array.length f.locals)0 in
    Array.iteri(fun id(s:scope)->if s.id<>id then bad s.span "unstable scope ID";
      if (id=0)<>(s.parent=None)then bad s.span "invalid root scope";
      Option.iter(fun parent->if parent>=id||parent<0 then bad s.span "invalid scope parent")s.parent;
      Option.iter(fun parent->if not(List.for_all(fun mode->List.mem mode s.mode_set)f.scopes.(parent).mode_set)
        then bad s.span "scope lost an enclosing capability")s.parent;
      List.iter(fun id->if(local s.span id).scope<>s.id then bad s.span "scope declaration mismatch";
        declared.(id)<-declared.(id)+1)s.declarations)f.scopes;
    Array.iteri(fun id count->if count<>1 then bad f.locals.(id).span "local must be declared exactly once")declared;
    if f.scopes.(0).mode_set<>f.mode_set then bad f.span "function capability differs from root scope";
    let parameters=Hashtbl.create 8 in
    List.iteri(fun index id->let l=local f.span id in
      if Hashtbl.mem parameters id then bad l.span "duplicate parameter local";
      Hashtbl.add parameters id ();
      if l.parameter<>Some index||l.scope<>0 then bad l.span "parameter metadata mismatch")f.params;
    Array.iter(fun(l:local)->if l.parameter<>None&&not(Hashtbl.mem parameters l.id)
      then bad l.span "parameter missing from signature")f.locals;
    concrete f.span f.return_type;
    if f.entry<0||f.entry>=Array.length f.blocks then bad f.span "unknown entry block";
    Array.iteri(fun id(b:block)->if b.id<>id then bad f.span "unstable block ID";
      if b.scope<0||b.scope>=Array.length f.scopes then bad f.span "unknown block scope";
      let calls=ref [] in
      List.iter(fun (op:operation)->
        if op.scope<0||op.scope>=Array.length f.scopes then bad op.span "unknown operation scope";
        List.iter(fun id->ignore(local op.span id))(uses op @ defines op);
        (match op.node with
         | Acquire(v,kind,p)->value v;place p;if v.typ<>p.typ then bad op.span "acquisition type mismatch";
             if kind=Read&&(local v.span v.id).owned then bad op.span "observation cannot own storage";
             if kind=Copy && (owns p.typ||linear [] p.typ)then bad op.span "illegal ownership copy";
             if kind=Clone && linear [] p.typ then bad op.span "illegal ownership clone"
         | Borrow(v,m,reserved,p)->value v;place p;if v.typ<>Ref(m,p.typ)then bad op.span "borrow type mismatch";
             if reserved&&not m then bad op.span "shared borrow cannot be reserved"
         | Eval(v,r)->value v;List.iter value(rvalue_uses r);
             let require expected actual=if expected<>actual then bad op.span "operation type mismatch"in
             let index (x:value)=require I64 x.typ in
             let call args params result=
               if List.length args<>List.length params then bad op.span "call arity mismatch";
               List.iter2(fun(v:value)t->require t v.typ)args params;require result v.typ in
             (match r with
              |Int_lit n->if not(Type_desc.is_integer v.typ||v.typ=Unit||v.typ=File||(match v.typ with Box _|Function _->n=0L|_->false))then bad op.span "integer constant type"
              |Float_lit _->if not(Type_desc.is_float v.typ)then bad op.span "float constant type"
              |String_lit _->require String v.typ|Bool_lit _->require Bool v.typ
              |Unary("!",x)->require Bool x.typ;require Bool v.typ
              |Unary("-",x)->require x.typ v.typ;if not(Type_desc.is_numeric x.typ)then bad op.span "numeric unary operand"
              |Unary _->bad op.span "unknown unary operation"
              |Binary(("&&"|"||"),_,_)->bad op.span "short circuit operation must be CFG"
              |Binary(operator,a,b)->require a.typ b.typ;
                  let rec equality = function
                    |String|Bool|Unit->true|Vec t->equality t|t->Type_desc.is_numeric t in
                  let valid=match operator with
                    |"+"->a.typ=String||Type_desc.is_numeric a.typ
                    |"-"|"*"|"/"|"<"|"<="|">"|">="->Type_desc.is_numeric a.typ
                    |"%"->Type_desc.is_integer a.typ
                    |"=="|"!="->equality a.typ|_->false in
                  if not valid then bad op.span "invalid binary operator or operands";
                  require (if List.mem operator["==";"!=";"<";"<=";">";">="]then Bool else a.typ)v.typ
              |Function_address name->(match List.find_opt(fun(f:func)->f.name=name)program.functions with
                  |Some target->require(Function(List.map(fun id->
                      if id<0||id>=Array.length target.locals then bad op.span "unknown parameter local";
                      target.locals.(id).typ)target.params,target.return_type))v.typ
                  |None->bad op.span "unknown function address")
              |Call(name,args)->(match List.find_opt(fun(f:func)->f.name=name)program.functions with
                  |Some target->call args(List.map(fun id->
                      if id<0||id>=Array.length target.locals then bad op.span "unknown parameter local";
                      target.locals.(id).typ)target.params)target.return_type
                  |None->(match name,args with
                    |("print"|"println"),[x]->if not(Type_desc.is_numeric x.typ||List.mem x.typ[Bool;String;Vec I64;Vec F64])then bad op.span "print operand";require Unit v.typ
                    |"len",[x]->(match x.typ with String|Vec _->require I64 v.typ|_->bad op.span "length operand")
                    |"arg_count",[]->require I64 v.typ
                    |"arg",[_]->call args[I64]String
                    |("open_read"|"open_write"),[_]->call args[String]File
                    |"assert",[_]->call args[Bool]Unit
                    |"assert_msg",[_;_]->call args[Bool;String]Unit
                    |"panic",[_]->call args[String]Unit
                    |"int_to_str",[_]->call args[I64]String
                    |"float",[_]->call args[I64]F64|"int",[_]->call args[F64]I64
                    |"zeros",[_]->call args[I64](Vec I64)
                    |"repeat",[x;n]->index n;if not(List.mem x.typ[I64;F64])then bad op.span "repeat operand";require(Vec x.typ)v.typ
                    |"read_text",[_]->call args[String]String
                    |"read_ints",[_]->call args[String](Vec I64)
                    |"read_floats",[_]->call args[String](Vec F64)
                    |"$vec_into_string",[_]->call args[Vec U8]String
                    |"$inactive_pair",[]->(match v.typ with Ptr _|Slice _->()|_->bad op.span "inactive pair type")
                    |name,[x] when String.starts_with ~prefix:"__convert_" name->
                        let target=List.assoc_opt name ["__convert_i8",I8;"__convert_u8",U8;"__convert_i16",I16;"__convert_u16",U16;
                          "__convert_i32",I32;"__convert_u32",U32;"__convert_i64",I64;"__convert_u64",U64;"__convert_f32",F32;"__convert_f64",F64]in
                        (match target with Some t when Type_desc.is_numeric x.typ->require t v.typ|_->bad op.span "conversion contract")
                    |_->bad op.span "unknown call or builtin contract"))
              |Indirect_call(c,args)->(match c.typ with Function(ps,r)->call args ps r|_->bad op.span "indirect callee type")
              |Struct_lit(l,fields)->require(Named l.name)v.typ;
                  if l<>layout op.span l.name then bad op.span "non-canonical aggregate layout";
                  if List.map fst fields<>l.fields then bad op.span "aggregate field order";
                  List.iter(fun((f:struct_field),(x:value))->require f.typ x.typ)fields
              |Vec_lit xs->(match v.typ with Vec t->List.iter(fun(x:value)->require t x.typ)xs|_->bad op.span "vector result type")
              |Index(a,i)|Vec_get(a,i)->index i;(match a.typ with Vec t->require t v.typ|_->bad op.span "vector operand type")
              |Vec_len a->(match a.typ with Vec _->require I64 v.typ|_->bad op.span "vector length operand")
              |Slice_make(a,b,c)->index b;index c;(match a.typ with Vec t->require(Slice t)v.typ|String->require(Slice U8)v.typ|_->bad op.span "slice owner type")
              |Slice_len a->(match a.typ with Slice _->require I64 v.typ|_->bad op.span "slice length operand")
              |Slice_get(a,i)->index i;(match a.typ with Slice t->require t v.typ|_->bad op.span "slice operand type")
              |Vec_push(a,x)|Vec_set(a,_,x)->require(Ref(true,Vec x.typ))a.typ;require Unit v.typ;
                  (match r with Vec_set(_,i,_)->index i|_->())
              |Vec_pop a->require(Ref(true,Vec v.typ))a.typ
              |Exchange(a,x)->require(Ref(true,x.typ))a.typ;require x.typ v.typ;
                  if (owns x.typ||linear [] x.typ)&&not(local x.span x.id).owned then
                    bad op.span "replacement consumes an owned operand"
              |Vec_swap(a,i,j)->index i;index j;require Unit v.typ;(match a.typ with Ref(true,Vec _)->()|_->bad op.span "swap receiver")
              |Vec_replace(a,i,x)->index i;require(Ref(true,Vec x.typ))a.typ;require x.typ v.typ;
                  if (owns x.typ||linear [] x.typ)&&not(local x.span x.id).owned then
                    bad op.span "replacement consumes an owned operand"
              |File_read a->require(Ref(true,File))a.typ;require String v.typ
              |File_write(a,b)->require(Ref(true,File))a.typ;require String b.typ;require Unit v.typ
              |File_close a->require(Ref(true,File))a.typ;require Unit v.typ
              |File_is_open a->(match a.typ with Ref(_,File)->require Bool v.typ|_->bad op.span "File observation operand")
              |Box_new x->require(Box x.typ)v.typ;
                  if (owns x.typ||linear [] x.typ)&&not(local x.span x.id).owned then
                    bad op.span "Box construction consumes an owned operand"
              |Box_take x->require(Box v.typ)x.typ;
                  if not(local x.span x.id).owned then bad op.span "Box extraction consumes an owned operand"
              |Raw_alloc(t,n)->index n;require(Ptr t)v.typ
              |Raw_load(t,p,i)->require(Ptr t)p.typ;index i;require t v.typ
              |Raw_store(t,p,i,x)->require(Ptr t)p.typ;index i;require t x.typ;require Unit v.typ
              |Raw_free(t,p)->require(Ptr t)p.typ;require Unit v.typ
              |Ptr_addr(t,p)->require(Ptr t)p.typ;require I64 v.typ
              |Ptr_len p->(match p.typ with Ptr _->require I64 v.typ|_->bad op.span "pointer length operand")
              |Syscall xs->if xs=[]||List.length xs>7 then bad op.span "syscall arity";List.iter index xs;require I64 v.typ)
         | Initialize(p,v)|Replace(p,v)->place p;value v;if p.typ<>v.typ then bad op.span "store type mismatch";
             if (owns p.typ||linear [] p.typ) && not(local v.span v.id).owned then
               bad op.span "observed descriptor stored as an owned value"
         | Drop p|Forget p|Drop_flag(p,_)->place p
         | Logical_call_enter target ->
             if target<0 || target>=List.length program.functions then bad op.span "unknown logical call target";
             let callee=List.nth program.functions target in
             if callee.mode_set<>f.scopes.(op.scope).mode_set then bad op.span "logical call capability mismatch";
             calls:=(target,op.scope)::!calls
         | Logical_call_exit target -> (match !calls with
             |(id,scope)::rest when id=target && scope=op.scope->calls:=rest
             |_->bad op.span "unbalanced logical call exit")
         | Storage_live _|Storage_dead _->());
        (match op.node with Eval(_, (Raw_alloc _|Raw_load _|Raw_store _|Raw_free _|Ptr_addr _|Ptr_len _|Syscall _))->
          if not(List.mem Bb f.scopes.(op.scope).mode_set)then bad op.span "raw operation outside bb scope"|_->()))b.operations;
      if !calls<>[] then bad f.span "logical call crosses block terminator";
      (match b.terminator with Branch(v,_,_)->value v;if v.typ<>Bool then bad v.span "branch expects Bool"
        |Return(Some v)->value v;if v.typ<>f.return_type then bad v.span "return type mismatch"
        |Return None when f.return_type<>Unit->bad f.span "missing return value"|_->());
      List.iter(fun target->if target<0||target>=Array.length f.blocks then bad f.span "unknown successor")(successors b.terminator))f.blocks)program.functions
let checked p = verify p;Checked p
let string_of_place (p:place) = "l"^string_of_int p.root^String.concat ""(List.map(function
  |Field f->"."^f.name|Element v->"[v"^string_of_int v.id^"]"|Deref->".*")p.projections)
let dump p =
  let b=Buffer.create 1024 in let line fmt=Printf.ksprintf(fun s->Buffer.add_string b(s^"\n"))fmt in
  List.iter(fun(f:func)->line "fn f%d %s -> %s" f.id f.name(string_of_typ f.return_type);
    Array.iter(fun(l:local)->line "  l%d %s: %s scope=s%d%s" l.id l.name(string_of_typ l.typ)l.scope(if l.owned then " owned" else ""))f.locals;
    Array.iter(fun(block:block)->line "  b%d scope=s%d:" block.id block.scope;
      List.iter(fun (op:operation)->let s=match op.node with
        |Storage_live n->"live l"^string_of_int n|Storage_dead n->"dead l"^string_of_int n
        |Acquire(v,k,p)->Printf.sprintf "v%d = %s %s" v.id(match k with Read->"read"|Copy->"copy"|Clone->"clone"|Move->"move")(string_of_place p)
        |Borrow(v,m,r,p)->Printf.sprintf "v%d = borrow %s%s %s" v.id(if m then "mut "else "")(if r then "reserved"else "")(string_of_place p)
        |Eval(v,r)->Printf.sprintf "v%d = %s(%s)" v.id(match r with Call(n,_)->"call "^n|Indirect_call _->"indirect-call"|_->"operation")(String.concat ","(List.map(fun(v:value)->"v"^string_of_int v.id)(rvalue_uses r)))
        |Initialize(p,v)->Printf.sprintf "init %s <- v%d"(string_of_place p)v.id
        |Replace(p,v)->Printf.sprintf "replace %s <- v%d"(string_of_place p)v.id
        |Drop p->"drop "^string_of_place p|Forget p->"forget "^string_of_place p
        |Logical_call_enter id->"logical-call-enter f"^string_of_int id
        |Logical_call_exit id->"logical-call-exit f"^string_of_int id
        |Drop_flag(p,yes)->"drop-flag "^string_of_place p^" <- "^string_of_bool yes in line "    %s" s)block.operations;
      line "    %s"(match block.terminator with Jump n->"jump b"^string_of_int n|Branch(v,a,b)->Printf.sprintf "branch v%d b%d b%d"v.id a b|Return None->"return"|Return(Some v)->"return v"^string_of_int v.id|Stop->"stop"))f.blocks)p.functions;
  Buffer.contents b
