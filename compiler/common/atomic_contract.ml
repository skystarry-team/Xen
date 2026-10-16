(* SPDX-License-Identifier: Apache-2.0 *)
open Ast
let kinds=["atomic_load",Atomic_load;"atomic_store",Atomic_store;
  "atomic_exchange",Atomic_exchange;"atomic_compare_exchange",Atomic_compare_exchange;
  "atomic_fetch_add",Atomic_fetch_add;"atomic_fetch_sub",Atomic_fetch_sub;
  "atomic_fetch_and",Atomic_fetch_and;"atomic_fetch_or",Atomic_fetch_or;"atomic_fetch_xor",Atomic_fetch_xor]
let names=List.map fst kinds
let kind name=List.assoc_opt name kinds
let name k=fst(List.find(fun(_,v)->k=v)kinds)
let payloads=function Atomic_load->0|Atomic_compare_exchange->2|_->1
let order=function "relaxed"->Some Relaxed|"acquire"->Some Acquire|"release"->Some Release
  |"acq_rel"->Some Acq_rel|"seq_cst"->Some Seq_cst|_->None
let validate kind typ success failure =
  if not(Type_desc.is_integer typ)then Error "atomic element must be an integer scalar"
  else match kind,success,failure with
  |Atomic_load,(Release|Acq_rel),_->Error "atomic_load order cannot be release or acq_rel"
  |Atomic_store,(Acquire|Acq_rel),_->Error "atomic_store order cannot be acquire or acq_rel"
  |Atomic_compare_exchange,_,None->Error "atomic_compare_exchange requires a failure order"
  |Atomic_compare_exchange,_,Some(Release|Acq_rel)->Error "CAS failure order cannot be release or acq_rel"
  |Atomic_compare_exchange,s,Some f when not(List.mem f(match s with
      |Relaxed|Release->[Relaxed]|Acquire|Acq_rel->[Relaxed;Acquire]|Seq_cst->[Relaxed;Acquire;Seq_cst]))->
      Error "CAS failure order is stronger than success order"
  |Atomic_compare_exchange,_,Some _->Ok()
  |_,_,Some _->Error "failure order is only valid for atomic_compare_exchange"
  |_->Ok()
