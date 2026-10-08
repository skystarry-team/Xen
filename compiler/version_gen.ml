(* SPDX-License-Identifier: Apache-2.0 *)
let () =
  let input = open_in Sys.argv.(1) in
  let fallback = Fun.protect ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input) |> String.trim) in
  let version = if Sys.argv.(2) = "" then fallback else Sys.argv.(2) in
  if version = "" || not (String.for_all (function
      | 'a'..'z' | 'A'..'Z' | '0'..'9' | '.' | '-' | '_' | '+' -> true
      | _ -> false) version) then
    (prerr_endline "invalid build version; use letters, digits, '.', '-', '_' or '+'"; exit 1);
  Printf.printf "(* SPDX-License-Identifier: Apache-2.0 *)\nlet current = %S\n" version
