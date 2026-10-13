(* SPDX-License-Identifier: Apache-2.0 *)
(* Immutable prefix nodes. A node is reused only after byte-for-byte matching
   of its alias, validated parent identity and input, never on a digest alone.
   Disk values use a bounded text envelope; no OCaml values are unmarshalled. *)
type node = { alias:string; parent:string; input:string; output:string }
type receipt = { id:string; parent:string; hit:bool; reason:string }
type t = { directory:string option; identity:string;
           nodes:(string,node)Hashtbl.t; latest:(string,string)Hashtbl.t;
           mutable pending:(string*node)list; mutable aliases:(string*string)list;
           key_digest:string->string }
let schema="xen-opt-prefix-1"
let limit=1024*1024
let digest s=Digest.to_hex(Digest.string s)
let serialize value=Marshal.to_string value [Marshal.No_sharing]
let compiler_identity () =
  let executable=try Digest.to_hex(Digest.file Sys.executable_name)with Sys_error _->Sys.executable_name in
  schema^":"^Sys.ocaml_version^":"^executable
let rec mkdir path=if path<>"." && path<>"/" && not(Sys.file_exists path)then begin
  mkdir(Filename.dirname path);try Unix.mkdir path 0o700 with Unix.Unix_error(Unix.EEXIST,_,_)->()end
let create ?directory ?identity ?(key_digest=digest) () =
  let directory=Option.bind directory(fun path->try mkdir path;Some path with Sys_error _|Unix.Unix_error _->None)in
  {directory;identity=(match identity with Some value->value|None->compiler_identity());
   nodes=Hashtbl.create 32;latest=Hashtbl.create 32;pending=[];aliases=[];key_digest}
let valid_id s =
  let length=String.length s in length>=34 && length<=44 && s.[32]='-' &&
  let valid=ref true in String.iteri(fun i c->if i<32 then
    (if not((c>='0'&&c<='9')||(c>='a'&&c<='f'))then valid:=false)
    else if i>32 && not(c>='0'&&c<='9')then valid:=false)s;!valid
let encode node =
  let body=String.concat "\n"[schema;String.escaped node.alias;String.escaped node.parent;
    String.escaped node.input;String.escaped node.output]in body^"\n"^digest body^"\n"
let decode text = match String.split_on_char '\n' text with
  | [version;alias;parent;input;output;checksum;""] when version=schema->
      let body=String.concat "\n"[version;alias;parent;input;output]in
      if digest body<>checksum then None else
      (try let parent=Scanf.unescaped parent in
        if parent<>"root" && not(valid_id parent)then None else
        Some{alias=Scanf.unescaped alias;parent;input=Scanf.unescaped input;output=Scanf.unescaped output}
       with Scanf.Scan_failure _|Failure _|Invalid_argument _->None)
  | _->None
let read path = try
  let channel=open_in_bin path in Fun.protect ~finally:(fun()->close_in_noerr channel)(fun()->
    let size=in_channel_length channel in if size>limit then None else Some(really_input_string channel size))
  with Sys_error _|End_of_file->None
let atomic_write directory path contents ~replace =
  let temp,channel=Filename.open_temp_file ~temp_dir:directory "prefix-" ".tmp" in
  Fun.protect ~finally:(fun()->close_out_noerr channel;try Sys.remove temp with Sys_error _->())(fun()->
    output_string channel contents;close_out channel;
    if replace then Unix.rename temp path else Unix.link temp path)
let latest cache alias = match Hashtbl.find_opt cache.latest alias with
  | Some id->Some id
  | None->Option.bind cache.directory(fun directory->
      Option.bind(read(Filename.concat directory(digest alias^".alias")))(fun id->
        if valid_id id then Some id else None))
let load cache id = match Hashtbl.find_opt cache.nodes id with Some node->Some node
  | None->Option.bind cache.directory(fun directory->
      Option.bind(read(Filename.concat directory(id^".prefix")))decode)
let remember cache alias id =
  Hashtbl.replace cache.latest alias id;
  cache.aliases<-(alias,id)::cache.aliases
let commit cache =
  let failed=Hashtbl.create 16 in
  Option.iter(fun directory->
    let on_disk id=Option.bind(read(Filename.concat directory(id^".prefix")))decode in
    let matches id=match Hashtbl.find_opt cache.nodes id,on_disk id with
      | Some expected,Some actual->expected=actual|_->false in
    List.iter(fun(id,node)->
      let contents=encode node in
      let parent_valid=node.parent="root" ||
        (not(Hashtbl.mem failed node.parent) && matches node.parent)in
      let published=if not parent_valid || String.length contents>limit then false else
        try atomic_write directory(Filename.concat directory(id^".prefix"))contents ~replace:false;true
        with Unix.Unix_error(Unix.EEXIST,_,_)->on_disk id=Some node
          | Sys_error _|Unix.Unix_error _->false in
      if not published then Hashtbl.replace failed id())(List.rev cache.pending);
    List.iter(fun(alias,id)->if not(Hashtbl.mem failed id) && matches id then
      try atomic_write directory(Filename.concat directory(digest alias^".alias"))id ~replace:true
      with Sys_error _|Unix.Unix_error _->())(List.rev cache.aliases))cache.directory;
  Hashtbl.iter(fun id ()->Hashtbl.remove cache.nodes id)failed;
  Hashtbl.filter_map_inplace(fun _ id->if Hashtbl.mem failed id then None else Some id)cache.latest;
  cache.pending<-[];cache.aliases<-[]
let abort cache =
  List.iter(fun(id,_)->Hashtbl.remove cache.nodes id)cache.pending;
  Hashtbl.clear cache.latest;cache.pending<-[];cache.aliases<-[]
let advance ?(reuse=true) cache ~alias ~parent ~input ~accept ~compute =
  let key=cache.key_digest(serialize(cache.identity,alias,parent,input))in
  if not(valid_id(key^"-0"))then invalid_arg "prefix digest format";
  let previous=Option.bind(latest cache alias)(load cache)in
  let reason=match previous with
    | Some n when n.alias<>alias->"alias changed"
    | Some n when n.parent<>parent->"prefix changed"
    | Some n when n.input<>input->"input/context changed"
    | Some _->"invalid cached result"
    | None->"cold or corrupt" in
  let rec find slot =
    let id=key^"-"^string_of_int slot in
    let path=Option.map(fun directory->Filename.concat directory(id^".prefix"))cache.directory in
    match load cache id with
    | Some node when reuse && node.alias=alias && node.parent=parent && node.input=input && accept node.output->
        Hashtbl.replace cache.nodes id node;remember cache alias id;
        node.output,{id;parent;hit=true;reason="exact prefix"}
    | _ when Hashtbl.mem cache.nodes id || Option.exists Sys.file_exists path->find(slot+1)
    | _->
        let output=compute()in let node={alias;parent;input;output}in
        Hashtbl.replace cache.nodes id node;cache.pending<-(id,node)::cache.pending;
        remember cache alias id;
        output,{id;parent;hit=false;reason=(if reuse then reason else "prefix invalidated")}
        in find 0
