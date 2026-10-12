(* SPDX-License-Identifier: Apache-2.0 *)
type architecture = X86_64 | Aarch64
type operating_system = Linux | Windows
type t = { architecture : architecture; operating_system : operating_system }

let architecture_name = function X86_64 -> "x86_64" | Aarch64 -> "aarch64"
let os_name = function Linux -> "linux" | Windows -> "windows"
let to_string target =
  architecture_name target.architecture ^ "-" ^ os_name target.operating_system

(* Legacy explicit target for library callers. The driver selects its host's
   default from generated OCaml configuration; this layer has no host probes. *)
let default = { architecture = X86_64; operating_system = Linux }

let parse name =
  match String.split_on_char '-' name with
  | [architecture; operating_system] ->
      let arch = match architecture with
        | "x86_64" -> Some X86_64
        | "aarch64" | "arm64" -> Some Aarch64
        | _ -> None in
      let os = match operating_system with
        | "linux" -> Some Linux | "windows" -> Some Windows | _ -> None in
      (match arch, os with
       | Some architecture, Some operating_system -> Ok { architecture; operating_system }
       | None, _ -> Error ("unknown target architecture '" ^ architecture ^ "'")
       | _, None -> Error ("unknown target operating system '" ^ operating_system ^ "'"))
  | _ -> Error ("invalid target '" ^ name ^ "'; expected <architecture>-<os>")
