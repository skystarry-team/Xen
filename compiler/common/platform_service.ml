(* SPDX-License-Identifier: Apache-2.0 *)
(* Finite raw service boundary for target standard libraries. All operands and
   results are I64, checked in bb. Buffers remain caller-owned; failures are
   normalized negative errno. No OS API names or syscall numbers cross this IR.
   cwd(address, capacity) returns UTF-8 bytes including NUL; address/capacity 0
   queries the required size. metadata(path, output) writes four I64 words:
   size, Unix modified seconds, is_directory, is_file, and returns zero.
   directory returns bytes of the target binding's native directory records.
   open modes are supplied by that binding, never interpreted in common. *)
type t = Read | Write | Open | Close | Directory | Cwd | Metadata | Id | Parent_id
let all = [Read;Write;Open;Close;Directory;Cwd;Metadata;Id;Parent_id]
let name = function Read->"read"|Write->"write"|Open->"open"|Close->"close"
  |Directory->"directory"|Cwd->"cwd"|Metadata->"metadata"|Id->"id"|Parent_id->"parent_id"
let find text = List.find_opt(fun service->name service=text)all
let arity = function Read|Write|Open|Directory->3|Close->1|Cwd|Metadata->2|Id|Parent_id->0
