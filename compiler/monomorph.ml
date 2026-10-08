(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

type error = { span : span; message : string; help : string option }
exception Invalid of error

type witness =
  | W_other
  | W_literal of expr_node
  | W_tuple of witness list
  | W_variant of string * witness option

let fail ?help span message = raise (Invalid {span;message;help})
let key name args = if args=[] then name else string_of_typ (Apply(name,List.map Type_desc.canonicalize args))
let rec subst bindings = function
  | Type_var n -> (match List.assoc_opt n bindings with Some t->t|None->Type_var n)
  | Box t->Box(subst bindings t)
  | Vec t->Vec(subst bindings t)|Slice t->Slice(subst bindings t)|Ptr t->Ptr(subst bindings t)|Ref(m,t)->Ref(m,subst bindings t)
  | Apply(n,xs)->Apply(n,List.map(subst bindings)xs)|Tuple xs->Tuple(List.map(subst bindings)xs)
  | Function(xs,r)->Function(List.map(subst bindings)xs,subst bindings r)
  | t->Type_desc.canonical t

module Names = Set.Make(String)
let run (program:program) =
 try
  (* Enum representation fields are compiler-private.  Reject source-level
     access before match/for lowering introduces its own internal field nodes. *)
  let rec reject_private_expr (e:expr) = match e.node with
    | Field(_,name) when name="__tag" || String.starts_with ~prefix:"__payload_"name->
        fail e.span ("enum representation field '"^name^"' is private")
    | Unary(_,x)|Borrow(_,x)|Field(x,_)|Tuple_index(x,_)|Try x->reject_private_expr x
    | Binary(_,a,b)|Index(a,b)->reject_private_expr a;reject_private_expr b
    | Call(_,xs)|Generic_call(_,_,xs)|Intrinsic(_,_,xs)|Vec_lit xs|Tuple_lit xs->List.iter reject_private_expr xs
    | Method(r,_,xs)->reject_private_expr r;List.iter reject_private_expr xs
    | Struct_lit(_,fs)|Generic_struct_lit(_,_,fs)->List.iter(fun(_,x,_)->reject_private_expr x)fs
    | Variant_lit(_,_,_,x)->Option.iter reject_private_expr x
    | If_expr(c,a,b)->List.iter reject_private_expr[c;a;b]
    | Match(x,arms)->reject_private_expr x;List.iter(fun(a:match_arm)->List.iter reject_private_stmt a.body;Option.iter reject_private_expr a.tail)arms
    | Match_control _->assert false
    | Int_lit _|Float_lit _|String_lit _|Bool_lit _|Var _->()
  and reject_private_stmt (s:stmt) = match s.node with
    | Field_assign(_,name,_) when name="__tag" || String.starts_with ~prefix:"__payload_"name->
        fail s.span ("enum representation field '"^name^"' is private")
    | Let(_,_,_,x)|Let_pattern(_,_,_,x)|Assign(_,x)|Field_assign(_,_,x)|Expr x->reject_private_expr x
    | Index_assign(a,b,x)->List.iter reject_private_expr[a;b;x]
    | Deref_assign(a,b)->List.iter reject_private_expr[a;b]
    | Return x->Option.iter reject_private_expr x
    | If(c,a,b)->reject_private_expr c;List.iter reject_private_stmt(a@b)
    | While(c,b)->reject_private_expr c;List.iter reject_private_stmt b
    | For(_,x,b)->reject_private_expr x;List.iter reject_private_stmt b
    | Block b|Scope(_,b)->List.iter reject_private_stmt b|Break|Continue->() in
  List.iter(fun(f:func)->List.iter reject_private_stmt f.body)program.functions;
  let struct_templates=Hashtbl.create 16 and fn_templates=Hashtbl.create 16 in
  let concrete_structs=Hashtbl.create 16 in
  let enum_templates=Hashtbl.create 16 and concrete_enums=Hashtbl.create 16 and concrete_enum_args=Hashtbl.create 16 in
  let type_names=Hashtbl.create 16 in
  List.iter(fun (d:struct_decl)->if Hashtbl.mem type_names d.struct_name then fail d.struct_span("duplicate type '"^d.struct_name^"'")else Hashtbl.add type_names d.struct_name();if d.type_params<>[] then Hashtbl.add struct_templates d.struct_name d else Hashtbl.add concrete_structs d.struct_name d)program.structs;
  List.iter(fun (f:func)->if f.type_params<>[] then Hashtbl.add fn_templates f.name f)program.functions;
  List.iter(fun (d:enum_decl)->if Hashtbl.mem type_names d.enum_name then fail d.enum_span("duplicate type '"^d.enum_name^"'")else Hashtbl.add type_names d.enum_name();
    if d.variants=[] then fail d.enum_span "enum must declare at least one variant";Hashtbl.add enum_templates d.enum_name d)program.enums;
  (* Preserve symbolic types before substitution, including inferred bindings
     and pattern payloads. The concrete checker still checks every instance. *)
  let builtin_call n = List.mem n ["print";"println";"len";"arg";"arg_count";"assert";"assert_msg";
    "panic";"float";"int";"int_to_str";"zeros";"repeat";"read_text";"read_ints";"read_floats";
    "open_read";"open_write";"raw_alloc_int";"raw_load_int";"raw_store_int";"raw_free_int";
    "raw_alloc";"raw_load";"raw_store";"raw_free";"ptr_addr";
    "syscall0";"syscall1";"syscall2";"syscall3";"syscall4";"syscall5";"syscall6";
    "i8";"u8";"i16";"u16";"i32";"u32";"i64";"u64";"f32";"f64"]in
  let local_call env n =
    if builtin_call n then None else
    let short=match String.rindex_opt n '.'with Some i->String.sub n(i+1)(String.length n-i-1)|None->n in
    match Hashtbl.find_opt env n with Some t->Some t|None->
      (match Hashtbl.find_opt env "$module"with
       |Some(Named m)when n=m^"."^short->Hashtbl.find_opt env short|_->None)in
  let module_context env name =
    let owner=if String.starts_with ~prefix:"__method$" name then
        let ending=String.rindex name '$'in String.sub name 9 (ending-9)else name in
    match String.rindex_opt owner '.'with
    |Some i->Hashtbl.replace env "$module"(Named(String.sub owner 0 i))|None->() in
  let box_constructor env n = n="$box_new" || n="core.box.new" ||
    (n="box" && not(Hashtbl.mem env n) && not(List.exists(fun(f:func)->f.name=n)program.functions)) in
  let box_element = function
    | Box t->Some t
    | Apply(n,[t]) when n="core.box.Box" || (n="Box" && not(Hashtbl.mem type_names n))->Some t
    |_->None in
  let structural_next = Hashtbl.create 16 in
  (* Concrete inference probes share the source tuple shape. This table remains
     empty during symbolic declaration validation, so type variables stay rigid. *)
  let tuple_shapes = Hashtbl.create 16 in
  let rec symbolic = function
    |Apply(n,[t])when n="core.box.Box" || (n="Box"&&not(Hashtbl.mem type_names n))->Box(symbolic t)
    |Box t->Box(symbolic t)|Vec t->Vec(symbolic t)|Slice t->Slice(symbolic t)|Ptr t->Ptr(symbolic t)
    |Ref(m,t)->Ref(m,symbolic t)|Apply(n,ts)->Apply(n,List.map symbolic ts)
    |Tuple ts->Tuple(List.map symbolic ts)|Function(ts,r)->Function(List.map symbolic ts,symbolic r)
    |Named n when Hashtbl.mem tuple_shapes n->Tuple(List.map symbolic(Hashtbl.find tuple_shapes n))
    |t->Type_desc.canonical t in
  let rec dependent = function
    | Type_var _->true
    | Box t|Vec t|Slice t|Ptr t|Ref(_,t)->dependent t
    | Apply(_,ts)|Tuple ts->List.exists dependent ts
    | Function(ts,r)->List.exists dependent (r::ts)|_->false in
  let unconstrained span = fail span "operation requires a concrete type; unconstrained type parameter is not allowed" in
  let rec referent = function Ref(_,t)->referent t|t->t in
  let aggregate = function Apply(n,ts)->Some(n,ts)|Named n->Some(n,[])|_->None in
  let field_type typ name = match aggregate(referent typ) with
    |Some(n,args)->let d=match Hashtbl.find_opt struct_templates n with
        |Some d->Some d|None->Hashtbl.find_opt concrete_structs n in
      (match d with Some d when List.length args=List.length d.type_params->
         Option.map(fun f->subst(List.combine d.type_params args)f.field_type)
           (List.find_opt(fun f->f.field_name=name)d.fields)|_->None)
    |_->None in
  let variant_type typ variant = match aggregate typ with
    |Some(n,args)->(match Hashtbl.find_opt enum_templates n with
        |Some d when List.length args=List.length d.type_params->
          Option.bind(List.find_opt(fun v->v.variant_name=variant)d.variants)
            (fun v->Option.map(subst(List.combine d.type_params args))v.payload)
        |_->None)|_->None in
  (* Match symbolic shapes, without choosing a numeric common type or using
     concrete instantiation to erase a caller's type parameter. *)
  let rec infer_bindings bindings pattern actual = match symbolic pattern,symbolic actual with
    |Type_var p,t->if not(Hashtbl.mem bindings p)then Hashtbl.add bindings p t
    |(Box p,Box a)|(Vec p,Vec a)|(Slice p,Slice a)|(Ptr p,Ptr a)|(Ref(_,p),Ref(_,a))->infer_bindings bindings p a
    |Apply(n,ps),Apply(m,ts) when n=m&&List.length ps=List.length ts->List.iter2(infer_bindings bindings)ps ts
    |Tuple ps,Tuple ts when List.length ps=List.length ts->List.iter2(infer_bindings bindings)ps ts
    |Function(ps,r),Function(ts,s) when List.length ps=List.length ts->List.iter2(infer_bindings bindings)(r::ps)(s::ts)
    |_->() in
  let rec compatible expected actual =
    let expected=symbolic expected and actual=symbolic actual in
    match expected,actual with
    (* Only an associated structural item can take a contextual expectation.
       The concrete next signature and ordinary use-site equality check it;
       source type parameters remain rigid, including in annotations. *)
    |_,Type_var "$iterator_item"->true
    |(Box p,Box a)|(Vec p,Vec a)|(Slice p,Slice a)|(Ptr p,Ptr a)->compatible p a
    |Ref(m,p),Ref(n,a) when m=n || not m->compatible p a
    |Apply(n,ps),Apply(m,ts) when n=m&&List.length ps=List.length ts->List.for_all2 compatible ps ts
    |Tuple ps,Tuple ts when List.length ps=List.length ts->List.for_all2 compatible ps ts
    |Function(ps,r),Function(ts,s) when List.length ps=List.length ts->List.for_all2 compatible(r::ps)(s::ts)
    |_->expected=actual in
  let require_symbolic span expected actual = match expected,actual with
    |Some p,Some a when (dependent p || dependent a) && not(compatible p a)->unconstrained span
    |_->() in
  let find_function env n =
    let resolved=match Hashtbl.find_opt env "$module" with
      |Some(Named m) when not(String.contains n '.')->m^"."^n|_->n in
    List.find_opt(fun(f:func)->f.name=resolved || f.name=n)program.functions in
  let rec generic_type ?expected env (e:expr) =
    let ty x=generic_type env x in
    match e.node with
    |Var n->(match Hashtbl.find_opt env n with Some _ as t->t|None->
        Option.map(fun f->Function(List.map(fun(p:param)->p.typ)f.params,f.return_type))(find_function env n))
    |Int_lit _->Some(match expected with Some t when Type_desc.is_integer t->t|_->I64)
    |Float_lit _->Some(match expected with Some t when Type_desc.is_float t->t|_->F64)
    |String_lit _->Some String|Bool_lit _->Some Bool|Intrinsic _->Some I64
    |Unary("*",r)->(match ty r with Some(Ref(_,t))->Some t|Some t->box_element t|_->None)
    |Unary("!",_)->Some Bool|Unary(_,x)->generic_type ?expected env x
    |Binary(("=="|"!="|"<"|"<="|">"|">="|"&&"|"||"),_,_)->Some Bool
    |Binary("..",_,_)->Some(Named "Range")|Binary(_,a,_)->generic_type ?expected env a
    |Borrow(m,x)->Option.map(fun t->Ref(m,t))(ty x)
    |Field(r,n)->Option.bind(ty r)(fun t->field_type t n)
    |Tuple_index(r,n)->(match Option.map(fun t->symbolic(referent t))(ty r),int_of_string_opt n with
        |Some(Tuple ts),Some i when i>=0&&i<List.length ts->Some(List.nth ts i)|_->None)
    |Try r->(match ty r with Some(Apply("Result",[t;_]))->Some t|_->None)
    |Tuple_lit []->Some Unit
    |Tuple_lit xs->let ts=match Option.map symbolic expected with
        |Some(Tuple ts) when List.length ts=List.length xs->List.map2(fun t x->generic_type ~expected:t env x)ts xs
        |_->List.map ty xs in
        if List.for_all Option.is_some ts then Some(Tuple(List.map Option.get ts))else None
    |Vec_lit xs->(match expected,xs with Some(Vec t),_->Some(Vec t)|_,x::_->Option.map(fun t->Vec t)(ty x)|_->None)
    |Index(r,_)->(match Option.map referent(ty r) with Some(Vec t|Slice t)->Some t|_->None)
    |If_expr(_,a,b)->(match generic_type ?expected env a with Some _ as t->t|_->generic_type ?expected env b)
    |Match(x,arms)->let typ=ty x in
        List.find_map(fun(a:match_arm)->let local=Hashtbl.copy env in bind_pattern local typ a.pattern;
          List.iter(record_binding local)a.body;Option.bind a.tail(generic_type ?expected local))arms
    |Struct_lit(n,fs)->(match Hashtbl.find_opt struct_templates n with
        |Some d->aggregate_type env expected n d.type_params
            (List.filter_map(fun(name,x,_)->Option.map(fun f->f.field_type,x)
              (List.find_opt(fun f->f.field_name=name)d.fields))fs)[]
        |_->Some(Named n))
    |Generic_struct_lit(n,ts,_)->Some(Apply(n,ts))
    |Variant_lit(n,ts,v,payload)->(match Hashtbl.find_opt enum_templates n with
        |Some d->let values=match List.find_opt(fun q->q.variant_name=v)d.variants,payload with
            |Some{payload=Some t;_},Some x->[t,x]|_->[] in
          aggregate_type env expected n d.type_params values ts
        |_->None)
    |Call(n,xs)->call_type env n [] xs
    |Generic_call(n,ts,xs)->call_type env n ts xs
    |Method(r,n,xs)->method_type env r n xs
    |Match_control _->assert false
  and aggregate_type env expected name parameters values explicit =
    if parameters=[] then Some(Named name)else
    if explicit<>[] then Some(Apply(name,explicit))else
    match expected with Some(Apply(n,_) as t)when n=name->Some t|_->
      let inferred=Hashtbl.create 8 in List.iter(fun(p,x)->Option.iter(infer_bindings inferred p)(generic_type env x))values;
      let args=List.filter_map(Hashtbl.find_opt inferred)parameters in
      if List.length args=List.length parameters then Some(Apply(name,args))else None
  and call_signature env n explicit xs =
    if builtin_call n then None else
    match local_call env n with Some(Function(ps,r))->Some(ps,r)|_->
    match find_function env n with None->None|Some f->
      let bindings=if explicit<>[] && List.length explicit=List.length f.type_params then List.combine f.type_params explicit else
        let inferred=Hashtbl.create 8 in
        if List.length f.params=List.length xs then List.iter2(fun(p:param)x->
          Option.iter(infer_bindings inferred p.typ)(generic_type env x))f.params xs;
        List.filter_map(fun n->Option.map(fun t->n,t)(Hashtbl.find_opt inferred n))f.type_params in
      Some(List.map(fun(p:param)->subst bindings p.typ)f.params,subst bindings f.return_type)
  and builtin_signature env expected n explicit xs =
    let element=match explicit with [t]->Some t|_->
      match xs with p::_->(match generic_type env p with Some(Ptr t)->Some t|_->None)|_->None in
    if box_constructor env n then
      let target=match explicit with [t]->Some t|_->
        match Option.map symbolic expected with Some(Box t)->Some t|_->
          (match xs with [x]->generic_type env x|_->None)in
      Option.map(fun t->[t],Box t)target
    else match n with
    |"raw_alloc"->Option.map(fun t->[I64],Ptr t)element
    |"raw_load"->Option.map(fun t->[Ptr t;I64],t)element
    |"raw_store"->Option.map(fun t->[Ptr t;I64;t],Unit)element
    |"raw_free"->Option.map(fun t->[Ptr t],Unit)element
    |"ptr_addr"->Option.map(fun t->[Ptr t],I64)element
    |"raw_alloc_int"->Some([I64],Ptr I64)
    |"raw_load_int"->Some([Ptr I64;I64],I64)
    |"raw_store_int"->Some([Ptr I64;I64;I64],Unit)
    |"raw_free_int"->Some([Ptr I64],Unit)
    |_->None
  and call_type env n explicit xs =
    if box_constructor env n then match explicit,xs with [t],_->Some(Box t)|_,[x]->Option.map(fun t->Box t)(generic_type env x)|_->None
    else match call_signature env n explicit xs with Some(_,r)->Some r|_->
    match n,explicit,xs with
    |("raw_alloc"),[t],_->Some(Ptr t)
    |"raw_load",_,p::_->(match generic_type env p with Some(Ptr t)->Some t|_->None)
    |("raw_alloc_int"),_,_->Some(Ptr I64)
    |("open_read"|"open_write"),_,_->Some File
    |("arg"|"read_text"|"int_to_str"),_,_->Some String
    |("zeros"|"read_ints"),_,_->Some(Vec I64)|"read_floats",_,_->Some(Vec F64)
    |"repeat",_,x::_->Option.map(fun t->Vec t)(generic_type env x)
    |("print"|"println"|"assert"|"assert_msg"|"panic"|"raw_store"|"raw_free"|"raw_store_int"|"raw_free_int"),_,_->Some Unit
    |("i8"|"u8"|"i16"|"u16"|"i32"|"u32"|"i64"|"u64"|"f32"|"f64"|"int"|"float"),_,_->
        Some(match n with "i8"->I8|"u8"->U8|"i16"->I16|"u16"->U16|"i32"->I32|"u32"->U32|"u64"->U64|"f32"->F32|"f64"|"float"->F64|_->I64)
    |("len"|"arg_count"|"ptr_addr"|"raw_load_int"|"syscall0"|"syscall1"|"syscall2"|"syscall3"|"syscall4"|"syscall5"|"syscall6"),_,_->Some I64
    |_->None
  and method_signature env r name = match Option.bind(generic_type env r)(fun t->aggregate(referent t))with
    |Some(owner,args)->let method_name="__method$"^owner^"$"^name in
      (match List.find_opt(fun(f:func)->f.name=method_name)program.functions with
       |Some f when List.length args=List.length f.type_params->let bindings=List.combine f.type_params args in
         Some(List.map(fun(p:param)->subst bindings p.typ)f.params,subst bindings f.return_type)
       |_->None)|_->None
  and method_type env r name _xs = match method_signature env r name with Some(_,t)->Some t|_->
    match Option.map referent(generic_type env r),name with
    |Some(Type_var _),"next"->Some(Apply("Option",[Type_var "$iterator_item"]))
    |Some(Vec t|Slice t),"iter"->Some(Apply("std.iter.SliceIter",[t]))
    |Some String,"iter"->Some(Apply("std.iter.SliceIter",[U8]))
    |Some(Ptr t),"iter"->Some(Apply("std.iter.PtrIter",[t]))
    |Some iterator,"enumerate"->(match method_type env r "next" []with
        |Some(Apply("Option",[item]))->Some(Apply("std.iter.Enumerate",[iterator;item]))|_->None)
    |Some(Vec _|Slice _|String),"len"->Some I64
    |Some(Vec t|Slice t),("get"|"pop")->Some t
    |Some(Vec t),("as_slice"|"slice")->Some(Slice t)
    |Some String,"as_bytes"->Some(Slice U8)
    |Some(Vec U8),"into_string"|Some File,"read"->Some String
    |Some File,"is_open"->Some Bool
    |Some(Vec _),("push"|"set")|Some File,("write"|"close")->Some Unit
    |Some t,("into_inner"|"as_ref"|"as_mut")->Option.map(fun t->if name="into_inner"then t else Ref(name="as_mut",t))(box_element t)
    |Some t,n->(match field_type t n with Some(Function(_,r))->Some r|_->None)|_->None
  and bind_pattern env typ p = match p.pattern_node with
    |Binding_pattern n->Option.iter(Hashtbl.replace env n)typ
    |Literal_pattern _->(match typ with Some(Type_var _)->unconstrained p.pattern_span|_->())
    |Tuple_pattern ps->(match Option.map symbolic typ with Some(Tuple ts)when List.length ps=List.length ts->List.iter2(fun p t->bind_pattern env (Some t)p)ps ts
        |Some(Type_var _)->unconstrained p.pattern_span|_->())
    |Variant_pattern(_,v,Some p)->(match typ with Some(Type_var _)->unconstrained p.pattern_span|_->bind_pattern env (Option.bind typ(fun t->variant_type t v))p)
    |Variant_pattern(_,_,None)->(match typ with Some(Type_var _)->unconstrained p.pattern_span|_->())
    |Wildcard_pattern->()
  and bind_let_pattern env typ p = match p.pattern_node with
    |Binding_pattern n->Option.iter(Hashtbl.replace env n)typ
    |Wildcard_pattern->()
    |Tuple_pattern ps->(match Option.map symbolic typ with
        |Some(Tuple ts) when List.length ps=List.length ts->List.iter2(fun p t->bind_let_pattern env(Some t)p)ps ts
        |Some(Type_var _)->unconstrained p.pattern_span
        |Some _->fail p.pattern_span "let tuple pattern requires a matching tuple type"
        |None->())
    |_->fail p.pattern_span "let pattern supports bindings, _, and nested tuples"
  and record_binding env (s:stmt) = match s.node with
    |Let(_,n,t,x)->(match t with Some t->Hashtbl.replace env n t|None->Option.iter(Hashtbl.replace env n)(generic_type env x))
    |Let_pattern(_,p,t,x)->
        let names=Hashtbl.create 8 in
        let rec unique p=match p.pattern_node with
          |Binding_pattern n->if Hashtbl.mem names n then fail p.pattern_span("duplicate pattern binding '"^n^"'");Hashtbl.add names n ()
          |Tuple_pattern ps->List.iter unique ps|_->() in
        unique p;
        bind_let_pattern env (match t with Some _->t|None->generic_type env x)p
    |_->()
  and validate_expr ?expected env (e:expr) =
    let check ?expected x=validate_expr ?expected env x in
    let reject_abstract x=match Option.map referent(generic_type env x)with Some(Type_var _)->unconstrained x.span|_->() in
    (match e.node with
    |Binary(op,a,b)->reject_abstract a;reject_abstract b;
        if op="=="||op="!="then List.iter(fun x->match generic_type env x with Some t when dependent t->unconstrained e.span|_->())[a;b];
        check a;check b
    |Unary("*",x)->(match generic_type env x with Some(Type_var _)->unconstrained x.span|_->());check x
    |Unary(_,x)->reject_abstract x;check x
    |Call(n,xs)|Generic_call(n,_,xs)->let explicit=match e.node with Generic_call(_,ts,_)->ts|_->[] in
        (match local_call env n with Some(Type_var _)->unconstrained e.span|_->());
        let signature=match call_signature env n explicit xs with Some _ as s->s|_->builtin_signature env expected n explicit xs in
        (match signature with
         |Some(ps,_)when List.length ps=List.length xs->List.iter2(fun t x->check ~expected:t x)ps xs
         |_->List.iter check xs;
           if not(box_constructor env n)then List.iter(fun x->match generic_type env x with
             |Some(Type_var _)->unconstrained x.span
             |Some t when (n="print"||n="println"||n="repeat")&&dependent t->unconstrained x.span|_->())xs)
    |Method(r,name,xs)->(match Option.map referent(generic_type env r)with
         |Some(Type_var _) when name="next"&&xs=[]->Hashtbl.replace structural_next e.span ()
         |Some(Type_var _)->unconstrained r.span|_->());check r;
        (match method_signature env r name with
         |Some(_self::ps,_)when List.length ps=List.length xs->List.iter2(fun t x->check ~expected:t x)ps xs
         |_->(match Option.bind(generic_type env r)(fun t->field_type t name)with
             |Some(Function(ps,_))when List.length ps=List.length xs->List.iter2(fun t x->check ~expected:t x)ps xs
             |_->let value_type=match Option.map referent(generic_type env r)with Some(Vec t)->Some t|_->None in
               List.iteri(fun i x->let expected=
                 if (name="push"&&i=0)||(name="set"&&i=1)then value_type
                 else if name="get"||name="slice"||(name="set"&&i=0)then Some I64
                 else None in check ?expected x)xs))
    |Index(r,i)->reject_abstract r;check r;check ~expected:I64 i
    |Field(r,_)|Tuple_index(r,_)->reject_abstract r;check r
    |Borrow(_,x)->check x
    |Try x->reject_abstract x;check x;
        (match generic_type env x,Hashtbl.find_opt env "$return"with
         |Some(Apply("Result",[_;error])),Some(Apply("Result",[_;target]))->
           require_symbolic e.span (Some target)(Some error);
           if not(compatible target error)then fail e.span "? requires the same Result error type"
         |Some(Apply("Result",_)),_->fail e.span "? requires a Result return type with the same error type"
         |_->())
    |Intrinsic(_,_,xs)->List.iter check xs
    |Tuple_lit xs->let ts=match Option.map symbolic expected with Some(Tuple ts)when List.length ts=List.length xs->List.map Option.some ts|_->List.map(fun _->None)xs in
        List.iter2(fun t x->check ?expected:t x)ts xs
    |Vec_lit xs->let element=match generic_type ?expected env e with Some(Vec t)->Some t|_->None in List.iter(check ?expected:element)xs
    |Struct_lit(_,fs)|Generic_struct_lit(_,_,fs)->let typ=generic_type ?expected env e in
        List.iter(fun(n,x,_)->check ?expected:(Option.bind typ(fun t->field_type t n))x)fs
    |Variant_lit(_,_,v,payload)->let typ=generic_type ?expected env e in
        Option.iter(check ?expected:(Option.bind typ(fun t->variant_type t v)))payload
    |If_expr(c,a,b)->check ~expected:Bool c;check ?expected a;check ?expected:(match expected with Some _->expected|_->generic_type env a)b
    |Match(x,arms)->check x;let typ=generic_type env x in
        let result=match expected with Some _->expected|_->generic_type env e in
        List.iter(fun(a:match_arm)->let local=Hashtbl.copy env in bind_pattern local typ a.pattern;
          List.iter(validate_stmt local)a.body;Option.iter(validate_expr ?expected:result local)a.tail)arms
    |_->());
    require_symbolic e.span expected(generic_type ?expected env e)
  and validate_stmt env (s:stmt) =
    let check ?expected x=validate_expr ?expected env x in
    let body xs=List.iter(validate_stmt(Hashtbl.copy env))xs in
    match s.node with
    |Let(_,_,t,x)|Let_pattern(_,_,t,x)->check ?expected:t x;record_binding env s
    |Assign(n,x)->check ?expected:(Hashtbl.find_opt env n)x
    |Field_assign(n,f,x)->(match Option.map referent(Hashtbl.find_opt env n)with Some(Type_var _)->unconstrained s.span|_->());
        check ?expected:(Option.bind(Hashtbl.find_opt env n)(fun t->field_type t f))x
    |Expr x->check x
    |Index_assign(a,b,x)->check a;check ~expected:I64 b;
        (match Option.map referent(generic_type env a)with Some(Type_var _)->unconstrained a.span|_->());
        let t=match Option.map referent(generic_type env a)with Some(Vec t)->Some t|_->None in check ?expected:t x
    |Deref_assign(a,b)->check a;(match generic_type env a with Some(Type_var _)->unconstrained a.span|_->());
        check ?expected:(match generic_type env a with Some(Ref(_,t))->Some t|_->None)b
    |Return x->Option.iter(check ?expected:(Hashtbl.find_opt env "$return"))x
    |If(c,a,b)->check ~expected:Bool c;body a;body b
    |While(c,b)->check ~expected:Bool c;body b
    |For(p,x,b)->check x;let local=Hashtbl.copy env in
        (match generic_type env x with Some(Type_var _)->Hashtbl.replace structural_next s.span ()|_->());
        let next:expr={node=Method(x,"next",[]);span=x.span} in
        let item=match generic_type env next with Some(Apply("Option",[t]))->Some t|_->None in
        bind_pattern local item p;List.iter(validate_stmt local)b
    |Block b|Scope(_,b)->body b|Break|Continue->() in
  Hashtbl.iter(fun _ (f:func)->let env=Hashtbl.create 8 in module_context env f.name;
    List.iter(fun(p:param)->Hashtbl.add env p.name p.typ)f.params;Hashtbl.add env "$return" f.return_type;
    List.iter(validate_stmt env)f.body)fn_templates;
  let generated_structs=Hashtbl.create 16 and generated_fns=Hashtbl.create 16 and concrete_struct_args=Hashtbl.create 16 in
  let active_aggregates=Hashtbl.create 16 and active_instances=Hashtbl.create 16 in
  let match_counter=ref 0 in
  let for_counter=ref 0 in
  let instantiation_depth=ref 0 in
  let enclosing_modes=ref [] in
  let named_struct name = match Hashtbl.find_opt generated_structs name with
    | Some d->Some d | None->Hashtbl.find_opt concrete_structs name in
  let rec describe span typ =
    try Type_desc.describe ~named:(fun n->match named_struct n with
      |Some d->let fields=List.map(fun f->describe f.field_span f.field_type)d.fields in
          let offset=ref 0 and alignment=ref 1 in
          List.iter(fun x->offset:=Type_desc.align_up !offset x.Type_desc.alignment+x.size;alignment:=max !alignment x.alignment)fields;
          {Type_desc.size=Type_desc.align_up !offset !alignment;alignment= !alignment;
           trivial_copy=List.for_all(fun x->x.Type_desc.trivial_copy)fields;
           move_only=List.exists(fun x->x.Type_desc.move_only)fields;
           drop=(if List.exists(fun x->x.Type_desc.drop<>Type_desc.No_drop)fields then Type_desc.Drop_struct else Type_desc.No_drop);
           equality=false;abi=Type_desc.Indirect}
      |None->fail span("cannot resolve type descriptor for "^n))typ
    with Invalid_argument _->fail span("cannot resolve type descriptor for "^string_of_typ typ) in
  let rec concrete_type ?(vec_boundary=false) span = function
    | Type_var n->fail span("unresolved type variable '"^n^"'")
    | Apply(n,args) when n="core.box.Box" || (n="Box" && not(Hashtbl.mem type_names n))->
        (match args with [t]->Box(concrete_type ~vec_boundary:true span t)
         |_->fail span "Box expects 1 type argument")
    | Box t->Box(concrete_type ~vec_boundary:true span t)
    | Apply(n,args)->
        let nested_vec_boundary=vec_boundary && Hashtbl.length active_instances>0 in
        let args=List.map(concrete_type ~vec_boundary:nested_vec_boundary span)args in
        ignore(instantiate_aggregate ~vec_boundary span n args);Named(key n args)
    | Tuple xs->
        let nested_vec_boundary=vec_boundary && Hashtbl.length active_instances>0 in
        let xs=List.map(concrete_type ~vec_boundary:nested_vec_boundary span)xs in
        ignore(instantiate_tuple span xs);Named(key "$Tuple" xs)
    | Vec t->Vec(concrete_type ~vec_boundary:true span t)
    | Slice t->Slice(concrete_type span t)|Ptr t->Ptr(concrete_type span t)|Ref(m,t)->Ref(m,concrete_type span t)
    | Function(xs,r)->Function(List.map(concrete_type span)xs,concrete_type span r)
    | Named n when Hashtbl.mem enum_templates n && (Hashtbl.find enum_templates n).type_params=[]->ignore(instantiate_enum span n []);Named n
    | t->Type_desc.canonical t
  and instantiate_aggregate ?(vec_boundary=false) span name args =
    if Hashtbl.mem enum_templates name then instantiate_enum ~vec_boundary span name args else instantiate_struct ~vec_boundary span name args
  and instantiate_struct ?(vec_boundary=false) span name args =
    let display=key name args in
    match Hashtbl.find_opt generated_structs display with Some d->
      if Hashtbl.mem active_instances display && not vec_boundary then fail span("recursive value layout involving '"^display^"'") else d
    |None->
    if Hashtbl.mem active_aggregates name then
      fail span(if vec_boundary then "generic recursion keeps expanding its type arguments" else "recursive value layout involving '"^name^"'");
    let template=match Hashtbl.find_opt struct_templates name with
      |Some d->d|None->fail span("unknown generic aggregate '"^name^"'") in
    if List.length args<>List.length template.type_params then fail span
      (Printf.sprintf "type '%s' expects %d type arguments" name (List.length template.type_params));
    let bindings=List.combine template.type_params args in
    let placeholder={template with struct_name=display;type_params=[];fields=[]} in
    let inherited_vec_boundary=vec_boundary && Hashtbl.length active_instances>0 in
    Hashtbl.add active_aggregates name ();Hashtbl.add active_instances display ();
    Hashtbl.add generated_structs display placeholder;
    let fields=List.map(fun f->{f with field_type=concrete_type ~vec_boundary:inherited_vec_boundary f.field_span(subst bindings f.field_type)})template.fields in
    let d={placeholder with fields} in Hashtbl.replace generated_structs display d;Hashtbl.replace concrete_struct_args display args;
    Hashtbl.remove active_instances display;Hashtbl.remove active_aggregates name;d
  and instantiate_enum ?(vec_boundary=false) span name args =
    let display=key name args in
    match Hashtbl.find_opt generated_structs display with Some d->
      if Hashtbl.mem active_instances display && not vec_boundary then fail span("recursive value layout involving '"^display^"'") else d
    |None->
    if Hashtbl.mem active_aggregates name then
      fail span(if vec_boundary then "generic recursion keeps expanding its type arguments" else "recursive value layout involving '"^name^"'");
    let template=Hashtbl.find enum_templates name in
    if List.length args<>List.length template.type_params then fail span
      (Printf.sprintf "type '%s' expects %d type arguments" name(List.length template.type_params));
    let bindings=List.combine template.type_params args in
    let placeholder={struct_name=display;type_params=[];fields=[];struct_span=span} in
    let inherited_vec_boundary=vec_boundary && Hashtbl.length active_instances>0 in
    Hashtbl.add active_aggregates name ();Hashtbl.add active_instances display ();
    Hashtbl.add generated_structs display placeholder;
    let variants=List.map(fun v->{v with payload=Option.map(fun t->concrete_type ~vec_boundary:inherited_vec_boundary v.variant_span(subst bindings t))v.payload})template.variants in
    let fields={field_name="__tag";field_type=U64;field_span=span}::
      List.filter_map(fun v->Option.map(fun t->{field_name="__payload_"^v.variant_name;field_type=t;field_span=v.variant_span})v.payload)variants in
    let d={placeholder with fields} in
    Hashtbl.replace generated_structs display d;Hashtbl.add concrete_enums display {template with enum_name=display;type_params=[];variants};
    Hashtbl.add concrete_enum_args display args;Hashtbl.remove active_instances display;Hashtbl.remove active_aggregates name;d
  and instantiate_tuple span args =
    let display=key "$Tuple" args in
    Hashtbl.replace tuple_shapes display args;
    match Hashtbl.find_opt generated_structs display with Some d->d|None->
    let fields=List.mapi(fun i t->{field_name="__item_"^string_of_int i;field_type=t;field_span=span})args in
    let d={struct_name=display;type_params=[];fields;struct_span=span} in Hashtbl.add generated_structs display d;d
  in
  let unify span bindings pattern actual =
    let rec go p a=match p with
    | Type_var n->let a=Type_desc.canonicalize a in
        (match Hashtbl.find_opt bindings n with None->Hashtbl.add bindings n a|Some old when old=a->()
         |Some old->fail span(Printf.sprintf "conflicting inference for type parameter '%s': %s and %s"
             n (string_of_typ old) (string_of_typ a)))
    | Tuple ps->let xs=match a with Tuple xs->Some xs
        |Named n->Hashtbl.find_opt tuple_shapes n
        |_->None in
        (match xs with Some xs when List.length ps=List.length xs->List.iter2 go ps xs|_->())
    | Apply(n,[p]) when n="core.box.Box" || (n="Box" && not(Hashtbl.mem type_names n))->(match a with Box x->go p x|_->())
    | Box p->(match a with Box x->go p x|_->())
    | Apply(n,ps)->(match a with
        | Apply(m,xs) when n=m&&List.length ps=List.length xs->List.iter2 go ps xs
        | Named display->
            let args=match Hashtbl.find_opt concrete_struct_args display with
              | Some args->Some args|None->Hashtbl.find_opt concrete_enum_args display in
            (match args with Some xs when display=key n xs&&List.length ps=List.length xs->List.iter2 go ps xs|_->())
        |_->())
    | Vec p->(match a with Vec x->go p x|_->())|Slice p->(match a with Slice x->go p x|_->())|Ptr p->(match a with Ptr x->go p x|_->())
    | Ref(m,p)->(match a with Ref(n,x)when m=n || not m->go p x|_->())
    | Function(ps,r)->(match a with Function(xs,y) when List.length ps=List.length xs->List.iter2 go ps xs;go r y|_->())
    |_->() in go pattern actual in
  let rec infer_expr ?(bindings=[]) env expected (e:expr) =
    let expected=Option.map(subst bindings)expected in
    let infer expected x=infer_expr ~bindings env expected x in
    match e.node with
    | Intrinsic _->Some I64
    | Int_lit _->(match expected with Some t when Type_desc.is_integer t->Some t|_->Some I64)
    | Float_lit _->(match expected with Some t when Type_desc.is_float t->Some t|_->Some F64)
    | String_lit _->Some String|Bool_lit _->Some Bool|Var n->(match Hashtbl.find_opt env n with
        |Some _ as t->t|None->let resolved=match Hashtbl.find_opt env "$module"with
          |Some(Named m) when not(String.contains n '.')->m^"."^n|_->n in
          (match List.find_opt(fun(f:func)->f.name=resolved&&f.type_params=[])program.functions with
          |Some f->Some(Function(List.map(fun(p:param)->concrete_type p.span p.typ)f.params,concrete_type f.span f.return_type))|None->None))
    | Unary("!",_)->Some Bool
    | Unary("*",x)->(match infer None x with Some(Ref(_,t))|Some(Box t)->Some t|_->expected)
    | Unary(_,x)->infer expected x
    | Borrow(m,x)->Option.map(fun t->Ref(m,t))(infer None x)
    | Binary(("=="|"!="|"<"|"<="|">"|">="|"&&"|"||"),_,_)->Some Bool
    | Binary(_,left,right)->
        (match infer expected left with
         | Some t->Some t
         | None->infer expected right)
    | Tuple_lit []->Some Unit
    | Tuple_lit xs->let expected_items=match expected with Some(Named n)->Option.map(fun d->List.map(fun f->f.field_type)d.fields)(named_struct n)|_->None in
        let ts=match expected_items with Some ts when List.length ts=List.length xs->Some ts
          |_->let ts=List.map(infer None)xs in
              if List.for_all Option.is_some ts then Some(List.map Option.get ts) else None in
        Option.map(fun ts->ignore(instantiate_tuple e.span ts);Named(key "$Tuple" ts))ts
    | Vec_lit xs->
        let element=match expected with Some(Vec t)->Some t|_->
          (match xs with x::_->infer None x|[]->None) in
        Option.map(fun t->Vec t)element
    | Index(r,_)->(match infer None r with
        |Some(Vec t)|Some(Slice t)|Some(Ref(_,Vec t))->Some t|_->None)
    | Struct_lit(n,_)->Some(Named n)|Generic_struct_lit(n,args,_)->
        let args=List.map(subst bindings)args in
        let layout=instantiate_struct e.span n args in Some(Named layout.struct_name)
    | Variant_lit(n,args,v,payload)->if args<>[] then
        let args=List.map(fun t->concrete_type e.span(subst bindings t))args in
        let layout=instantiate_enum e.span n args in Some(Named layout.struct_name)
      else
        (match expected with Some _ as t->t|None->
         match Hashtbl.find_opt enum_templates n with Some template->
           let inferred=Hashtbl.create 8 in
           (match List.find_opt(fun q->q.variant_name=v)template.variants,payload with
            |Some {payload=Some pattern;_},Some value->Option.iter(unify value.span inferred pattern)(infer None value)
            |_->());
           let args=List.filter_map(fun p->Hashtbl.find_opt inferred p)template.type_params in
           if List.length args=List.length template.type_params then
             (ignore(instantiate_enum e.span n args);Some(Named(key n args))) else None
         |None->None)
    | If_expr(_,yes,no)->(match expected with Some _ as t->t|None->
        (match infer None yes with Some _ as t->t|None->infer None no))
    | Match_control(_,typ,_,_)->Some typ
    | Call(("open_read"|"open_write"),_)->Some File
    | Call(("read_text"|"arg"|"int_to_str"),_)->Some String
    | Call(("arg_count"|"len"|"ptr_addr"|"syscall0"|"syscall1"|"syscall2"|"syscall3"|"syscall4"|"syscall5"|"syscall6"),_)->Some I64
    | Call(("i8"|"u8"|"i16"|"u16"|"i32"|"u32"|"i64"|"u64"|"f32"|"f64"|"int"|"float" as n),_)->
        Some(match n with "i8"->I8|"u8"->U8|"i16"->I16|"u16"->U16|"i32"->I32|"u32"->U32
          |"u64"->U64|"f32"->F32|"f64"|"float"->F64|_->I64)
    | Call(("zeros"|"read_ints"),_)->Some(Vec I64)
    | Call("read_floats",_)->Some(Vec F64)
    | Call("repeat",x::_)->Option.map(fun t->Vec t)(infer None x)
    | Call("raw_alloc_int",_)->Some(Ptr I64)
    | Generic_call("raw_alloc",[t],_)->Some(Ptr(concrete_type e.span(subst bindings t)))
    | Call("raw_load_int",_)->Some I64
    | Call("raw_load",p::_)|Generic_call("raw_load",_,p::_)->
        (match infer None p with Some(Ptr t)->Some t|_->None)
    | Generic_call("ptr_addr",_,_)->Some I64
    | Call(("raw_store"|"raw_free"|"raw_store_int"|"raw_free_int"),_)
    | Generic_call(("raw_store"|"raw_free"),_,_)->Some Unit
    | Call(("print"|"println"|"assert"|"assert_msg"|"panic"|"$unit"),_)->Some Unit
    | Call(n,[x]) when box_constructor env n->
        let target=match expected with Some(Box t)->Some t|_->None in
        Option.map(fun t->Box t)(infer target x)
    | Generic_call(n,[t],_) when box_constructor env n->Some(Box(concrete_type e.span(subst bindings t)))
    | Method(r,("as_ref"|"as_mut"|"into_inner" as name),[])->
        (match infer None r with
         |Some(Box t)|Some(Ref(_,Box t))->Some(if name="into_inner"then t else Ref(name="as_mut",t))
         |_->expected)
    | Call(n,xs)->(match call_type env n [] xs with
        |Some t->let t=subst bindings t in if dependent t then None else Some(concrete_type e.span t)
        |None->
        (match Hashtbl.find_opt generated_fns n with Some f->Some f.return_type|None->
         match List.find_opt(fun (f:func)->f.name=n)program.functions with
         |Some f when f.type_params=[]->Some(concrete_type e.span f.return_type)|_->expected))
    | Generic_call(n,args,xs)->(match call_type env n (List.map(subst bindings)args) xs with
        |Some t->let t=subst bindings t in if dependent t then None else Some(concrete_type e.span t)
        |None->
          (match Hashtbl.find_opt generated_fns n with Some f->Some f.return_type|None->
           match List.find_opt(fun (f:func)->f.name=n)program.functions with
           |Some f when f.type_params=[]->Some(concrete_type e.span f.return_type)|_->expected))
    | Field(r,n)->(match infer None r with Some(Named owner)|Some(Ref(_,Named owner))->
        (match named_struct owner with Some d->Option.map(fun f->f.field_type)(List.find_opt(fun f->f.field_name=n)d.fields)|None->expected)
        |_->expected)
    | Tuple_index(r,digits)->(match infer None r with
        |Some(Named owner)|Some(Ref(_,Named owner)) when String.starts_with ~prefix:"$Tuple<" owner->
          (match int_of_string_opt digits,named_struct owner with
           |Some i,Some d when i >= 0 && i < List.length d.fields->Some(List.nth d.fields i).field_type
           |_->expected)
        |_->expected)
    | Try x->(match infer None x with
        |Some(Named result)->(match Hashtbl.find_opt concrete_enum_args result with
          |Some(ok::_error::_) when String.length result >= 6 && String.sub result 0 6 = "Result"->Some ok
          |_->expected)
        |_->expected)
    | Method(r,"iter",[])->(match infer None r with
        |Some(Vec t)|Some(Slice t)->Some(Named(key "std.iter.SliceIter" [t]))
        |Some String->Some(Named(key "std.iter.SliceIter" [U8]))
        |Some(Ptr t)->Some(Named(key "std.iter.PtrIter" [t]))
        |_->expected)
    | Method(r,"enumerate",[])->(match infer None r with
        |Some iterator->
          let display=match iterator with Named n->n|_->"" in
          let base=match String.index_opt display '<' with Some i->String.sub display 0 i|None->display in
          let method_name="__method$"^base^"$next" in
          let result=match Hashtbl.find_opt fn_templates method_name with
            |Some f->let args=Option.value ~default:[] (Hashtbl.find_opt concrete_struct_args display) in
              concrete_type e.span(subst(List.combine f.type_params args)f.return_type)
            |None->(match List.find_opt(fun(f:func)->f.name=method_name)program.functions with Some f->concrete_type e.span f.return_type|None->Unit) in
          (match result with Named option when Hashtbl.mem concrete_enum_args option->
             let item=List.hd(Hashtbl.find concrete_enum_args option) in
             Some(Named(key "std.iter.Enumerate" [iterator;item]))
           |_->expected)
        |_->expected)
    | Method(r,n,_)->
        let receiver=match infer None r with Some(Ref(_,t))->Some t|t->t in
        (match receiver,n with
         |Some(Vec _|Slice _|String),"len"|Some(Ptr _),"$bounds_len"->Some I64
         |Some(Vec t), ("get"|"pop")|Some(Slice t),"get"->Some t
         |Some(Vec t), ("as_slice"|"slice")->Some(Slice t)
         |Some String,"as_bytes"->Some(Slice U8)
         |Some(Vec U8),"into_string"|Some File,"read"->Some String
         |Some File,"is_open"->Some Bool
         |Some(Vec _),("set"|"push")|Some File,("write"|"close")->Some Unit
         |Some(Named owner),name->(match named_struct owner with
             |Some d->(match List.find_opt(fun f->f.field_name=name)d.fields with
                 |Some {field_type=Function(_,r);_}->Some r|_->expected)
             |None->expected)
         |_->expected)
    | _->expected in
  let rec record_concrete_pattern env typ p = match p.pattern_node with
    |Binding_pattern n->Hashtbl.replace env n typ
    |Wildcard_pattern->()
    |Tuple_pattern ps->(match typ with
        |Named n when String.starts_with ~prefix:"$Tuple<" n->
            let fs=(Hashtbl.find generated_structs n).fields in
            if List.length ps<>List.length fs then fail p.pattern_span(Printf.sprintf "tuple pattern expects %d elements"(List.length fs));
            List.iter2(fun p f->record_concrete_pattern env f.field_type p)ps fs
        |_->fail p.pattern_span("tuple pattern cannot match "^string_of_typ typ))
    |_->fail p.pattern_span "let pattern supports bindings, _, and nested tuples" in
  let rec default_expr span typ =
    let node=match typ with
    | t when Type_desc.is_integer t->Int_lit "0"|t when Type_desc.is_float t->Float_lit 0.0
    | Bool->Bool_lit false|String->String_lit ""|Unit->Call("$unit",[])
    | Vec _->Vec_lit []
    | Box t->Generic_call("$inactive_box",[t],[])
    | Ptr t->Generic_call("$inactive_ptr",[t],[])
    | Slice t->Generic_call("$inactive_slice",[t],[])
    | Tuple ts->Tuple_lit(List.map(default_expr span)ts)
    | Named n->let d=match named_struct n with Some d->d|None->fail span("cannot construct default for "^n) in
        Struct_lit(n,List.map(fun f->f.field_name,default_expr span f.field_type,f.field_span)d.fields)
    | File->Call("$inactive_file",[])
    | t->fail span("cannot construct inactive enum payload of type "^string_of_typ t) in
    {node;span}
  in
  let rec transform_expr env expected bindings (e:expr) =
    let tr ?expected x=transform_expr env expected bindings x in
    let node=match e.node with
    | Intrinsic(kind,types,xs)->Intrinsic(kind,List.map(fun t->concrete_type e.span(subst bindings t))types,List.map(fun x->tr x)xs)
    | Unary(op,x)->Unary(op,tr x)|Binary(op,a,b)->Binary(op,tr a,tr b)
    | Vec_lit xs->
        (* Constructors are resolved here, before the typed checker can supply
           collection context.  Preserve it through every literal element. *)
        let element_expected=match expected with Some(Vec t)->Some t|_->None in
        Vec_lit(List.map(fun x->tr ?expected:element_expected x)xs)
    | Tuple_lit []->Call("$unit",[])
    | Tuple_lit xs->let expected_items=match expected with Some(Named n)->Option.map(fun d->List.map(fun f->f.field_type)d.fields)(named_struct n)|_->None in
        let xs=match expected_items with Some ts when List.length ts=List.length xs->List.map2(fun t x->tr ~expected:t x)ts xs|_->List.map tr xs in
        let ts=match expected_items with Some ts when List.length ts=List.length xs->ts|_->List.map(fun x->
          match infer_expr ~bindings env None x with Some t->t|None->fail x.span "cannot infer tuple element type")xs in
        let layout=instantiate_tuple e.span ts in Struct_lit(layout.struct_name,List.mapi(fun i x->"__item_"^string_of_int i,x,e.span)xs)
    | Index(a,b)->Index(tr a,tr b)
    | Method(r,"iter",[]) ->
        let receiver=tr r in
        let require_std name = if not(Hashtbl.mem struct_templates name) then
          fail e.span "iterator factory requires explicit 'use std.iter;'" in
        let zero:expr={node=Int_lit "0";span=e.span} in
        (match infer_expr ~bindings env None r with
         |Some(Vec t)->if describe e.span t |> fun d->d.move_only then
             fail e.span("cannot iterate move-only "^string_of_typ t^" by reference; consuming into_iter() is not supported yet");
             require_std "std.iter.SliceIter";ignore(instantiate_struct e.span "std.iter.SliceIter" [t]);
             Struct_lit(key "std.iter.SliceIter" [t],["items",{node=Method(receiver,"as_slice",[]);span=e.span},e.span;"index",zero,e.span])
         |Some(Slice t)->if describe e.span t |> fun d->d.move_only then
             fail e.span("cannot iterate move-only "^string_of_typ t^" by reference; consuming into_iter() is not supported yet");
             require_std "std.iter.SliceIter";ignore(instantiate_struct e.span "std.iter.SliceIter" [t]);
             Struct_lit(key "std.iter.SliceIter" [t],["items",receiver,e.span;"index",zero,e.span])
         |Some String->require_std "std.iter.SliceIter";ignore(instantiate_struct e.span "std.iter.SliceIter" [U8]);
             Struct_lit(key "std.iter.SliceIter" [U8],["items",{node=Method(receiver,"as_bytes",[]);span=e.span},e.span;"index",zero,e.span])
         |Some(Ptr t)->require_std "std.iter.PtrIter";ignore(instantiate_struct e.span "std.iter.PtrIter" [t]);
             Struct_lit(key "std.iter.PtrIter" [t],["pointer",receiver,e.span;"index",zero,e.span;"length",{node=Method(receiver,"$bounds_len",[]);span=e.span},e.span])
         |Some t->fail e.span("iter() is not supported for "^string_of_typ t)|None->fail e.span "cannot infer iter() receiver type")
    | Method(r,"enumerate",[]) ->
        let receiver=tr r in
        let iterator=match infer_expr ~bindings env None r with Some t->concrete_type e.span t|None->fail e.span "cannot infer enumerate() receiver type" in
        let display=match iterator with Named n->n|_->fail e.span "enumerate() receiver must satisfy next(&mut self) -> Option<T>" in
        let base=match String.index_opt display '<' with Some i->String.sub display 0 i|None->display in
        let method_name="__method$"^base^"$next" in
        let result=match Hashtbl.find_opt fn_templates method_name with
          |Some _->let args=Option.value ~default:[] (Hashtbl.find_opt concrete_struct_args display) in
            let target=instantiate_fn e.span method_name args in
            let f=Hashtbl.find generated_fns target in
            if List.map(fun(p:param)->p.typ)f.params<>[Ref(true,iterator)] then
              fail e.span("iterator next must have signature next(&mut self) -> Option<T>; found "^string_of_typ(Function(List.map(fun(p:param)->p.typ)f.params,f.return_type)));
            f.return_type
          |None->(match List.find_opt(fun(f:func)->f.name=method_name)program.functions with Some f->
              let params=List.map(fun(p:param)->concrete_type p.span p.typ)f.params in
              if params<>[Ref(true,iterator)] then fail e.span("iterator next must have signature next(&mut self) -> Option<T>; found "^string_of_typ(Function(params,f.return_type)));
              concrete_type e.span f.return_type
            |None->fail e.span("type "^display^" has no next(&mut self) -> Option<T> method")) in
        let item=match result with Named option when Hashtbl.mem concrete_enum_args option &&
          (match String.index_opt option '<' with Some i->String.sub option 0 i="Option"|None->false)->List.hd(Hashtbl.find concrete_enum_args option)
          |_->fail e.span("iterator next must have signature next(&mut self) -> Option<T>") in
        if not(Hashtbl.mem struct_templates "std.iter.Enumerate") then fail e.span "iterator factory requires explicit 'use std.iter;'";
        ignore(instantiate_struct e.span "std.iter.Enumerate" [iterator;item]);
        let zero:expr={node=Int_lit "0";span=e.span} in
        let consumed:expr={node=Call("$consume",[receiver]);span=e.span} in
        Struct_lit(key "std.iter.Enumerate" [iterator;item],["iterator",consumed,e.span;"index",zero,e.span])
    | Method(r,n,xs)->
        let receiver=tr r in
        let owner=match infer_expr ~bindings env None r with Some(Named q)->Some q|Some(Ref(_,Named q))->Some q|_->None in
        if Hashtbl.mem structural_next e.span then begin
          let bad ()=fail e.span "structural iterator requires next(&mut self) -> Option<T>" in
          match owner with None->bad ()|Some display->
            let base=match String.index_opt display '<'with Some i->String.sub display 0 i|None->display in
            let method_name="__method$"^base^"$next" in
            let f=match List.find_opt(fun(f:func)->f.name=method_name)program.functions with Some f->f|_->bad () in
            let args=Option.value ~default:[](Hashtbl.find_opt concrete_struct_args display)in
            if List.length f.type_params<>List.length args then bad ();
            let types=List.combine f.type_params args in
            (match f.params with
             |[{typ=Ref(true,t);_}] when concrete_type e.span(subst types t)=Named display->()
             |_->bad ());
            (match concrete_type e.span(subst types f.return_type)with
             |Named option when Hashtbl.mem concrete_enums option &&
               (match String.index_opt option '<'with Some i->String.sub option 0 i|None->option)="Option"->()
             |_->bad ())
        end;
        (match owner with
         | Some display->
             let base=match String.index_opt display '<' with Some i->String.sub display 0 i|None->display in
             let method_name="__method$"^base^"$"^n in
             if Hashtbl.mem fn_templates method_name then
               let args=match Hashtbl.find_opt concrete_struct_args display with Some xs->xs|None->[] in
               let target=instantiate_fn e.span method_name args in
               let signature=Hashtbl.find generated_fns target in
               let values=receiver::List.map tr xs in
               Call(target,List.map2(fun (p:param) x->transform_expr env (Some p.typ) bindings x)signature.params values)
             else if List.exists(fun (f:func)->f.name=method_name)program.functions then
               Call(method_name,receiver::List.map tr xs)
             else Method(receiver,n,List.map tr xs)
         | None->Method(receiver,n,List.map tr xs))
    | Borrow(m,x)->Borrow(m,tr x)
    | Field(r,n)->Field(tr r,n)
    | Tuple_index(r,digits)->
        let receiver=tr r in
        let owner=match infer_expr ~bindings env None r with
          |Some(Named n)|Some(Ref(_,Named n)) when String.starts_with ~prefix:"$Tuple<" n->n
          |Some t->fail e.span("tuple index access requires a tuple receiver, found "^string_of_typ t)
          |None->fail e.span "cannot infer tuple receiver type" in
        let layout=match named_struct owner with Some d->d|None->fail e.span "cannot resolve tuple layout" in
        let index=match int_of_string_opt digits with Some i->i|None->fail e.span "tuple index is too large" in
        if index >= List.length layout.fields then
          fail e.span(Printf.sprintf "tuple index %s is out of range for %d-element tuple" digits (List.length layout.fields));
        Field(receiver,"__item_"^digits)
    | Try x->Try(tr x)
    | Struct_lit(n,fs) when Hashtbl.mem struct_templates n->
        let template=Hashtbl.find struct_templates n in let inferred=Hashtbl.create 8 in
        List.iter(fun(name,x,_)->match List.find_opt(fun f->f.field_name=name)template.fields,infer_expr ~bindings env None x with
          |Some f,Some t->unify x.span inferred f.field_type t|_->())fs;
        let args=List.mapi(fun i p->match Hashtbl.find_opt inferred p with Some t->t|None->
          (match expected with Some(Named display) when Hashtbl.mem concrete_struct_args display->List.nth(Hashtbl.find concrete_struct_args display)i
           |_->fail e.span("cannot infer type parameter '"^p^"'")))template.type_params in
        ignore(instantiate_struct e.span n args);Struct_lit(key n args,List.map(fun(n,x,s)->n,tr x,s)fs)
    | Struct_lit(n,fs)->Struct_lit(n,List.map(fun(n,x,s)->n,tr x,s)fs)
    | Generic_struct_lit(n,args,fs)->let args=List.map(fun t->concrete_type e.span(subst bindings t))args in
        ignore(instantiate_struct e.span n args);Struct_lit(key n args,List.map(fun(n,x,s)->n,tr x,s)fs)
    | Variant_lit(n,args,v,x)->
        let template=match Hashtbl.find_opt enum_templates n with Some d->d|None->fail e.span("unknown enum '"^n^"'") in
        let args=if args<>[] then List.map(fun t->concrete_type e.span(subst bindings t))args else
          match expected with Some(Named display) when Hashtbl.mem concrete_enum_args display &&
            (match String.index_opt display '<' with Some i->String.sub display 0 i=n|None->display=n)->Hashtbl.find concrete_enum_args display
          |_->let inferred=Hashtbl.create 8 in
          let variant=match List.find_opt(fun q->q.variant_name=v)template.variants with Some q->q|None->fail e.span("unknown variant '"^v^"' for "^n) in
          (match variant.payload,x with Some p,Some value->(match infer_expr ~bindings env None value with Some t->unify value.span inferred p t|None->())|None,None->()|_->fail e.span("wrong payload arity for "^n^"."^v));
          (* A matching enum expectation was handled above.  An unrelated enum
             must not supply missing arguments by their parameter positions. *)
          List.map(fun p->match Hashtbl.find_opt inferred p with Some t->t|None->
            fail e.span("cannot infer type parameter '"^p^"'"))template.type_params in
        let layout=instantiate_enum e.span n args in let enum=Hashtbl.find concrete_enums layout.struct_name in
        let tag=let rec find i=function []->fail e.span("unknown variant '"^v^"'")|q::qs->if q.variant_name=v then i else find(i+1)qs in find 0 enum.variants in
        let concrete_variant=List.find(fun q->q.variant_name=v)enum.variants in
        let payload=match concrete_variant.payload,x with
          |Some typ,Some value->Some(transform_expr env (Some typ) bindings value)
          |None,None->None|_->fail e.span("wrong payload arity for "^n^"."^v) in
        let fields=List.map(fun (f:struct_field)->
          let value:expr=if f.field_name="__tag" then {node=Int_lit(string_of_int tag);span=e.span}
            else if f.field_name="__payload_"^v then (match payload with Some x->x|None->fail e.span("variant '"^v^"' requires a payload"))
            else default_expr e.span f.field_type in f.field_name,value,f.field_span)layout.fields in
        Struct_lit(layout.struct_name,fields)
    | Generic_call(n,args,xs) when box_constructor env n->
        if List.length args<>1 then fail e.span "box expects 1 type argument";
        Generic_call("$box_new",List.map(fun t->concrete_type e.span(subst bindings t))args,List.map tr xs)
    | Generic_call(("$inactive_box"|"raw_alloc"|"raw_load"|"raw_store"|"raw_free"|"ptr_addr" as n),args,xs)->
        Generic_call(n,List.map(fun t->concrete_type e.span(subst bindings t))args,List.map tr xs)
    | Generic_call(n,args,xs)->
        let args=List.map(fun t->concrete_type e.span(subst bindings t))args in
        let target=instantiate_fn e.span n args in
        let signature=Hashtbl.find generated_fns target in
        let values=if List.length signature.params=List.length xs then
          List.map2(fun (p:param) x->transform_expr env (Some p.typ) bindings x)signature.params xs else List.map tr xs in
        Call(target,values)
    | Call(n,xs) when box_constructor env n->
        let target=match expected with Some(Box t)->Some t|_->None in
        Call("$box_new",List.map(transform_expr env target bindings)xs)
    | Call(n,xs) when (match local_call env n with Some(Function _)->true|_->false)->
        (match local_call env n with
         |Some(Function(params,_)) when List.length params=List.length xs->
             Call(n,List.map2(fun typ x->transform_expr env (Some typ)bindings x)params xs)
         |_->Call(n,List.map tr xs))
    | Call(n,xs) when Hashtbl.mem fn_templates n->
        let template=Hashtbl.find fn_templates n in let inferred=Hashtbl.create 8 in
        if List.length template.params<>List.length xs then fail e.span
          (Printf.sprintf "function '%s' expects %d arguments" n (List.length template.params));
        (* The surrounding result type is deliberately not an inference source.
           Direct type-variable arguments are lowered without context so nested
           calls and aggregate type arguments are concrete before probing. Defer
           ambiguous constructors and other parameters to the existing concrete
           parameter checking path. *)
        let lowered=List.map2(fun (p:param) (x:expr)->match p.typ,x.node with
          |Type_var _,(Variant_lit _|Vec_lit []) when infer_expr ~bindings env None x=None->None
          |Type_var _,_->let value=tr x in
              Option.iter(unify x.span inferred p.typ)(infer_expr ~bindings env None value);Some value
          |_->Option.iter(unify x.span inferred p.typ)(infer_expr ~bindings env None x);None)template.params xs in
        let args=List.map(fun p->match Hashtbl.find_opt inferred p with Some t->t|None->
          let call_name=match Hashtbl.find_opt env "$module" with
            |Some(Named owner) when String.starts_with ~prefix:(owner^".")n->
                String.sub n (String.length owner+1)(String.length n-String.length owner-1)
            |_->n in
          let examples=List.map(fun p->match Hashtbl.find_opt inferred p with
            |Some t->string_of_typ t|None->"I64")template.type_params in
          fail ~help:("specify all type arguments explicitly, for example: "^call_name^"<"^
            String.concat ", " examples^">"^(if xs=[] then "()" else "(...)"))e.span("cannot infer type parameter '"^p^"'"))template.type_params in
        let target=instantiate_fn e.span n args in
        let signature=Hashtbl.find generated_fns target in
        Call(target,List.map2(fun (p:param)(x,lowered)->match lowered with Some x->x
          |None->transform_expr env (Some p.typ) bindings x)signature.params(List.combine xs lowered))
    | Call(n,xs)->
        let signature=match Hashtbl.find_opt generated_fns n with Some f->Some f
          |None->List.find_opt(fun (f:func)->f.name=n)program.functions in
        Call(n,match signature with Some f when List.length f.params=List.length xs->
          List.map2(fun (p:param) x->transform_expr env (Some(concrete_type p.span p.typ)) bindings x)f.params xs
          |_->List.map tr xs)
    | Match(x,arms)->
        if arms=[] then fail e.span "match must contain at least one arm";
        let scrutinee=tr x in
        let scrutinee_type=match infer_expr ~bindings env None scrutinee with Some t->concrete_type e.span t|None->fail e.span "cannot infer match scrutinee type" in
        let tuple_fields typ=match typ with Named n when String.starts_with ~prefix:"$Tuple<" n->
          (Hashtbl.find generated_structs n).fields|_->fail e.span("tuple pattern cannot match "^string_of_typ typ) in
        let enum_of typ span=match typ with Named n->(match Hashtbl.find_opt concrete_enums n with Some d->d|None->fail span("variant pattern cannot match "^string_of_typ typ))
          |_->fail span("variant pattern cannot match "^string_of_typ typ) in
        let owner_name n=match String.index_opt n '<' with Some i->String.sub n 0 i|None->n in
        let rec validate names typ p = match p.pattern_node with
        | Wildcard_pattern->()
        | Binding_pattern n->if Hashtbl.mem names n then fail p.pattern_span("duplicate pattern binding '"^n^"'")else Hashtbl.add names n typ
        | Literal_pattern lit->(match lit.node with
            |Int_lit _ when Type_desc.is_integer typ->()|Float_lit _ when Type_desc.is_float typ->()
            |String_lit _ when typ=String->()|Bool_lit _ when typ=Bool->()
            |_->fail p.pattern_span("literal pattern does not have type "^string_of_typ typ))
        | Tuple_pattern ps->let fs=tuple_fields typ in
            if List.length ps<>List.length fs then fail p.pattern_span(Printf.sprintf "tuple pattern expects %d elements"(List.length fs));
            List.iter2(fun q f->validate names f.field_type q)ps fs
        | Variant_pattern(owner,v,payload)->let enum=enum_of typ p.pattern_span in
            if owner<>owner_name enum.enum_name then fail p.pattern_span("pattern must name enum '"^enum.enum_name^"'");
            let variant=match List.find_opt(fun q->q.variant_name=v)enum.variants with Some q->q|None->fail p.pattern_span("unknown variant '"^v^"'") in
            (match variant.payload,payload with None,None->()|Some t,Some q->validate names t q
             |None,Some _->fail p.pattern_span("variant '"^v^"' has no payload")
             |Some _,None->fail p.pattern_span("variant '"^v^"' requires a payload pattern")) in
        let bindings_of p=let names=Hashtbl.create 8 in validate names scrutinee_type p;names in
        let arm_bindings=List.map(fun a->bindings_of a.pattern)arms in
        let literal_equal a b=match a,b with Int_lit x,Int_lit y->x=y|Float_lit x,Float_lit y->x=y
          |String_lit x,String_lit y->x=y|Bool_lit x,Bool_lit y->x=y|_->false in
        let relevant_for_variant v ps=List.filter_map(fun p->match p.pattern_node with
          |Variant_pattern(_,q,Some x)when q=v->Some x|Wildcard_pattern|Binding_pattern _->None|_->None)ps in
        let rec cartesian=function []->[[]]|xs::rest->List.concat_map(fun x->List.map(fun tail->x::tail)(cartesian rest))xs in
        let rec universe typ ps = match typ with
        | Bool->[W_literal(Bool_lit false);W_literal(Bool_lit true)]
        | Named n when Hashtbl.mem concrete_enums n->let d=Hashtbl.find concrete_enums n in
            List.concat_map(fun v->match v.payload with None->[W_variant(v.variant_name,None)]|Some t->
              List.map(fun w->W_variant(v.variant_name,Some w))(universe t(relevant_for_variant v.variant_name ps)))d.variants
        | Named n when String.starts_with ~prefix:"$Tuple<" n->let fs=(Hashtbl.find generated_structs n).fields in
            let child i=List.filter_map(fun p->match p.pattern_node with Tuple_pattern qs->Some(List.nth qs i)|_->None)ps in
            List.map(fun ws->W_tuple ws)(cartesian(List.mapi(fun i f->universe f.field_type(child i))fs))
        | _->let literals=List.fold_left(fun out p->match p.pattern_node with Literal_pattern l when not(List.exists(literal_equal l.node)out)->l.node::out|_->out)[]ps in
            List.map(fun n->W_literal n)literals @ [W_other] in
        let rec matches p w=match p.pattern_node,w with
        |(Wildcard_pattern|Binding_pattern _),_->true
        |Literal_pattern l,W_literal n->literal_equal l.node n
        |Tuple_pattern ps,W_tuple ws->List.for_all2 matches ps ws
        |Variant_pattern(_,v,None),W_variant(q,None)->v=q
        |Variant_pattern(_,v,Some p),W_variant(q,Some w)->v=q&&matches p w
        |_->false in
        let witnesses=universe scrutinee_type(List.map(fun a->a.pattern)arms) in
        let covered=ref [] in List.iter(fun arm->
          if not(List.exists(fun w->matches arm.pattern w&&not(List.exists(fun p->matches p w)!covered))witnesses)
          then fail arm.arm_span "unreachable pattern";
          covered:=arm.pattern::!covered)arms;
        let missing=List.find_opt(fun w->not(List.exists(fun p->matches p w)!covered))witnesses in
        let rec witness_text=function W_other->"_"|W_literal(Int_lit s)->s|W_literal(Float_lit f)->string_of_float f
          |W_literal(String_lit s)->Printf.sprintf "%S" s|W_literal(Bool_lit b)->string_of_bool b
          |W_tuple ws->"("^String.concat ", "(List.map witness_text ws)^")"
          |W_variant(v,None)->v|W_variant(v,Some w)->v^"("^witness_text w^")"|W_literal _->"_" in
        Option.iter(fun w->fail e.span("non-exhaustive match; missing "^witness_text w))missing;
        let result_arm_env i=let local=Hashtbl.copy env in Hashtbl.iter(Hashtbl.replace local)(List.nth arm_bindings i);
          List.iter(fun(s:stmt)->match s.node with
            |Let(_,n,t,x)->Option.iter(Hashtbl.replace local n)(match t with Some t->Some(concrete_type s.span(subst bindings t))|None->infer_expr ~bindings local None x)
            |Let_pattern(_,p,t,x)->Option.iter(fun typ->record_concrete_pattern local typ p)(match t with Some t->Some(concrete_type s.span(subst bindings t))|None->infer_expr ~bindings local None x)
            |_->())(List.nth arms i).body;
          local in
        let result_type=match expected with Some t->t|None->
          let rec first saw_tail i=function []->if saw_tail then fail e.span "cannot infer match result type" else Unit
            |a::rest->match a.tail with Some t->(match infer_expr ~bindings (result_arm_env i)None t with Some typ->typ|None->first true(i+1)rest)
              |None->first saw_tail(i+1)rest in first false 0 arms in
        incr match_counter;
        let scrutinee_name="__match_scrutinee_"^string_of_int !match_counter in
        let expr (node:expr_node):expr={node;span=e.span} and stmt (node:stmt_node):stmt={node;span=e.span} in
        let scr=expr(Var scrutinee_name) in
        let path_expr path=List.fold_left(fun x f->expr(Field(x,f)))scr path in
        let rec condition typ path p=match p.pattern_node with
        |Wildcard_pattern|Binding_pattern _->expr(Bool_lit true)
        |Literal_pattern l->expr(Binary("==",path_expr path,transform_expr env(Some typ)bindings l))
        |Tuple_pattern ps->let fs=tuple_fields typ in combine(List.map2(fun q f->condition f.field_type(path@[f.field_name])q)ps fs)
        |Variant_pattern(_,v,payload)->let d=enum_of typ p.pattern_span in
            let rec index i=function []->assert false|q::rest->if q.variant_name=v then i else index(i+1)rest in
            let tag=expr(Binary("==",expr(Field(path_expr path,"__tag")),expr(Int_lit(string_of_int(index 0 d.variants))))) in
            (match payload with None->tag|Some q->let t=Option.get(List.find(fun x->x.variant_name=v)d.variants).payload in
              expr(Binary("&&",tag,condition t(path@["__payload_"^v])q)))
        and combine=function []->expr(Bool_lit true)|[x]->x|x::xs->expr(Binary("&&",x,combine xs)) in
        let rec binding_stmts typ path p=match p.pattern_node with
        |Binding_pattern n->[stmt(Let(false,n,Some typ,path_expr path))]
        |Tuple_pattern ps->let fs=tuple_fields typ in List.concat(List.map2(fun q f->binding_stmts f.field_type(path@[f.field_name])q)ps fs)
        |Variant_pattern(_,v,Some q)->let d=enum_of typ p.pattern_span in let t=Option.get(List.find(fun x->x.variant_name=v)d.variants).payload in binding_stmts t(path@["__payload_"^v])q
        |_->[] in
        let lowered_arms=List.mapi(fun i (arm:match_arm)->
          let local=result_arm_env i in
          let body=transform_stmts local bindings arm.body in
          let tail=Option.map(fun t->transform_expr local(Some result_type)bindings t)arm.tail in
          arm.pattern,condition scrutinee_type[]arm.pattern,
          binding_stmts scrutinee_type[]arm.pattern @ body,tail)arms in
        Match_control(scrutinee_name,result_type,scrutinee,lowered_arms)
    | If_expr(c,yes,no)->
        let result=match expected with Some t->t|None->
          (match infer_expr ~bindings env None yes with Some t->t|None->
           match infer_expr ~bindings env None no with Some t->t|None->fail e.span "cannot infer if expression result type") in
        If_expr(transform_expr env (Some Bool) bindings c,
          transform_expr env (Some result) bindings yes,
          transform_expr env (Some result) bindings no)
    | Match_control _ -> assert false
    | (Int_lit _|Float_lit _|String_lit _|Bool_lit _|Var _)as n->n in {e with node}
  and transform_stmt env bindings (s:stmt) =
    let ex ?expected x=transform_expr env expected bindings x in
    let node=match s.node with
    | Let(m,n,t,x)->let t=Option.map(fun t->concrete_type s.span(subst bindings t))t in
        let x=ex ?expected:t x in (match t with Some t->Hashtbl.replace env n t|None->(match infer_expr ~bindings env None x with Some t->Hashtbl.replace env n t|None->if n="box"then Hashtbl.replace env n Unit));Let(m,n,t,x)
    | Let_pattern(m,p,t,x)->let t=Option.map(fun t->concrete_type s.span(subst bindings t))t in
        let x=ex ?expected:t x in
        let typ=match t with Some t->t|None->(match infer_expr ~bindings env None x with
          |Some t->t|None->fail x.span "cannot infer let pattern initializer type") in
        record_concrete_pattern env typ p;
        Let_pattern(m,p,t,x)
    | Assign(n,x)->Assign(n,ex ?expected:(Hashtbl.find_opt env n)x)|Field_assign(n,f,x)->Field_assign(n,f,ex x)
    | Index_assign(a,b,x)->Index_assign(ex a,ex b,ex x)
    | Deref_assign(a,b)->
        let target=match infer_expr ~bindings env None a with Some(Ref(_,t))->Some t|_->None in
        Deref_assign(ex a,ex ?expected:target b)
    | Expr x->Expr(ex x)|Return x->Return(Option.map(fun x->ex ?expected:(Hashtbl.find_opt env "$return") x)x)|If(c,a,b)->If(ex c,transform_stmts(Hashtbl.copy env)bindings a,transform_stmts(Hashtbl.copy env)bindings b)
    | While(c,b)->While(ex c,transform_stmts(Hashtbl.copy env)bindings b)
    | For(pattern,iterator,body)->
        incr for_counter;let id=string_of_int !for_counter in
        let iterator_name="__for_iter_"^id and option_name="__for_option_"^id in
        let iterator=ex iterator in
        let iterator_type=match infer_expr ~bindings env None iterator with Some t->concrete_type s.span t|None->fail s.span "cannot infer iterator type" in
        Hashtbl.replace env iterator_name iterator_type;
        let var n:expr={node=Var n;span=s.span} in
        let next=transform_expr env None bindings {node=Method(var iterator_name,"next",[]);span=s.span} in
        let option_type=match infer_expr ~bindings env None next with Some t->concrete_type s.span t|None->fail s.span "iterator next result cannot be inferred" in
        let option_enum=match option_type with Named n->(match Hashtbl.find_opt concrete_enums n with Some d->d|None->fail s.span "iterator next must return Option<T>")|_->fail s.span "iterator next must return Option<T>" in
        let base=match String.index_opt option_enum.enum_name '<' with Some i->String.sub option_enum.enum_name 0 i|None->option_enum.enum_name in
        if base<>"Option" then fail s.span "iterator next must return Option<T>";
        let item_type=match (List.find(fun v->v.variant_name="Some")option_enum.variants).payload with Some t->t|None->assert false in
        Hashtbl.replace env option_name option_type;
        let expr (node:expr_node):expr={node;span=s.span} and stmt (node:stmt_node):stmt={node;span=s.span} in
        let payload=expr(Field(var option_name,"__payload_Some")) in
        let rec bind local typ value p=match p.pattern_node with
          | Wildcard_pattern->[]
          | Binding_pattern n->Hashtbl.replace local n typ;[stmt(Let(false,n,Some typ,value))]
          | Tuple_pattern ps->(match typ with Named n->let fields=(Hashtbl.find generated_structs n).fields in
              if List.length ps<>List.length fields then fail p.pattern_span "tuple pattern arity differs from iterator item";
              List.concat(List.map2(fun q f->bind local f.field_type(expr(Field(value,f.field_name)))q)ps fields)
            |_->fail p.pattern_span "tuple pattern requires a tuple iterator item")
          | _->fail p.pattern_span "for pattern supports bindings, _, and nested tuples" in
        let local=Hashtbl.copy env in
        let bindings_stmts=bind local item_type payload pattern in
        let body=transform_stmts local bindings body in
        let tag=expr(Field(var option_name,"__tag")) in
        let condition=expr(Binary("==",tag,expr(Int_lit "1"))) in
        Block[stmt(Let(true,iterator_name,Some iterator_type,iterator));
          stmt(While(expr(Bool_lit true),[stmt(Let(false,option_name,Some option_type,next));
            stmt(If(condition,bindings_stmts@body,[stmt Break]))]))]
    | Block b->Block(transform_stmts(Hashtbl.copy env)bindings b)
    | Scope(m,b)->
        let old_modes= !enclosing_modes in
        enclosing_modes:=List.fold_left(fun modes mode->if List.mem mode modes then modes else modes@[mode])old_modes m;
        let body=transform_stmts(Hashtbl.copy env)bindings b in
        enclosing_modes:=old_modes;
        Scope(m,body)
    |(Break|Continue)as n->n in {s with node}
  and transform_stmts env bindings xs=List.map(transform_stmt env bindings)xs
  and instantiate_fn span name args =
    let display=key name args in if Hashtbl.mem generated_fns display then display else
    if !instantiation_depth>=64 then fail span "generic recursion keeps expanding its type arguments" else
    let template=Hashtbl.find fn_templates name in
    if List.length args<>List.length template.type_params then fail span(Printf.sprintf "function '%s' expects %d type arguments" name(List.length template.type_params));
    incr instantiation_depth;
    let bindings=List.combine template.type_params args in
    let params=List.map(fun (p:param)->{p with typ=concrete_type p.span(subst bindings p.typ)})template.params in
    let result=concrete_type template.span(subst bindings template.return_type) in
    (* Recursive calls can observe this instance while its body is being lowered.
       Publish its concrete signature rather than the template's type variables. *)
    Hashtbl.add generated_fns display {template with name=display;type_params=[];params;return_type=result;body=[]};
    let env=Hashtbl.create 16 in module_context env template.name;List.iter(fun (p:param)->Hashtbl.add env p.name p.typ)params;Hashtbl.add env "$return" result;
    let mode_set=match params with {name="self";typ=Ref _;_}::_ when not(List.mem Explc template.mode_set)->Explc::template.mode_set|_->template.mode_set in
    let old_modes= !enclosing_modes in enclosing_modes:=mode_set;
    let body=transform_stmts env bindings template.body in enclosing_modes:=old_modes;
    let f={template with name=display;type_params=[];mode_set;params;return_type=result;body} in
    Hashtbl.replace generated_fns display f;decr instantiation_depth;display
  in
  List.iter(fun (d:enum_decl)->if d.type_params=[] then ignore(instantiate_enum d.enum_span d.enum_name []))program.enums;
  let concrete_structs=List.filter_map(fun (d:struct_decl)->
    if d.type_params<>[] then None else
      let fields=List.map(fun f->{f with field_type=concrete_type f.field_span f.field_type})d.fields in
      let d={d with fields} in
      Hashtbl.replace concrete_structs d.struct_name d;
      Some d)program.structs in
  let concrete_functions=List.filter(fun (f:func)->f.type_params=[])program.functions in
  let functions=List.map(fun (f:func)->let env=Hashtbl.create 16 in
    module_context env f.name;
    let params=List.map(fun (p:param)->{p with typ=concrete_type p.span p.typ})f.params in
    let return_type=concrete_type f.span f.return_type in
    let mode_set=match params with {name="self";typ=Ref _;_}::_ when not(List.mem Explc f.mode_set)->Explc::f.mode_set|_->f.mode_set in
    List.iter(fun (p:param)->Hashtbl.add env p.name p.typ)params;Hashtbl.add env "$return" return_type;
    let old_modes= !enclosing_modes in enclosing_modes:=mode_set;
    let body=transform_stmts env [] f.body in enclosing_modes:=old_modes;
    {f with mode_set;params;return_type;body})concrete_functions in
  Ok {program with enums=Hashtbl.fold(fun _ d out->d::out)concrete_enums []; structs=concrete_structs @ Hashtbl.fold(fun _ d xs->d::xs)generated_structs [];
       functions=functions @ Hashtbl.fold(fun _ f xs->f::xs)generated_fns []}
 with Invalid e->Error e
