(* SPDX-License-Identifier: Apache-2.0 *)
(* Keep the existing emitter behind a small adapter. A future Windows backend
   must supply its own platform ABI, runtime and executable writer. *)
include (struct
  let description : Backend_intf.description = {
    target = { architecture = Target.X86_64; operating_system = Target.Linux };
    calling_convention = "Xen internal x86-64 calling convention (not a C FFI ABI)";
    runtime = "Embedded Xen runtime and scalar JIT; Linux x86-64 syscalls";
    executable_format = "Static non-PIE ELF64, little-endian, EM_X86_64";
  }

  type executable = bytes
  let generate ?jit ?jit_report checked =
    match Native_backend.generate ?jit ?jit_report checked with
    | Ok executable -> Ok executable
    | Error (error : Native_backend.error) ->
        Error ({ span = error.span; message = error.message } : Backend_intf.error)
  let write = Native_backend.write
end : Backend_intf.S)
