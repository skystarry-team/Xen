(* SPDX-License-Identifier: Apache-2.0 *)
let expect condition message = if not condition then failwith message

let read path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))

let write path contents =
  let output = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out output)
    (fun () -> output_string output contents)

let () =
  let generator = Filename.concat (Filename.dirname Sys.executable_name)
    "../compiler/version_gen.exe" in
  let version_file = Filename.temp_file "xen-version-" ".txt"
  and stdout_file = Filename.temp_file "xen-version-" ".stdout"
  and stderr_file = Filename.temp_file "xen-version-" ".stderr" in
  Fun.protect ~finally:(fun () -> List.iter Sys.remove
      [version_file; stdout_file; stderr_file]) (fun () ->
    let invoke contents override =
      write version_file contents;
      let with_fd path flags f =
        let fd = Unix.openfile path flags 0o600 in
        Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> f fd) in
      let pid = with_fd version_file [Unix.O_RDONLY] (fun input ->
        with_fd stdout_file [Unix.O_WRONLY; Unix.O_TRUNC] (fun output ->
          with_fd stderr_file [Unix.O_WRONLY; Unix.O_TRUNC] (fun errors ->
            Unix.create_process generator [|generator; version_file; override|]
              input output errors))) in
      let status = snd (Unix.waitpid [] pid) in
      (* Generated OCaml text may itself use CRLF on Windows. *)
      let stdout = String.concat "" (String.split_on_char '\r' (read stdout_file)) in
      status, stdout, read stderr_file in
    let valid contents override expected =
      let status, stdout, stderr = invoke contents override in
      expect (status = Unix.WEXITED 0 && stderr = "" &&
        stdout = Printf.sprintf
          "(* SPDX-License-Identifier: Apache-2.0 *)\nlet current = %S\n" expected)
        "version generator changed the requested version" in
    List.iter (fun ending -> valid ("0.1.0-demo.5" ^ ending) "" "0.1.0-demo.5")
      ["\n"; "\r\n"; ""];
    valid "0.1.0-demo.5\r\n" "v1.2.3-rc.1+build_2" "v1.2.3-rc.1+build_2";
    List.iter (fun (contents, override) ->
      let status, stdout, stderr = invoke contents override in
      expect (status = Unix.WEXITED 1 && stdout = "" &&
        String.starts_with ~prefix:"invalid build version;" stderr)
        "version generator accepted an invalid version")
      ["\r\n", ""; "bad version\r\n", ""; "1.2.3\n", "bad/version"]);
  print_endline "Version generator LF/CRLF inputs, overrides and validation passed"
