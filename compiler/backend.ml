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
let host_target ~architecture ~system =
  match architecture, system with
  | "arm64", "linux" -> Ok {Target.architecture=Target.Aarch64;operating_system=Target.Linux}
  | "amd64", "linux" -> Ok {Target.architecture=Target.X86_64;operating_system=Target.Linux}
  | _ -> Error ("unsupported compiler host '" ^ architecture ^ "-" ^ system ^
      "'; specify --target=x86_64-linux or --target=aarch64-linux")
let default_target () = host_target ~architecture:Host_config.architecture ~system:Host_config.system
(* Library callers retain an explicit portable fallback; CLI reports unknown hosts. *)
let default = match select (Result.value (default_target ()) ~default:Target.default) with
  | Ok backend -> backend | Error _ -> assert false
let default_jit target = target.Target.architecture=Target.X86_64
