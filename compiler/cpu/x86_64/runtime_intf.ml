(* SPDX-License-Identifier: Apache-2.0 *)
(* Inline service ABI used by the x86-64 lowering and ownership runtimes.
   Hooks emit instructions, not host operations. The inline alloc/unmap/read/
   write/close/open_ services keep rsp, rbx, rbp, r12..r15 and all FP registers.
   Errors are negative errno in rax, in the normalized range -4095..-1.
   CPU helpers may compare -4 for interrupted read/write and use -4096 as their
   private NUL-path sentinel; a platform must normalize these conventions. *)
module type S = sig
  val open_read_flags : int
  val open_write_flags : int
  (* Allocate a constant stack region, retaining all inputs except r11/flags.
     Platforms with guard pages probe each intervening page. *)
  val stack_allocate : Machine_ir.t -> int -> unit
  (* Emit a source-function prolog and return its epilog/frame-record emitter. *)
  val function_prologue : Machine_ir.t -> (unit -> unit)

  (* rsi = size. Returns rax = address/error. Clobbers rcx, rdi, rdx, r8..r11
     and flags, preserving rsi and all other registers. Anonymous read/write
     memory; allocation must be releasable with unmap. *)
  val alloc : Machine_ir.t -> unit
  (* rdi = address, rsi = bytes. Result in rax; only rcx, r11 and flags
     may additionally change. The same clobbers apply to read/write/close. *)
  val unmap : Machine_ir.t -> unit
  (* rdi = fd, rsi = buffer, rdx = count; result = byte count/error. *)
  val read : Machine_ir.t -> unit
  val write : Machine_ir.t -> unit
  (* rdi = fd. Close once; callers never retry an interrupted close. *)
  val close : Machine_ir.t -> unit
  (* rdi = NUL-terminated path, rsi = platform flags. Result = fd/error.
     May additionally clobber rdi, rsi, rdx, r10. *)
  val open_ : Machine_ir.t -> unit
  (* Terminate the process with the supplied status; must not return. *)
  val exit : Machine_ir.t -> int -> unit

  (* arity includes the raw number. Values were pushed left-to-right in 8-byte
     slots, last argument at rsp. Load the OS registers, consume arity*8 bytes,
     emit the trap, and return its unmodified native result in rax. *)
  val raw_syscall : Machine_ir.t -> arity:int -> unit
  (* Arguments pushed left-to-right as I64 slots. Consume all slots, return
     normalized I64 in rax. Unsupported services must report a source error. *)
  val platform_call : Machine_ir.t -> Platform_service.t -> (unit, string) result
  (* Define _start, initialize __xen_argc/argv (excluding the executable name),
     and leave rsp aligned to 16 before the CPU calls the Xen entry function. *)
  val start : Machine_ir.t -> unit
  (* Define _start and transfer through the C library to the CPU's C main thunk.
     Preserve the loader's finalizer and arrange C initialization/finalization. *)
  val foreign_start : Machine_ir.t -> main:string -> (unit, string) result
  val executable : entry:int -> Machine_ir.t -> bytes

end
