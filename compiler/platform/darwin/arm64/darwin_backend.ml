(* SPDX-License-Identifier: Apache-2.0 *)
(* Internal prototype. Do not register until actual macOS execution is validated. *)
include (struct
  let description : Backend_intf.description = {
    target=Darwin_runtime.target;
    calling_convention="Xen internal AArch64; LC_MAIN C argc/argv entry; x18 reserved";
    runtime="Unvalidated Darwin prototype: normalized BSD traps, ownership and file/numeric services; no JIT";
    executable_format="Mach-O64 PIE with dyld/libSystem and ad-hoc SHA-256 signing (unvalidated)";
  }
  type executable = bytes
  module Codegen = Xen_arm64.Native_backend.Make(Darwin_runtime)
  let generate = Codegen.generate
  let write = Codegen.write
end : Backend_intf.S)
