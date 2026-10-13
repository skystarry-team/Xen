(* SPDX-License-Identifier: Apache-2.0 *)
(* Compose the OS-independent A64 lowering with Linux services and ELF. *)
include (struct
  let description : Backend_intf.description = {
    target={architecture=Target.Aarch64;operating_system=Target.Linux};
    calling_convention="Xen internal AArch64: x0..x5 argument addresses, x8 result address; not C FFI";
    runtime="Linux AArch64 static runtime with FP, managed ownership, Ptr/raw syscalls and target-selected stdlib";
    executable_format="Static non-PIE ELF64, little-endian, EM_AARCH64";
  }
  type executable = bytes
  let generate = Native_backend.generate
  let write = Native_backend.write
end : Backend_intf.S)
