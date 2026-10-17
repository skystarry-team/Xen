(* SPDX-License-Identifier: Apache-2.0 *)
module M = Xen_x86_64.Machine_ir
module W = Xen_x86_64.Win64
module P = Xen_windows.Pe_writer

let executable ?stack_reserve ?stack_commit ?(bss_size=0) ?(pointers=[])
    ~entry ~functions output =
  let entry=match Hashtbl.find_opt output.M.labels entry with
    |Some offset->offset|None->raise(M.Missing_label entry)in
  let functions=List.map(fun(f:W.function_frame)->
    {P.begin_offset=f.begin_offset;end_offset=f.end_offset;prolog_size=f.prolog_size;
     codes=List.map(fun(c:W.unwind_code)->
       {P.code_offset=c.code_offset;operation=(match c.operation with
         |W.Push_nonvol r->P.Push_nonvol r|W.Alloc_stack n->P.Alloc_stack n
         |W.Save_nonvol(r,n)->P.Save_nonvol(r,n)|W.Save_xmm(r,n)->P.Save_xmm(r,n)
         |W.Set_frame(r,n)->P.Set_frame(r,n))})f.codes})functions in
  P.executable ?stack_reserve ?stack_commit ~entry ~code_size:(M.position output)
    ~rodata:(Buffer.contents output.M.rodata) ~data:(Buffer.contents output.M.data)
    ~bss_size ~imports:(List.map(fun(l,s,_)->l,s)output.M.imports) ~pointers ~functions
    ~encode:(fun ~code_address ~rodata_address ~data_address ~import_address->
      M.encode ~code_address ~rodata_address ~data_address ~import_address output) ()
