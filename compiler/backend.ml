(* SPDX-License-Identifier: Apache-2.0 *)
(* Only this driver registry knows concrete implementations. *)
let available : (module Backend_intf.S) list = [
  (module Xen_x86_64.Linux_backend);
  (module Xen_arm64.Linux_backend);
]

let select target =
  match List.find_opt (fun (module B : Backend_intf.S) ->
      B.description.target = target) available with
  | Some backend -> Ok backend
  | None ->
      let supported = List.map (fun (module B : Backend_intf.S) ->
        Target.to_string B.description.target) available in
      Error ("target '" ^ Target.to_string target ^
        "' is not implemented; supported targets: " ^ String.concat ", " supported)

let of_string name = Result.bind (Target.parse name) select
let default = match select Target.default with Ok backend -> backend | Error _ -> assert false
