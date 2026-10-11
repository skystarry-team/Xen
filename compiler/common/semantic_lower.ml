(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
module A = Typed_ast
open Semantic_ir

let lower (program:A.program) =
  let layout name = List.find(fun(l:struct_layout)->l.name=name)program.layouts in
  let rec linear seen = function
    |File|Box _->true|Vec t->linear seen t
    |Named n when not(List.mem n seen)->List.exists(fun(f:struct_field)->match f.typ with Ptr _->true|t->linear(n::seen)t)(layout n).fields
    |_->false in
  let owned = function String|Vec _|File|Box _->true|Named n->(layout n).managed || linear [] (Named n)|_->false in
  let functions=List.mapi(fun fid (fn:A.func)->
    let locals=ref [] and scopes=ref [] and blocks=ref [] in
    let local_count=ref 0 and scope_count=ref 0 and block_count=ref 0 in
    let declarations=Hashtbl.create 16 in
    let new_scope parent modes span = let id= !scope_count in incr scope_count;
      scopes:={id;parent;mode_set=modes;span;declarations=[]}::!scopes;Hashtbl.add declarations id(ref []);id in
    let root_scope=new_scope None fn.mode_set fn.span in
    let current_scope=ref root_scope in
    let new_local ?(temporary=true) ?parameter ?own name typ span =
      let id= !local_count in incr local_count;
      let l:local={id;name;typ;span;scope= !current_scope;owned=Option.value ~default:(owned typ)own;temporary;parameter}in
      locals:=l::!locals;let ds=Hashtbl.find declarations !current_scope in ds:=id::!ds;
      value_of_local l in
    let names=Hashtbl.create 32 in
    let params=List.mapi(fun i(p:param)->let v=new_local ~temporary:false ~parameter:i p.name p.typ p.span in Hashtbl.add names p.name v;v.id)fn.params in
    let block_data=Hashtbl.create 32 in
    let new_block scope=let id= !block_count in incr block_count;Hashtbl.add block_data id(ref [],ref None,scope);id in
    let current=ref(new_block root_scope) in
    let emit span node = let ops,term,_=Hashtbl.find block_data !current in if !term=None then ops:={node;span;scope= !current_scope}::!ops in
    let terminate t=let _,term,_=Hashtbl.find block_data !current in if !term=None then term:=Some t in
    let open_block()=let _,term,_=Hashtbl.find block_data !current in !term=None in
    let storage (v:value)=emit v.span(Storage_live v.id) in
    let temp ?own typ span = let v=new_local ?own "$temporary" typ span in storage v;v in
    let eval typ span r=let v=temp typ span in emit span(Eval(v,r));v in
    let local_place name span = let v=Hashtbl.find names name in {root=v.id;projections=[];typ=v.typ;span} in
    let field p f={p with projections=p.projections@[Field f];typ=f.typ} in
    let acquire span kind (p:place)=let v=temp ~own:(kind<>Read && owned p.typ)p.typ span in emit span(Acquire(v,kind,p));v in
    let consume (v:value)=if owned v.typ then emit v.span(Forget(place_of_value v)) in
    let store init (p:place) (v:value)=emit p.span(if init then Initialize(p,v)else Replace(p,v));consume v in
    let cleanup ?except scope = List.iter(fun id->if Some id<>except then emit fn.span(Storage_dead id)) !(Hashtbl.find declarations scope) in
    let rec exit_to ?except from target = if Some from<>target then begin cleanup ?except from;
      let s=List.find(fun(s:scope)->s.id=from)!scopes in Option.iter(fun p->exit_to ?except p target)s.parent end in
    let loops=ref [] in
    let kind (e:A.expr)=match e.transfer with A.Direct->Read|A.Copy->Copy|A.Clone->if owned e.typ then Clone else Copy|A.Move->Move in
    let rec place (e:A.expr) = match e.node with
      |A.Var n->local_place n e.span
      |A.Field(r,f)->field(place r)f
      |A.Deref r->let p=place_or_value r in {p with projections=p.projections@[Deref];typ=e.typ;span=e.span}
      |A.Index(r,i)->let p=place r in let i=expression i in {p with projections=p.projections@[Element i];typ=e.typ;span=e.span}
      |_->place_of_value(expression e)
    and place_or_value e=match e.A.node with A.Var _|A.Field _|A.Deref _->place e|_->place_of_value(expression e)
    and borrow reserved mut span (p:place) = let v=temp ~own:false (Ref(mut,p.typ))span in emit span(Borrow(v,mut,reserved && mut,p));v
    and operand ?(reserved=false) (e:A.expr)=match e.node with
      |A.Address n->borrow reserved (match e.typ with Ref(m,_)->m|_->false)e.span(local_place n e.span)
      |A.Field_address(r,f)->let p=place r in let p=match p.typ with Ref(_,t)->{p with projections=p.projections@[Deref];typ=t}|_->p in borrow reserved (match e.typ with Ref(m,_)->m|_->false)e.span(field p f)
      |A.Shared_reborrow r->
          let p=place_or_value r in
          let typ=match p.typ with Ref(_,t)->t|_->assert false in
          borrow false false e.span {p with projections=p.projections@[Deref];typ;span=e.span}
      |A.Place_borrow(mut,r)->borrow reserved mut e.span(place r)
      |A.Box_borrow(mut,r)->
          let p=place_or_value r in
          let p=match p.typ with Ref(_,t)->{p with projections=p.projections@[Deref];typ=t}|_->p in
          let typ=match p.typ with Box t->t|_->assert false in
          borrow reserved mut e.span {p with projections=p.projections@[Deref];typ;span=e.span}
      |_->expression e
    and expression (e:A.expr) =
      let ex=expression and ev r=eval e.typ e.span r in
      let unary f x=ev(f(ex x)) and binary f a b=let a=ex a in let b=ex b in ev(f a b) in
      match e.node with
      |A.Int_lit x->ev(Int_lit x)|A.Float_lit x->ev(Float_lit x)|A.String_lit x->ev(String_lit x)|A.Bool_lit x->ev(Bool_lit x)
      |A.Var _|A.Field _|A.Deref _->acquire e.span(kind e)(place e)
      |A.Address _|A.Field_address _|A.Shared_reborrow _|A.Box_borrow _|A.Place_borrow _->operand e
      |A.Unary(op,x)->unary(fun x->Unary(op,x))x
      |A.Binary(("&&"|"||"as op),a,b)->
          let c=ex a in let result=temp ~own:false Bool e.span in
          let yes=new_block !current_scope and no=new_block !current_scope and join=new_block !current_scope in
          terminate(Branch(c,yes,no));
          current:=yes;let v=if op="&&"then ex b else eval Bool e.span(Bool_lit true)in store true(place_of_value result)v;terminate(Jump join);
          current:=no;let v=if op="||"then ex b else eval Bool e.span(Bool_lit false)in store true(place_of_value result)v;terminate(Jump join);
          current:=join;result
      |A.Binary(op,a,b)->binary(fun a b->Binary(op,a,b))a b
      |A.If_expr(c,a,b)->
          let c=ex c in let result=temp e.typ e.span in
          let yes=new_block !current_scope and no=new_block !current_scope and join=new_block !current_scope in
          terminate(Branch(c,yes,no));
          current:=yes;let v=ex a in store true(place_of_value result)v;terminate(Jump join);
          current:=no;let v=ex b in store true(place_of_value result)v;terminate(Jump join);
          current:=join;result
      |A.Match_control(name,scrutinee,arms)->
          let result=temp e.typ e.span in let outer= !current_scope in
          let scope=new_scope(Some outer)e.mode_set e.span in current_scope:=scope;
          let scr=ex scrutinee in let local=new_local ~temporary:false name scr.typ e.span in storage local;Hashtbl.add names name local;store true(place_of_value local)scr;
          let join=new_block outer and joins=ref false in
          List.iteri(fun i(_,condition,(body:A.block),tail)->
            let arm_scope=new_scope(Some scope)body.A.mode_set e.span in
            let arm=new_block arm_scope and next=new_block scope in
            if i=List.length arms-1 then terminate(Jump arm)else(let c=ex condition in terminate(Branch(c,arm,next)));
            current:=arm;current_scope:=arm_scope;statements body;
            if open_block()then begin let v=match tail with Some x->ex x|None->eval Unit e.span(Int_lit 0L)in
              if open_block()then begin joins:=true;
                store true(place_of_value result)v;exit_to arm_scope(Some outer);terminate(Jump join)end end;
            current:=next;current_scope:=scope)arms;
          terminate Stop;current:=join;current_scope:=outer;
          if not !joins then terminate Stop;result
      |A.Try(x,input,ok,err,out_layout,_out_ok,out_err)->
          let input_value=ex x in let p=place_of_value input_value in
          let tag=List.find(fun(f:struct_field)->f.name="__tag")input.fields in
          let tag=acquire e.span Copy(field p tag)in let zero=eval tag.typ e.span(Int_lit 0L)in
          let condition=eval Bool e.span(Binary("==",tag,zero))in
          let yes=new_block !current_scope and no=new_block !current_scope in terminate(Branch(condition,yes,no));
          current:=no;
          let error=acquire e.span Move(field p err)in
          let fields=List.map(fun(f:struct_field)->if f.name=out_err.name then f,error else if f.name="__tag"then f,eval f.typ e.span(Int_lit 1L)else f,default f.typ e.span)out_layout.fields in
          let result=eval(Named out_layout.name)e.span(Struct_lit(out_layout,fields))in List.iter(fun(_,v)->consume v)fields;
          exit_to ~except:result.id !current_scope None;terminate(Return(Some result));
          current:=yes;acquire e.span Move(field p ok)
      |A.Struct_lit(l,fs)->let fs=List.map(fun(f,x)->f,ex x)fs in let v=ev(Struct_lit(l,fs))in List.iter(fun(_,v)->consume v)fs;v
      |A.Vec_lit xs->let xs=List.map ex xs in let v=ev(Vec_lit xs)in List.iter consume xs;v
      |A.Call(n,xs)->
          let is_method=String.starts_with ~prefix:"__method$" n in
          let xs=List.mapi(fun i x->operand ~reserved:(is_method&&i=0) x)xs in
          let v=ev(Call(n,xs))in
          if List.exists(fun(f:A.func)->f.name=n)program.functions || n="$vec_into_string"then List.iter consume xs;
          if n="panic"then terminate Stop;v
      |A.Indirect_call(c,xs)->let c=ex c in let xs=List.map ex xs in let v=ev(Indirect_call(c,xs))in List.iter consume xs;v
      |A.Function_address n->ev(Function_address n)
      |A.Box_new x->let x=ex x in let v=ev(Box_new x)in consume x;v
      |A.Box_take x->let x=ex x in let v=ev(Box_take x)in consume x;v
      |A.Raw_alloc(t,x)->unary(fun x->Raw_alloc(t,x))x
      |A.Raw_free(t,x)->unary(fun x->Raw_free(t,x))x
      |A.Ptr_addr(t,x)->unary(fun x->Ptr_addr(t,x))x
      |A.Ptr_len x->unary(fun x->Ptr_len x)x
      |A.Raw_load(t,a,b)->binary(fun a b->Raw_load(t,a,b))a b
      |A.Raw_store(t,a,b,c)->let a=ex a in let b=ex b in let c=ex c in ev(Raw_store(t,a,b,c))
      |A.Syscall xs->ev(Syscall(List.map ex xs))
      |A.Index(a,b)->binary(fun a b->Index(a,b))a b
      |A.Vec_get(a,b)->binary(fun a b->Vec_get(a,b))a b
      |A.Slice_get(a,b)->binary(fun a b->Slice_get(a,b))a b
      |A.Slice_make(a,b,c)->let a=ex a in let b=ex b in let c=ex c in ev(Slice_make(a,b,c))
      |A.Slice_len x->unary(fun x->Slice_len x)x|A.Vec_len x->unary(fun x->Vec_len x)x
      |A.File_is_open x->unary(fun x->File_is_open x)x
      |A.File_read x->let x=operand ~reserved:true x in ev(File_read x)
      |A.File_close x->let x=operand ~reserved:true x in ev(File_close x)
      |A.File_write(a,b)->let a=operand ~reserved:true a in let b=ex b in ev(File_write(a,b))
      |A.Vec_pop a->let a=operand ~reserved:true a in ev(Vec_pop a)
      |A.Exchange(a,b)->let a=operand ~reserved:true a in let b=ex b in let v=ev(Exchange(a,b))in consume b;v
      |A.Vec_swap(a,b,c)->let a=operand ~reserved:true a in let b=ex b in let c=ex c in ev(Vec_swap(a,b,c))
      |A.Vec_replace(a,b,c)->let a=operand ~reserved:true a in let b=ex b in let c=ex c in let v=ev(Vec_replace(a,b,c))in consume c;v
      |A.Vec_push(a,b)->let a=operand ~reserved:true a in let b=ex b in let v=ev(Vec_push(a,b))in consume b;v
      |A.Vec_set(a,b,c)->let a=operand ~reserved:true a in let b=ex b in let c=ex c in let v=ev(Vec_set(a,b,c))in consume c;v
    and default typ span = match typ with
      |Box _->eval typ span(Int_lit 0L)
      |File->eval File span(Int_lit(-1L))|String->eval String span(String_lit "")
      |Vec _->eval typ span(Vec_lit [])|Ptr _|Slice _->eval typ span(Call("$inactive_pair",[]))
      |Named n->let l=layout n in let fs=List.map(fun(f:struct_field)->f,default f.typ span)l.fields in
          let v=eval typ span(Struct_lit(l,fs))in List.iter(fun(_,v)->consume v)fs;v
      |F32|F64->eval typ span(Float_lit 0.)|Bool->eval typ span(Bool_lit false)|_->eval typ span(Int_lit 0L)
    and statements (body:A.block) = List.iter(fun(s:A.stmt)->if open_block()then begin
      let before= !local_count in
      (match s.node with
       |A.Let(n,x)->let v=expression x in let target=new_local ~temporary:false n x.typ s.span in storage target;Hashtbl.add names n target;store true(place_of_value target)v
       |A.Let_pattern(x,bindings)->
          (* The owner is a full-expression temporary addressed only by Local ID.
             Remaining fields die below, after all bindings have been initialized. *)
          let owner=expression x in
          let bindings=List.map(fun(n,path,span)->
            let p=List.fold_left field (place_of_value owner)path in
            let kind=if linear [] p.typ then Move else if owned p.typ then Clone else Copy in
            let v=acquire span kind {p with span} in
            let target=new_local ~temporary:false n p.typ span in storage target;
            store true(place_of_value target)v;n,target)bindings in
          List.iter(fun(n,target)->Hashtbl.add names n target)bindings
       |A.Assign(n,x)->let v=expression x in store false(local_place n s.span)v
       |A.Field_assign(n,f,x)->let v=expression x in store false(field(local_place n s.span)f)v
       |A.Place_assign(target,x)->let p=place target in let v=expression x in store false p v
       |A.Ref_field_assign(r,f,x)->let p=place_or_value r in let typ=match p.typ with Ref(_,t)->t|_->assert false in let p={p with projections=p.projections@[Deref];typ}in
          let v=expression x in store false(field p f)v
       |A.Ref_set(r,x)->let p=place_or_value r in let typ=match p.typ with Ref(_,t)->t|_->assert false in let v=expression x in store false{p with projections=p.projections@[Deref];typ}v
       |A.Vec_set_stmt(a,b,c)->ignore(expression{A.node=A.Vec_set(a,b,c);typ=Unit;span=s.span;transfer=A.Direct;mode_set=body.mode_set})
       |A.Expr x->ignore(expression x)
       |A.Return x->let v=Option.map expression x in exit_to ?except:(Option.map(fun(v:value)->v.id)v) !current_scope None;terminate(Return v)
       |A.Break|A.Continue->let head,done_,outer=List.hd !loops in exit_to !current_scope(Some outer);terminate(Jump(if s.node=A.Break then done_ else head))
       |A.Block b|A.Scope b->let outer= !current_scope in let scope=new_scope(Some outer)b.mode_set s.span in current_scope:=scope;statements b;
          if open_block()then cleanup scope;current_scope:=outer
       |A.If(c,a,b)->let c=expression c in let outer= !current_scope in
          let sa=new_scope(Some outer)a.mode_set s.span and sb=new_scope(Some outer)b.mode_set s.span in
          let yes=new_block sa and no=new_block sb and join=new_block outer in terminate(Branch(c,yes,no));
          current:=yes;current_scope:=sa;statements a;if open_block()then(cleanup sa;terminate(Jump join));
          current:=no;current_scope:=sb;statements b;if open_block()then(cleanup sb;terminate(Jump join));
          current:=join;current_scope:=outer;if a.terminated&&b.terminated then terminate Stop
       |A.While(c,b)->let outer= !current_scope in let scope=new_scope(Some outer)b.mode_set s.span in
          let head=new_block outer and body_block=new_block scope and done_=new_block outer in terminate(Jump head);
          current:=head;let condition_start= !local_count in let c=expression c in
          List.iter(fun(l:local)->if l.id>=condition_start && l.id<>c.id && l.temporary then
            emit l.span(Storage_dead l.id))!locals;
          terminate(Branch(c,body_block,done_));
          current:=body_block;current_scope:=scope;loops:=(head,done_,outer)::!loops;statements b;
          if open_block()then(cleanup scope;terminate(Jump head));loops:=List.tl !loops;current:=done_;current_scope:=outer);
      (* End full-expression temporaries. Values staged before a later ? are
         still declared in the lexical scope and participate in early exits. *)
      if open_block()then List.iter(fun(l:local)->if l.id>=before && l.temporary && l.scope= !current_scope then emit l.span(Storage_dead l.id))!locals
    end)body.statements
    in
    statements fn.body;
    if open_block()then(exit_to !current_scope None;terminate(Return None));
    Hashtbl.iter(fun id(ops,term,scope)->blocks:={id;scope;operations=List.rev !ops;terminator=Option.value ~default:Stop !term}::!blocks)block_data;
    let sort get xs=Array.of_list(List.sort(fun a b->compare(get a)(get b))xs)in
    {id=fid;name=fn.name;mode_set=fn.mode_set;params;return_type=fn.return_type;
     locals=sort(fun(l:local)->l.id)!locals;
     scopes=sort(fun(s:scope)->s.id)(List.map(fun(s:scope)->{s with declarations=List.rev !(Hashtbl.find declarations s.id)})!scopes);
     blocks=sort(fun(b:block)->b.id)!blocks;entry=0;span=fn.span})program.functions in
  {layouts=program.layouts;enums=program.enums;functions;entry=program.entry}
