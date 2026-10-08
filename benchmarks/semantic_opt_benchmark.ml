(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Isolate region-pass cost from source analysis/revalidation. Observations
   only: no wall-clock thresholds belong in regression tests. *)
open Semantic_ir
let () =
  let sizes=[100;200;400;800]in
  let entries=List.map(fun n->
    let source="fn main(){let x=arg_count();"^String.concat ""(List.init n(fun _->"println(x*x);"))^"}"in
    let checked=match Checker.check(Parser.parse ~file:"scale.xen"source)with
      |Ok p->p|Error d->failwith d.message in
    let f=List.find(fun(f:func)->f.name="main")(program checked).functions in
    let times=List.init 5(fun _->Gc.full_major();let start=Unix.gettimeofday()in
      for _=1 to 20 do ignore(Semantic_opt.optimize_function f)done;
      (Unix.gettimeofday()-.start)*.1000./.20.) |> List.sort compare in
    Printf.sprintf "{\"statements\":%d,\"region_ms_median\":%.3f}"n(List.nth times 2))sizes in
  Printf.printf "[%s]\n"(String.concat ","entries)
