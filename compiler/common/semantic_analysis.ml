(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
open Semantic_ir
module I = Set.Make(Int)
(* A loan's birth survives reference copies. A new loan produced by a callee
   also has the caller's creation site; recursive summaries never grow an
   unbounded call string. *)
type loan_id = int * int * int * int
module K = Set.Make(struct type t=loan_id let compare=compare end)
module P = Map.Make(struct type t=int*string list let compare=compare end)
module PS = Set.Make(struct type t=int*string list let compare=compare end)

type origin = Owner of (int*string list) | Incoming of int*string list
type loan = { identity : loan_id; origin : origin; mutable_ : bool; reserved : bool; ancestors : K.t }
module L = Set.Make(struct
  type t=loan
  let compare a b =
    let c=compare (a.identity,a.origin,a.mutable_,a.reserved)
      (b.identity,b.origin,b.mutable_,b.reserved) in
    if c<>0 then c else K.compare a.ancestors b.ancestors
end)
type cell = { initialized : bool; loans : L.t; moved_at : span option }
type state = { cells : cell P.t; storage : I.t; written : PS.t; touched : PS.t; required : PS.t }
type call_effect = { parameter : int; path : string list; loans : L.t;
                     initialized : bool; definite : bool }
type summary = { effects : call_effect list; reads : (int * string list) list;
                 moves : (int * string list) list;
                 result : (string list * L.t) list }
exception Diagnostic of span * string * (span * string) list
let absent={initialized=false;loans=L.empty;moved_at=None}
let empty={cells=P.empty;storage=I.empty;written=PS.empty;touched=PS.empty;required=PS.empty}
let blank_summary={effects=[];reads=[];moves=[];result=[]}
(* Box contents cannot contain views, and are initialized with their owner.
   Materialize only paths actually accessed, so recursive types stay finite. *)
let rec get state ((root,path) as key)=match P.find_opt key state.cells with
  |Some cell->cell
  |None->let rec owner before=function
      |("$box"|"[]")::_->let cell=get state(root,List.rev before)in {cell with loans=L.empty}
      |x::xs->owner(x::before)xs|[]->absent in owner [] path
let prefix a b = let rec loop a b=match a,b with [],_->true|x::xs,y::ys when x=y||x="[]"||y="[]"->loop xs ys|_->false in loop a b
let overlaps (a,xs)(b,ys)=a=b&&(prefix xs ys||prefix ys xs)
let union_cell (a:cell) (b:cell)={initialized=a.initialized&&b.initialized;loans=L.union a.loans b.loans;
  moved_at=(if a.moved_at=b.moved_at then a.moved_at else None)}
let merge a b={cells=P.merge(fun key x y->Some(union_cell(Option.value ~default:(get a key)x)(Option.value ~default:(get b key)y)))a.cells b.cells;
  written=PS.inter a.written b.written;touched=PS.union a.touched b.touched;
  required=PS.union a.required b.required;storage=I.inter a.storage b.storage}
let cell_equal (a:cell) (b:cell)=a.initialized=b.initialized && a.moved_at=b.moved_at && L.equal a.loans b.loans
let state_equal a b=P.equal cell_equal a.cells b.cells&&PS.equal a.written b.written&&PS.equal a.touched b.touched&&PS.equal a.required b.required&&I.equal a.storage b.storage
let summary_equal a b=
  a.reads=b.reads && a.moves=b.moves && List.length a.effects=List.length b.effects &&
  List.for_all2(fun a b->a.parameter=b.parameter && a.path=b.path &&
    a.initialized=b.initialized && a.definite=b.definite && L.equal a.loans b.loans)a.effects b.effects &&
  List.length a.result=List.length b.result &&
  List.for_all2(fun(p,a)(q,b)->p=q && L.equal a b)a.result b.result

(* A reference cell can hold mutually exclusive sibling loans after a join.
   Access through that value authorizes compatible alternatives, but never a
   parent/child pair: a live child elsewhere must still block the parent path. *)
let authority alternatives loan =
  L.fold(fun other auth->
    if other.mutable_=loan.mutable_ && other.reserved=loan.reserved &&
       K.equal other.ancestors loan.ancestors then
      K.union auth(K.add other.identity other.ancestors)
    else auth)alternatives(K.add loan.identity loan.ancestors)

(* Cleanup does not count as a semantic use of a reference. Otherwise a loan
   would be extended by destructor bookkeeping after its last actual use. *)
let flow_paths leaves (f:func) =
  let expand root path typ=List.map(fun(path,_)->root,path)(leaves path typ)in
  let value (v:value)=expand v.id [] v.typ in
  let rec place_path root path typ = function
    |[]->expand root path typ
    |Field field::rest->place_path root(path@[field.name])field.typ rest
    |Deref::_->expand root path typ
    |Element _::_->expand root path typ in
  let place p=place_path p.root [] f.locals.(p.root).typ p.projections @
    List.concat_map(function Element v->value v|_->[])p.projections in
  let static p=List.fold_left(fun result->function Field f->Option.map(fun path->path@[f.name])result|_->None)(Some[])p.projections in
  let use op=match op.node with
    |Acquire(_,_,p)|Borrow(_,_,_,p)->place p
    |Initialize(p,v)|Replace(p,v)->value v @ (if List.exists(function Deref|Element _->true|_->false)p.projections then place p else [])
    |Eval(_,r)->List.concat_map value(rvalue_uses r)
    |Storage_live _|Storage_dead _|Drop _|Forget _|Drop_flag _|Logical_call_enter _|Logical_call_exit _->[]in
  let kill op live =
    let definitions=match op.node with
      |Acquire(v,_,_)|Borrow(v,_,_,_)|Eval(v,_)->[v.id,[]]
      |Storage_live id|Storage_dead id->[id,[]]
      |Initialize(p,_)|Replace(p,_)->(match static p with Some path->[p.root,path]|None->[])
      |_->[]in
    PS.filter(fun(root,path)->not(List.exists(fun(r,p)->r=root&&prefix p path)definitions))live in
  let terminal = function Branch(v,_,_)|Return(Some v)->value v|_->[]in
  use,kill,terminal

let liveness leaves (f:func) =
  let use,kill,terminal=flow_paths leaves f in
  let add live keys=List.fold_left(fun live key->PS.add key live)live keys in
  let n=Array.length f.blocks in let inputs=Array.make n PS.empty and outputs=Array.make n PS.empty in
  let transfer b out=List.fold_right(fun op live->
    add(kill op live)(use op))b.operations(add out(terminal b.terminator))in
  let changed=ref true in while !changed do changed:=false;
    for id=n-1 downto 0 do let b=f.blocks.(id)in
      let out=List.fold_left(fun live id->PS.union live inputs.(id))PS.empty(successors b.terminator)in
      let input=transfer b out in
      if not(PS.equal input inputs.(id))||not(PS.equal out outputs.(id))then(changed:=true;inputs.(id)<-input;outputs.(id)<-out)
    done
  done;
  Array.map(fun(b:block)->
    let live=ref(add outputs.(b.id)(terminal b.terminator))in
    let points=List.rev_map(fun op->let after= !live in
      live:=add(kill op !live)(use op);(!live,after))(List.rev b.operations)in
    points)f.blocks

let analyze_program ~elaborate (program:program) =
  verify program;
  let layout n=List.find(fun(l:struct_layout)->l.name=n)program.layouts in
  let rec leaves path typ = match typ with Named n->List.concat_map(fun(f:struct_field)->leaves(path@[f.name])f.typ)(layout n).fields|_->[path,typ]in
  let borrowed = function Ref _|Slice _->true|_->false in
  let resource = function String|Vec _|File|Box _->true|_->false in
  let all_loans state id = P.fold(fun(root,_)(c:cell) loans->if root=id then L.union c.loans loans else loans)state.cells L.empty in
  let summaries=Hashtbl.create 32 in List.iter(fun(f:func)->Hashtbl.add summaries f.name blank_summary)program.functions;
  let lives=List.map(fun(f:func)->f.id,liveness leaves f)program.functions in
  let analyze validate (f:func) =
    let identity id=(f.id,id,-1,-1) in
    let validating=ref false in
    let point=ref(f.entry,0)in
    let drop_updates=Hashtbl.create 16 in
    let live_points=List.assoc f.id lives in
    let parameter_id i=List.nth f.params i in
    let typ_at id path =
      let start=if id<0 then match f.locals.(parameter_id(-id-1)).typ with Ref(_,t)->t|_->assert false else f.locals.(id).typ in
      List.fold_left(fun typ field->if field="$view"then typ else if field="$box"then(match typ with Box t->t|_->typ)else if field="[]"then(match typ with Vec t|Slice t->t|_->typ)
        else match typ with Named n->(List.find(fun(f:struct_field)->f.name=field)(layout n).fields).typ|_->typ)start path in
    let keys (root,path) typ=List.map(fun(path,t)->(root,path),t)(leaves path typ)in
    let write state (root,path) typ values ~definite ~moved_at =
      let base=if definite then P.filter(fun(r,p)_->not(r=root && prefix path p && p<>path))state.cells else state.cells in
      let cells=List.fold_left(fun cells ((root,full),_)->
        let relative=List.filteri(fun i _->i>=List.length path)full in
        let loans=Option.value ~default:L.empty(List.assoc_opt relative values)in
        let previous=get state(root,full)in
        let initialized=(moved_at=None) && (definite || previous.initialized) in
        let moved_at=if not definite && not previous.initialized && moved_at=None then previous.moved_at else moved_at in
        P.add(root,full){initialized;loans=(if definite then loans else L.union previous.loans loans);moved_at}cells)base(keys(root,path)typ)in
      {state with cells}in
    let read state (root,path) typ=List.map(fun((_,full),_)->
      List.filteri(fun i _->i>=List.length path)full,(get state(root,full)).loans)(keys(root,path)typ)in
    let initial = List.fold_left(fun state id->let l=f.locals.(id)in let i=Option.get l.parameter in
      let values=List.map(fun(path,t)->path,(if borrowed t then L.singleton{identity=identity(-(id+1));origin=(match t with Ref _->Owner(-i-1,[])|_->Incoming(i,path));mutable_=(match t with Ref(m,_)->m|_->false);reserved=false;ancestors=K.empty}else L.empty))(leaves[]l.typ)in
      let state=write {state with storage=I.add id state.storage}(id,[])l.typ values ~definite:true ~moved_at:None in
      match l.typ with Ref(_,t)->let values=List.map(fun(path,t)->path,(if borrowed t then L.singleton{identity=identity(-(id+1));origin=Incoming(i,"$deref"::path);mutable_=(match t with Ref(m,_)->m|_->false);reserved=false;ancestors=K.empty}else L.empty))(leaves[]t)in
        write state(-i-1,[])t values ~definite:true ~moved_at:None
      |_->state)empty f.params in
    let active state live =
      let direct=P.fold(fun(root,path)(cell:cell)out->
        if PS.exists(fun(r,p)->r=root&&(prefix p path||path=["$view"]))live then L.union out cell.loans else out)state.cells L.empty in
      (* A live reference also keeps the views stored behind it valid. Direct
         aggregate field uses remain separate; dereferenced storage is followed
         conservatively until the reference's last use. *)
      let rec follow loans=let next=L.fold(fun loan out->match loan.origin with Owner(root,path)->
          P.fold(fun(r,p)(cell:cell)out->if r=root&&prefix path p then L.union out cell.loans else out)state.cells out
          |_->out)loans loans in
        if L.equal loans next then loans else follow next in
      follow direct in
    let display_name (owner:func) (root,path)=
      let id=if root<0 then let position= -root-1 in
          if position<0 then None else List.nth_opt owner.params position
        else Some root in
      let name=match id with Some id when id>=0 && id<Array.length owner.locals->
      let local=owner.locals.(id)in
      let n=if local.temporary then "temporary value" else local.name in
      (match String.index_opt n '$'with Some i->String.sub n 0 i|None->n)
      |_->if root<0 then "parameter" else "borrowed value"in
      List.fold_left(fun name p->if p="$box"then "(*"^name^")"else name^"."^p)name path in
    let name key=display_name f key in
    let owner_context loan =
      let birth,_,caller,_=loan.identity in
      List.find_opt(fun(f:func)->f.id=(if caller>=0 then caller else birth))program.functions in
    let scope_note loan = match loan.origin,owner_context loan with
      |Owner(root,_),Some owner when root>=0 && root<Array.length owner.locals->
          [owner.scopes.(owner.locals.(root).scope).span,"owner's scope begins here"]
      |_->[]in
    let origin_note loan =
      let fn,id,caller,call=loan.identity in
      let site fn id=match List.find_opt(fun(f:func)->f.id=fn)program.functions with
        |Some owner->let index=if id<0 then -id-1 else id in
            if index>=0 && index<Array.length owner.locals then Some owner.locals.(index).span else None
        |None->None in
      let notes=match site fn id with None->[]|Some span->
        let owner=match loan.origin,owner_context loan with
          |Owner key,Some owner->" of '"^display_name owner key^"'"|_->""in
        [span,(if id<0 then "borrow received through this parameter" else
          (if loan.mutable_ then "mutable" else "shared")^" borrow"^owner^" originates here")]in
      if caller<0 then notes else match site caller call with None->notes|Some span->
        notes@[span,"borrow forwarded by this call"]in
    let later_use state live loan =
      let holders=P.fold(fun key(cell:cell)out->
        if PS.mem key live && L.exists(fun other->other.identity=loan.identity)cell.loans
        then PS.add key out else out)state.cells PS.empty in
      let use,kill,terminal=flow_paths leaves f in
      let relevant keys uses=List.exists(fun key->PS.exists(overlaps key)keys)uses in
      let queue=Queue.create()and visited=Hashtbl.create 16 in
      let block,index= !point in Queue.add(block,index+1,holders)queue;
      let result=ref None and budget=ref 256 in
      while !result=None && not(Queue.is_empty queue) && !budget>0 do
        decr budget;
        let block,index,keys=Queue.take queue in
        let marker=block,index,PS.elements keys in
        if not(PS.is_empty keys) && not(Hashtbl.mem visited marker)then begin
          Hashtbl.add visited marker();let b=f.blocks.(block)in
          let operations=List.mapi(fun i op->i,op)b.operations in
          let keys=List.fold_left(fun keys(i,(op:operation))->
            if i<index || !result<>None then keys else begin
              if relevant keys(use op)then result:=Some op.span;
              kill op keys
            end)keys operations in
          if !result=None then begin
            if relevant keys(terminal b.terminator)then
              result:=(match b.terminator with Return(Some v)|Branch(v,_,_)->Some v.span|_->None);
            List.iter(fun target->Queue.add(target,0,keys)queue)(successors b.terminator)
          end
        end
      done;
      !result in
    let loan_notes span state live loan =
      let notes=origin_note loan in
      let notes=match later_use state live loan with Some use when use<>span->
        notes@[use,"borrow may remain live through this use"]|_->notes in
      List.sort_uniq compare notes in
    let ensure_storage span state root = if !validating && root>=0 && not(I.mem root state.storage)then
      raise(Diagnostic(span,"use of dead storage '"^name(root,[])^"'",[]))in
    let ensure_initialized span state key typ =
      ensure_storage span state(fst key);
      if !validating then
      let expanded=keys key typ in
      let whole=List.for_all(fun(k,_)->not(get state k).initialized)expanded in
      List.iter(fun(k,t)->let c=get state k in if not c.initialized then
        let notes=match c.moved_at with Some s->[s,"value moved here"]|None->[]in
        let failing,typ=if whole then key,typ else k,t in
        let partial=if not whole && k<>key then " (partial move of '"^name key^"')" else ""in
        raise(Diagnostic(span,"use of moved "^string_of_typ typ^" '"^name failing^"'"^partial^" (or uninitialized value)",notes)))expanded in
    let resolve state (p:place) =
      ensure_storage p.span state p.root;
      List.fold_left(fun paths->function
        |Field field->List.map(fun((root,path),auth)->(root,path@[field.name]),auth)paths
        |Element index->ensure_initialized index.span state(index.id,[])index.typ;
            List.map(fun((root,path),auth)->(root,path@["[]"]),auth)paths
        |Deref->List.concat_map(fun(key,auth)->
            (* An empty provenance set must not hide an uninitialized pointer
               read by making the list of accessed referents empty. *)
            ensure_initialized p.span state key(typ_at(fst key)(snd key));
            match typ_at(fst key)(snd key)with
            |Box _->[( (fst key,snd key@["$box"]),auth)]
            |_->let alternatives=(get state key).loans in
            L.elements alternatives|>List.filter_map(fun l->match l.origin with
              Owner p->Some(p,K.union auth(authority alternatives l))|Incoming _->None))paths)
        [((p.root,[]),K.empty)]p.projections in
    let access span state live key auth kind = if !validating then
      L.iter(fun loan->match loan.origin with
        |Owner owner when overlaps key owner && K.mem loan.identity auth &&
            not loan.mutable_ && kind<>`Read->
            raise(Diagnostic(span,"cannot move or mutate through a shared reference",loan_notes span state live loan))
        |Owner owner when overlaps key owner && not(K.mem loan.identity auth)->
          let conflict=match kind with `Read->loan.mutable_ && not loan.reserved|`Write|`Move->true in
          if conflict then let verb=match kind with `Read->"access"|`Write->"mutate"|`Move->"move"in
            let message=if kind=`Move&&loan.reserved then "cannot move a value while mutating one of its Vec fields"else
              "cannot "^verb^" '"^name key^"' while it is borrowed"in
            raise(Diagnostic(span,message,loan_notes span state live loan))
        |_->())(active state live)in
    (* Summaries stop at owning indirection. Contents have no borrowed views,
       and moving them through a borrow is forbidden; an access conservatively
       concerns the owning cell. Recursive traversal cannot grow path strings. *)
    let summary_target (root,path) typ =
      let rec before acc=function
        |("$box"|"[]")::_->let path=List.rev acc in (root,path),typ_at root path
        |x::xs->before(x::acc)xs|[]->(root,path),typ in before [] path in
    let record ?(definite=true) state key typ =
      let key,typ=summary_target key typ in if fst key<0 then
      List.fold_left(fun state(k,_)->{state with touched=PS.add k state.touched;
        written=(if definite then PS.add k state.written else state.written)})state(keys key typ)
      else state in
    let record_read state key typ =
      let key,typ=summary_target key typ in if fst key<0 then
      List.fold_left(fun state(k,_)->if PS.mem k state.written then state else
        {state with required=PS.add k state.required})state(keys key typ)
      else state in
    let moved_paths=ref PS.empty in
    let record_move key typ =
      let key,typ=summary_target key typ in
      if fst key<0 then List.iter(fun(k,_)->moved_paths:=PS.add k !moved_paths)(keys key typ) in
    let check_escape span values = if !validating then List.iter(fun(_,loans)->L.iter(fun loan->match loan.origin with
      |Owner(root,_) when root>=0->raise(Diagnostic(span,"borrowed value escapes its owner scope (callee-owned origin)",
          origin_note loan @ scope_note loan))|_->())loans)values in
    let resolve_argument state (v:value) path =
      if path<>[]&&List.hd path="$deref"then
        let rest=List.tl path in L.elements(get state(v.id,[])).loans|>List.filter_map(fun l->match l.origin with Owner(root,p)->Some(root,p@rest)|_->None)
      else [v.id,path] in
    let instantiate_loan callsite state args loan = match loan.origin with
      |Incoming(i,path)->if i>=List.length args then L.empty else
          List.fold_left(fun loans key->L.union loans(get state key).loans)L.empty(resolve_argument state(List.nth args i)path)
      |Owner(root,path)when root<0->let i= -root-1 in if i>=List.length args then L.empty else
          L.fold(fun input out->match input.origin with Owner(root,p)->
            let born_fn,born_id,_,_=loan.identity in
            let identity,ancestors=if born_id<0 then input.identity,input.ancestors
              else (born_fn,born_id,f.id,callsite),K.add input.identity input.ancestors in
            L.add{loan with identity;ancestors;reserved=false;origin=Owner(root,p@path)}out
            |Incoming _->L.add input out)(get state((List.nth args i).id,[])).loans L.empty
      |_->L.singleton loan in
    let instantiate callsite state args values = List.map(fun(path,loans)->path,L.fold(fun loan out->L.union out(instantiate_loan callsite state args loan))loans L.empty)values in
    let targets = function
      |Call(n,_)->(match List.find_opt(fun(f:func)->f.name=n)program.functions with Some f->[f]|None->[])
      |Indirect_call(c,_)->(match c.typ with Function(ps,r)->List.filter(fun(fn:func)->fn.return_type=r&&List.map(fun id->fn.locals.(id).typ)fn.params=ps)program.functions|_->[])
      |_->[]in
    let apply_call callsite span state live r =
      let call_input=state in
      let args=match r with Call(_,args)|Indirect_call(_,args)->args|_->[]in
      let fs=targets r in
      (* Distinct mutable parameters are analyzed as distinct memory roots.
         Reference copies keep their loan identity, but must not turn one loan
         into aliased parameter roots at a call boundary. *)
      if !validating then List.iteri(fun i (a:value)->
        List.iteri(fun j (b:value)->if j>i then match a.typ,b.typ with
          |Ref(ma,_),Ref(mb,_) when ma||mb->
              L.iter(fun x->L.iter(fun y->match x.origin,y.origin with
                |Owner p,Owner q when overlaps p q->raise(Diagnostic(span,"conflicting mutable borrow arguments",
                    List.sort_uniq compare(loan_notes span state live x @ loan_notes span state live y)))
                |_->())(get call_input(b.id,[])).loans)(get call_input(a.id,[])).loans
          |_->())args)args;
      let results=List.map(fun(fn:func)->
        let summary=Hashtbl.find summaries fn.name in
        List.iter(fun(i,path)->let argument=List.nth args i in
          L.iter(fun loan->match loan.origin with
            |Owner(root,p)->let key=root,p@path in
                if !validating && List.mem "$box"(snd key)then
                  raise(Diagnostic(span,"cannot move out of borrowed Box contents; use into_inner",[]));
                record_move key (typ_at root (p@path))
            |_->())(get call_input(argument.id,[])).loans)summary.moves;
        let state=List.fold_left(fun state(i,path)->
          let argument=List.nth args i in
          L.fold(fun loan state->match loan.origin with Owner(root,p)->
            let key=root,p@path in let typ=typ_at root (p@path)in
            ensure_initialized span call_input key typ;
            access span call_input live key(authority (get call_input(argument.id,[])).loans loan)`Read;
            record_read state key typ
            |_->state)(get call_input(argument.id,[])).loans state)state summary.reads in
        let state=List.fold_left(fun state change->
          let argument=List.nth args change.parameter in
          let loans=(get call_input(argument.id,[])).loans in
          let destinations=L.elements loans|>List.filter_map(fun loan->match loan.origin with Owner(root,path)->Some((root,path@change.path),authority loans loan)|_->None)in
          let distinct=List.fold_left(fun keys(key,_)->PS.add key keys)PS.empty destinations in
          List.fold_left(fun state(key,auth)->
            access span state live key auth `Write;
            let typ=typ_at(fst key)(snd key)in
            if !validating && not change.initialized && List.mem "$box" (snd key)then
              raise(Diagnostic(span,"cannot move out of borrowed Box contents; use into_inner",[]));
            if !validating && fst key>=0 && resource typ then begin
              let previous=Option.value ~default:PS.empty(Hashtbl.find_opt drop_updates callsite)in
              Hashtbl.replace drop_updates callsite(PS.add key previous)
            end;
            let values=instantiate callsite call_input args [[],change.loans]in
            if fst key<0 then check_escape span values;
            let strong=change.definite&&PS.cardinal distinct=1 in
            let state=write state key typ values ~definite:strong
              ~moved_at:(if change.initialized then None else Some span) in
            let key,_=summary_target key typ in
            let touched=PS.add key state.touched in let written=if strong then PS.add key state.written else state.written in
            {state with touched;written})state destinations)state summary.effects in
        state,instantiate callsite call_input args summary.result)fs in
      match results with []->state,[]|(state,result)::rest->List.fold_left(fun(state,result)(s,r)->merge state s,
        List.map(fun(path,loans)->path,L.union loans(Option.value ~default:L.empty(List.assoc_opt path r)))result)(state,result)rest in
    let step span scope state live node =
      let check_values values=if !validating then List.iter(fun(v:value)->ensure_initialized span state(v.id,[])v.typ;
        L.iter(fun loan->match loan.origin with Owner(root,_)when root>=0 && not(I.mem root state.storage)->
          raise(Diagnostic(span,"borrowed value escapes its owner scope",origin_note loan @
            scope_note loan))|_->())(all_loans state v.id))values in
      let state=match node with
      |Storage_live id->let state={state with storage=I.add id state.storage;
          cells=P.filter(fun(root,_)_->root<>id)state.cells}in
          {state with cells=List.fold_left(fun cells(key,_)->P.add key absent cells)state.cells(keys(id,[])f.locals.(id).typ)}
      |Storage_dead id->
          if !validating then L.iter(fun loan->match loan.origin with Owner(root,_)when root=id->raise(Diagnostic(span,"borrowed value escapes its owner scope",
            loan_notes span state live loan @ scope_note loan))|_->())(active state(PS.filter(fun(root,_)->root<>id)live));
          write {state with storage=I.remove id state.storage;
            cells=P.filter(fun(root,_)_->root<>id)state.cells}(id,[])f.locals.(id).typ [] ~definite:true ~moved_at:(Some span)
      |Acquire(v,kind,p)->
          ensure_storage span state v.id;
          let paths=resolve state p in
          let values=List.fold_left(fun values(key,auth)->
            if !validating && kind=Move && List.mem "$box"(snd key)then
              raise(Diagnostic(span,"cannot move out of borrowed Box contents; use into_inner",[]));
            ensure_initialized span state key p.typ;access span state live key auth(if kind=Move then `Move else `Read);
            let read=read state key p.typ in
            List.map(fun(path,loans)->path,L.union loans(Option.value ~default:L.empty(List.assoc_opt path values)))read)[]paths in
          let values=if kind=Read && (match p.typ with String|Vec _|Named _|Box _->true|_->false)then
            ("$view"::[],List.fold_left(fun out(key,auth)->L.add{identity=identity v.id;origin=Owner key;mutable_=false;reserved=false;ancestors=auth}out)L.empty paths)::values else values in
          let state=write state(v.id,[])v.typ values ~definite:true ~moved_at:None in
          let state=match List.assoc_opt["$view"]values with Some loans->{state with cells=P.add(v.id,["$view"]){initialized=true;loans;moved_at=None}state.cells}|None->state in
          let state=List.fold_left(fun state(key,_)->record_read state key p.typ)state paths in
          if kind=Move then begin List.iter(fun(key,_)->record_move key p.typ)paths;
            List.fold_left(fun state(key,_)->record
            (write state key p.typ [] ~definite:true ~moved_at:(Some span))key p.typ)state paths end else state
      |Borrow(v,mut,reserved,p)->
          ensure_storage span state v.id;
          let paths=resolve state p in
          List.iter(fun(key,auth)->
            if not(reserved && (match p.typ with Named _->true|_->false))then ensure_initialized span state key p.typ;
            if not reserved then (try access span state live key auth(if mut then `Write else `Read) with Diagnostic(s,m,n)->raise(Diagnostic(s,"conflicting borrow: "^m,n)))
            else if !validating then L.iter(fun loan->match loan.origin with Owner owner when overlaps key owner&&loan.mutable_&&not(K.mem loan.identity auth)->raise(Diagnostic(span,"conflicting borrow of '"^name key^"' while it is borrowed",loan_notes span state live loan))|_->())(active state live))paths;
          let loans=List.fold_left(fun loans(key,auth)->L.add{identity=identity v.id;origin=Owner key;mutable_=mut;reserved;ancestors=auth}loans)L.empty paths in
          let state=if reserved && (match p.typ with Named _->true|_->false)then state
            else List.fold_left(fun state(key,_)->record_read state key p.typ)state paths in
          write state(v.id,[])v.typ [[],loans] ~definite:true ~moved_at:None
      |Initialize(p,v)|Replace(p,v)->
          check_values[v];let values=read state(v.id,[])v.typ in
          let destinations=resolve state p in
          let distinct=List.fold_left(fun keys(key,_)->PS.add key keys)PS.empty destinations in
          let definite=PS.cardinal distinct=1 in
          List.fold_left(fun state(key,auth)->access span state live key auth `Write;
            if fst key<0 then check_escape span values;
            record ~definite (write state key p.typ values ~definite ~moved_at:None)key p.typ)state destinations
      |Forget p->List.fold_left(fun state(key,_)->write state key p.typ [] ~definite:true ~moved_at:(Some span))state(resolve state p)
      |Drop _|Drop_flag _|Logical_call_enter _|Logical_call_exit _->state
      |Eval(v,r)->
          ensure_storage span state v.id;
          check_values(rvalue_uses r);
          let state,values=apply_call v.id span state live r in
          let state=match r with Vec_push(t,_)|Vec_set(t,_,_)|Vec_replace(t,_,_)|Vec_pop t|Vec_swap(t,_,_)|File_read t|File_write(t,_)|File_close t->
            L.fold(fun loan state->match loan.origin with Owner key->
              ensure_initialized span state key(typ_at(fst key)(snd key));
              access span state live key(authority (get state(t.id,[])).loans loan)`Write;
              let state=record_read state key(typ_at(fst key)(snd key))in
              record state key(typ_at(fst key)(snd key))
              |_->state)(get state(t.id,[])).loans state
            |_->state in
          let state,values=match r with
            |Exchange(t,x)->
                let typ=x.typ and alternatives=(get state(t.id,[])).loans in
                let values=read state(x.id,[])x.typ in
                let destinations=L.elements alternatives|>List.filter_map(fun loan->match loan.origin with Owner key->Some(key,authority alternatives loan)|_->None)in
                let old=List.fold_left(fun out(key,_)->
                  List.fold_left(fun out(path,loans)->(path,L.union loans(Option.value ~default:L.empty(List.assoc_opt path out)))::List.remove_assoc path out)out(read state key typ))[]destinations in
                let state=List.fold_left(fun state(key,auth)->
                  ensure_initialized span state key typ;access span state live key auth `Write;
                  if fst key<0 then check_escape span values;
                  let state=record_read state key typ in
                  record state key typ |> fun state->write state key typ values ~definite:(List.length destinations=1) ~moved_at:None)state destinations in
                state,old
            |_->state,values in
          let values=match r with
            |Struct_lit(_,fields)->List.concat_map(fun((field:struct_field),(v:value))->List.map(fun(path,loans)->field.name::path,loans)(read state(v.id,[])v.typ))fields
            |Slice_make(receiver,_,_)->let loans=L.union(get state(receiver.id,["$view"])).loans(all_loans state receiver.id)in
                [[],L.map(fun l->{l with identity=identity v.id;mutable_=false;reserved=false;ancestors=K.add l.identity l.ancestors})loans]
            |_->values in
          write state(v.id,[])v.typ values ~definite:true ~moved_at:None in
      ignore scope;state in
    let inputs=Array.make(Array.length f.blocks)None in inputs.(f.entry)<-Some initial;
    let changed=ref true in while !changed do changed:=false;
      Array.iter(fun(b:block)->match inputs.(b.id)with None->()|Some input->
        let out=List.fold_left2(fun state (op:operation)(live,_)->step op.span op.scope state live op.node)input b.operations live_points.(b.id)in
        List.iter(fun target->let next=match inputs.(target)with None->out|Some old->merge old out in
          if Option.fold ~none:true ~some:(fun old->not(state_equal old next))inputs.(target)then(inputs.(target)<-Some next;changed:=true))(successors b.terminator))f.blocks
    done;
    validating:=validate;
    let returns=ref [] in
    Array.iter(fun(b:block)->match inputs.(b.id)with None->()|Some input->
      let state=List.fold_left2(fun state (index,(op:operation))(live,_)->point:=b.id,index;step op.span op.scope state live op.node)
        input(List.mapi(fun i op->i,op)b.operations)live_points.(b.id)in
      point:=b.id,List.length b.operations;
      match b.terminator with Return value->
        let result=match value with None->[]|Some v->ensure_initialized v.span state(v.id,[])v.typ;let values=read state(v.id,[])v.typ in check_escape v.span values;values in
        returns:=(state,result)::!returns
      |Branch(v,_,_)->ensure_initialized v.span state(v.id,[])v.typ|_->())f.blocks;
    let summary=match !returns with []->blank_summary|(state,result)::rest->
      let merged=List.fold_left(fun s(state,_)->merge s state)state rest in
      let result=List.map(fun(path,loans)->path,List.fold_left(fun loans(_,r)->L.union loans(Option.value ~default:L.empty(List.assoc_opt path r)))loans rest)result in
      let effects=PS.elements merged.touched|>List.filter_map(fun(root,path)->if root>=0 then None else
        Some{parameter= -root-1;path;loans=(get merged(root,path)).loans;
             initialized=(get merged(root,path)).initialized;definite=PS.mem(root,path)merged.written})in
      let reads=PS.elements merged.required|>List.filter_map(fun(root,path)->if root<0 then Some(-root-1,path)else None)in
      {effects;reads;moves=[];result}in
    let moves=PS.elements !moved_paths|>List.map(fun(root,path)-> -root-1,path)in
    {summary with moves},inputs,drop_updates in
  let converge()=
    let changed=ref true in while !changed do changed:=false;
      List.iter(fun(f:func)->let summary,_,_=analyze false f in let old=Hashtbl.find summaries f.name in
        if not(summary_equal old summary)then(Hashtbl.replace summaries f.name summary;changed:=true))program.functions
    done in
  (* First discover possible effects. Then solve must-overwrite and must-init
     from the top of those known paths, with provenance starting at the bottom.
     This proves overwrites on all normal returns through recursive cycles. *)
  converge();
  Hashtbl.filter_map_inplace(fun _ summary->Some{summary with effects=List.map(fun change->
    {change with definite=true;initialized=true;loans=L.empty})summary.effects})summaries;
  converge();
  let functions=List.map(fun(f:func)->
    let _,_,drop_updates=analyze true f in
    if not elaborate then f else
    let update_place(root,path)=
      let l=f.locals.(root)in
      List.fold_left(fun (p:place) name->match p.typ,name with
        |Box t,"$box"->{p with projections=p.projections@[Deref];typ=t}
        |Named n,_->
        let field=List.find(fun(f:struct_field)->f.name=name)(layout n).fields in
        {p with projections=p.projections@[Field field];typ=field.typ}
        |_->raise(Invalid(l.span,"invalid summary drop path")))
        {root;projections=[];typ=l.typ;span=l.span}path in
    let blocks=Array.map(fun(b:block)->let operations=List.concat_map(fun (op:operation)->match op.node with
      |Storage_dead id->let l=f.locals.(id)in if l.owned then [{op with node=Drop(place_of_value(value_of_local l))};op]else[op]
      |Replace(p,v)->[{op with node=Drop p};{op with node=Initialize(p,v)}]
      |Eval(v,_)->op::List.map(fun key->{op with node=Drop_flag(update_place key,true)})
          (PS.elements(Option.value ~default:PS.empty(Hashtbl.find_opt drop_updates v.id)))
      |_->[op])b.operations in {b with operations})f.blocks in {f with blocks})program.functions in
  checked{program with functions}

(* Checked input already contains cleanup. Revalidation never elaborates it again. *)
let check program = analyze_program ~elaborate:true program
let revalidate program = analyze_program ~elaborate:false program
