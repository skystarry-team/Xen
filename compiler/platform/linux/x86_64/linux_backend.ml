(* SPDX-License-Identifier: Apache-2.0 *)
(* Compose OS-independent x86-64 lowering with Linux services and ELF. *)
include (struct
  let description : Backend_intf.description = {
    target = { architecture = Target.X86_64; operating_system = Target.Linux };
    calling_convention = "Xen internal x86-64; extern_call uses System V scalar C ABI";
    runtime = "Embedded Xen runtime; Linux syscalls; optional glibc C startup and shared libraries";
    executable_format = "Non-PIE ELF64, EM_X86_64; static or dynamic for extern_call";
  }

  type executable = bytes
  let generate = Native_backend.generate
  let write = Native_backend.write
end : Backend_intf.S)
