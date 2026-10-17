(* SPDX-License-Identifier: Apache-2.0 *)
(* Apple Silicon backend. Native execution is gated by macOS CI. *)
include (struct
  let description : Backend_intf.description = {
    target=Darwin_runtime.target;
    calling_convention="Xen internal AArch64; LC_MAIN C argc/argv entry; x18 reserved";
    runtime="Darwin BSD traps, ownership and file/numeric services";
    executable_format="Mach-O64 PIE with dyld/libSystem and ad-hoc SHA-256 signing";
  }
  type executable = bytes
  module Codegen = Xen_arm64.Native_backend.Make(Darwin_runtime)
  let generate = Codegen.generate
  let write = Codegen.write
end : Backend_intf.S)
