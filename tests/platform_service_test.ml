(* SPDX-License-Identifier: Apache-2.0 *)
open Semantic_ir
let expect yes message = if not yes then failwith message
let check source = Checker.check(Parser.parse ~file:"platform-contract.xen" source)
let rejected source message = match check source with
  |Error d->expect(String.includes ~affix:message d.message)d.message
  |Ok _->failwith("accepted invalid platform service: "^source)
let () =
  rejected "fn main(){platform_call(\"id\");}" "requires #![bb]";
  rejected "#global[bb]\nfn main(){platform_call(\"unknown\");}" "unknown platform service";
  rejected "#global[bb]\nfn main(){let name=\"id\";platform_call(name);}" "literal service name";
  rejected "#global[bb]\nfn main(){platform_call(\"read\",0,0);}" "expects 3";
  rejected "#global[bb]\nfn main(){platform_call(\"close\",1.0);}" "expected";
  let source="#global[bb]\nfn main(){let p=raw_alloc<Int>(1);raw_store(p,0,1);platform_call(\"read\",0,ptr_addr(p),8);println(raw_load(p,0));raw_free(p);platform_call(\"id\");}"in
  let checked=match check source with Ok p->p|Error d->failwith d.message in
  let calls program=List.concat_map(fun(f:func)->Array.to_list f.blocks|>List.concat_map(fun(b:block)->
      List.filter_map(fun op->match op.node with Eval(_,Platform_call(s,xs))->Some(s,xs)|_->None)b.operations))program.functions in
  List.iter(fun level->let p=program(Semantic_opt.apply level checked)in
    verify p;
    let services=calls p in expect(List.length services=2)"service effects were eliminated";
    List.iter(fun(s,xs)->expect(List.length xs=Platform_service.arity s)"operand arity lost")services;
    let broken={p with functions=List.map(fun(f:func)->{f with blocks=Array.map(fun(b:block)->
      {b with operations=List.map(fun op->match op.node with
        |Eval(v,Platform_call(Platform_service.Read,xs))->{op with node=Eval(v,Platform_call(Platform_service.Close,xs))}
        |_->op)b.operations})f.blocks})p.functions}in
    (try verify broken;failwith "IR verifier accepted service arity corruption" with Invalid _->()))
    [Semantic_opt.Off;Semantic_opt.Basic];
  print_endline "Finite platform service checking, operands and effect boundaries passed"
