(* SPDX-License-Identifier: MIT OR Apache-2.0 *)
(* Exercise the actual host test-runner plumbing without registering a backend. *)
let () =
  if Array.length Sys.argv<>4 then failwith "usage: windows_runner_fixture EXE STDOUT STDERR";
  let executable=Bytes.of_string(Project_loader.read_file Sys.argv.(1))in
  let write path contents=let ch=open_out_bin path in
    Fun.protect ~finally:(fun()->close_out ch)(fun()->output_bytes ch contents);
    if not Sys.win32 then Unix.chmod path 0o755 in
  let status,stdout,stderr=Test_runner.execute
    ~target:{Target.architecture=X86_64;operating_system=Windows} ~write executable in
  write Sys.argv.(2)(Bytes.of_string stdout);write Sys.argv.(3)(Bytes.of_string stderr);
  match status with
  |Unix.WEXITED n->Printf.printf "%d\n" n
  |Unix.WSIGNALED n|Unix.WSTOPPED n->failwith("unexpected signal "^string_of_int n)
