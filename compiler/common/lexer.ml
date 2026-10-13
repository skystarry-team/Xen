(* SPDX-License-Identifier: Apache-2.0 *)
open Ast

type kind =
  | Ident of string | Int_lit of string | Float_lit of string | String_lit of string
  | Fn | Let | Mut | If | Else | While | For | In | Break | Continue | Return | True | False | Match | Fat_arrow
  | Arrow | Eq | Plus | Minus | Star | Slash | Percent | Eq_eq | Bang_eq | Bang | Amp
  | And_and | Or_or | Lt | Lt_eq | Gt | Gt_eq
  | Lparen | Rparen | Lbrace | Rbrace | Colon | Comma | Semi | Eof
  | Hash | Lbracket | Rbracket | Dot | Dot_dot
  | Question

type token = { kind : kind; span : span }
exception Error of span * string

let lex ~file source =
  let length = String.length source in
  let rec scan offset line column tokens =
    let span = { file; line; column } in
    let emit kind width =
      scan (offset + width) line (column + width) ({ kind; span } :: tokens)
    in
    if offset >= length then List.rev ({ kind = Eof; span } :: tokens)
    else match source.[offset] with
    | ' ' | '\t' | '\r' -> scan (offset + 1) line (column + 1) tokens
    | '\n' -> scan (offset + 1) (line + 1) 1 tokens
    | '/' when offset + 1 < length && source.[offset + 1] = '/' ->
        let rec skip i = if i < length && source.[i] <> '\n' then skip (i + 1) else i in
        scan (skip (offset + 2)) line column tokens
    | '(' -> emit Lparen 1 | ')' -> emit Rparen 1
    | '[' -> emit Lbracket 1 | ']' -> emit Rbracket 1 | '#' -> emit Hash 1
    | '{' -> emit Lbrace 1 | '}' -> emit Rbrace 1
    | ':' -> emit Colon 1 | ',' -> emit Comma 1 | ';' -> emit Semi 1
    | '?' -> emit Question 1
    | '+' -> emit Plus 1 | '*' -> emit Star 1 | '/' -> emit Slash 1 | '%' -> emit Percent 1
    | '-' when offset + 1 < length && source.[offset + 1] = '>' -> emit Arrow 2
    | '-' -> emit Minus 1
    | '=' when offset + 1 < length && source.[offset + 1] = '>' -> emit Fat_arrow 2
    | '=' when offset + 1 < length && source.[offset + 1] = '=' -> emit Eq_eq 2
    | '=' -> emit Eq 1
    | '!' when offset + 1 < length && source.[offset + 1] = '=' -> emit Bang_eq 2
    | '!' -> emit Bang 1
    | '&' when offset + 1 < length && source.[offset + 1] = '&' -> emit And_and 2
    | '&' -> emit Amp 1
    | '|' when offset + 1 < length && source.[offset + 1] = '|' -> emit Or_or 2
    | '<' when offset + 1 < length && source.[offset + 1] = '=' -> emit Lt_eq 2
    | '>' when offset + 1 < length && source.[offset + 1] = '=' -> emit Gt_eq 2
    | '<' -> emit Lt 1 | '>' -> emit Gt 1
    | '"' ->
        let bytes = Buffer.create 16 in
        let rec literal i col =
          if i >= length then raise (Error (span, "unterminated string literal"))
          else match source.[i] with
          | '"' -> scan (i + 1) line (col + 1) ({ kind = String_lit (Buffer.contents bytes); span } :: tokens)
          | '\n' | '\r' ->
              raise (Error ({ span with column = col }, "string literal cannot contain a newline"))
          | '\\' ->
              if i + 1 >= length then raise (Error (span, "unterminated string literal"));
              let escaped = match source.[i + 1] with
                | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r' | '"' -> '"' | '\\' -> '\\'
                | character -> raise (Error ({ span with column = col },
                    Printf.sprintf "unknown string escape '\\\\%c'" character))
              in
              Buffer.add_char bytes escaped; literal (i + 2) (col + 2)
          | character -> Buffer.add_char bytes character; literal (i + 1) (col + 1)
        in literal (offset + 1) (column + 1)
    | '.' when offset + 1 < length && source.[offset + 1] = '.' -> emit Dot_dot 2
    | '.' -> emit Dot 1
    | '0' .. '9' ->
        let rec take i =
          if i < length && source.[i] >= '0' && source.[i] <= '9' then take (i + 1) else i
        in
        let integer_end = take offset in
        let after_fraction =
          if offset > 0 && source.[offset - 1] = '.' &&
             not (offset > 1 && source.[offset - 2] = '.') then integer_end
          else if integer_end < length && source.[integer_end] = '.' &&
             (integer_end + 1 >= length || source.[integer_end + 1] <> '.') then begin
            if integer_end + 1 >= length || source.[integer_end + 1] < '0' || source.[integer_end + 1] > '9'
            then raise (Error (span, "float literal must have digits after the decimal point"));
            take (integer_end + 1)
          end else integer_end
        in
        let next =
          if after_fraction < length && (source.[after_fraction] = 'e' || source.[after_fraction] = 'E') then begin
            let exponent = after_fraction + 1 in
            let digits = if exponent < length && (source.[exponent] = '+' || source.[exponent] = '-')
              then exponent + 1 else exponent in
            if digits >= length || source.[digits] < '0' || source.[digits] > '9'
            then raise (Error (span, "float literal exponent requires digits"));
            take digits
          end else after_fraction
        in
        let literal = String.sub source offset (next - offset) in
        let kind = if integer_end <> next then Float_lit literal else Int_lit literal in
        scan next line (column + next - offset) ({ kind; span } :: tokens)
    | ('a' .. 'z' | 'A' .. 'Z' | '_') ->
        let identifier = function
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false
        in
        let rec take i = if i < length && identifier source.[i] then take (i + 1) else i in
        let next = take offset in
        let word = String.sub source offset (next - offset) in
        let kind = match word with
          | "fn" -> Fn | "let" -> Let | "mut" -> Mut | "if" -> If | "else" -> Else
          | "while" -> While | "for" -> For | "in" -> In | "break" -> Break | "continue" -> Continue
          | "return" -> Return | "true" -> True | "false" -> False | "match" -> Match | _ -> Ident word
        in
        scan next line (column + next - offset) ({ kind; span } :: tokens)
    | character -> raise (Error (span, Printf.sprintf "unexpected character '%c'" character))
  in
  scan 0 1 1 []
