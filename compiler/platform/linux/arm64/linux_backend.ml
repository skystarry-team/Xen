(* SPDX-License-Identifier: Apache-2.0 *)
(* Compose the OS-independent A64 lowering with Linux services and ELF. *)
include (struct
  let description : Backend_intf.description = {
    target={architecture=Target.Aarch64;operating_system=Target.Linux};
    calling_convention="Xen internal AArch64: argument/result addresses; extern_call uses scalar AAPCS64";
    runtime="Linux AArch64 runtime; optional glibc C startup and shared libraries";
    executable_format="Non-PIE ELF64, EM_AARCH64; static or dynamic for extern_call";
  }
  type executable = bytes
  let generate = Native_backend.generate
  let write = Native_backend.write
end : Backend_intf.S)
