(* SPDX-License-Identifier: Apache-2.0 *)
(* Only this driver registry knows concrete implementations. *)
let available : (module Backend_intf.S) list = [
  (module Xen_linux_x86_64.Linux_backend);
  (module Xen_linux_arm64.Linux_backend);
]

let select target =
  match List.find_opt (fun (module B : Backend_intf.S) ->
      B.description.target = target) available with
  | Some backend -> Ok backend
  | None ->
      let supported = List.map (fun (module B : Backend_intf.S) ->
        Target.to_string B.description.target) available in
      let status = match target.Target.operating_system with
        | Target.MacOS -> "is unsupported; macOS development is discontinued"
        | _ -> "is not implemented" in
      Error ("target '" ^ Target.to_string target ^ "' " ^ status ^
        "; supported targets: " ^ String.concat ", " supported)

let of_string name = Result.bind (Target.parse name) select
let host_target ~architecture ~system =
  let cpu=match architecture with
    |"arm64"|"aarch64"->Some Target.Aarch64
    |"amd64"|"x86_64"->Some Target.X86_64|_->None in
  let operating_system=match system with
    |"linux"->Some Target.Linux|"macosx"|"macos"|"darwin"->Some Target.MacOS
    |_->None in
  match cpu, operating_system with
  | Some architecture, Some operating_system -> Ok {Target.architecture;operating_system}
  | _ -> Error ("unsupported compiler host '" ^ architecture ^ "-" ^ system ^
      "'; specify --target=x86_64-linux or --target=aarch64-linux")
let default_target () = host_target ~architecture:Host_config.architecture ~system:Host_config.system
(* Legacy library fallback is fixed, independent of registration order. The CLI
   uses default_target/select directly and never falls back on an unsupported OS. *)
let library_default target = match Result.bind target select with
  | Ok backend -> backend
  | Error _ -> match select Target.default with
      |Ok backend->backend
      |Error message->invalid_arg ("legacy library backend unavailable: "^message)
let default = library_default (default_target ())
