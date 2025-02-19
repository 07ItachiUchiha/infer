(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open Textual

module ProcEntry = struct
  type t = Decl of ProcDecl.t | Desc of ProcDesc.t

  let is_implemented = function Decl _ -> false | Desc _ -> true

  let decl = function Decl p -> p | Desc p -> p.procdecl

  let desc = function Decl _ -> None | Desc p -> Some p

  let signature t lang = ProcDecl.to_sig (decl t) lang
end

type t =
  { globals: Global.t VarName.Hashtbl.t
  ; procs: ProcEntry.t ProcSig.Hashtbl.t
        (** the boolean records whether an implementation was given *)
  ; structs: Struct.t TypeName.Hashtbl.t
  ; sourcefile: SourceFile.t
  ; lang: Lang.t option }

let init sourcefile lang =
  { globals= VarName.Hashtbl.create 17
  ; procs= ProcSig.Hashtbl.create 17
  ; structs= TypeName.Hashtbl.create 17
  ; sourcefile
  ; lang }


type error =
  | FieldDeclaredTwice of qualified_fieldname
  | GlobalDeclaredTwice of Global.t
  | NodeImplementedTwice of qualified_procname * NodeName.t
  | ParameterDeclatedTwice of qualified_procname * VarName.t
  | ProcImplementedTwice of qualified_procname
  | StructDeclaredTwice of TypeName.t

let pp_error sourcefile fmt err =
  F.fprintf fmt "%a: SIL consistency error: " SourceFile.pp sourcefile ;
  match err with
  | FieldDeclaredTwice qualified_fieldname ->
      F.fprintf fmt "field %a is declared twice in type %a" FieldName.pp qualified_fieldname.name
        TypeName.pp qualified_fieldname.enclosing_class
  | GlobalDeclaredTwice global ->
      F.fprintf fmt "global %a is declared twice in the same file" VarName.pp global.name
  | NodeImplementedTwice (qualified_procname, label) ->
      F.fprintf fmt "node %a is implemented twice in the same function %a" NodeName.pp label
        pp_qualified_procname qualified_procname
  | ParameterDeclatedTwice (qualified_procname, varname) ->
      F.fprintf fmt "parameter %a is declared twice in the same function %a" VarName.pp varname
        pp_qualified_procname qualified_procname
  | ProcImplementedTwice qualified_procname ->
      F.fprintf fmt "function %a is implemented twice in the same file" pp_qualified_procname
        qualified_procname
  | StructDeclaredTwice tname ->
      F.fprintf fmt "type %a is declared twice in the same file" TypeName.pp tname


let declare_global decls (global : Global.t) =
  VarName.Hashtbl.replace decls.globals global.name global


let is_global_declared decls (global : Global.t) = VarName.Hashtbl.mem decls.globals global.name

let is_proc_implemented decls proc =
  let procsig = ProcDecl.to_sig proc decls.lang in
  ProcSig.Hashtbl.find_opt decls.procs procsig
  |> Option.value_map ~default:false ~f:ProcEntry.is_implemented


let declare_proc decls (proc : ProcEntry.t) =
  let procsig = ProcEntry.signature proc decls.lang in
  let existing_proc = ProcSig.Hashtbl.find_opt decls.procs procsig in
  match (existing_proc, proc) with
  | Some (Desc _), Decl _ ->
      ()
  | _, _ ->
      ProcSig.Hashtbl.replace decls.procs procsig proc


let declare_struct decls (s : Struct.t) = TypeName.Hashtbl.replace decls.structs s.name s

let is_struct_declared decls (s : Struct.t) = TypeName.Hashtbl.mem decls.structs s.name

let is_field_declared decls ({enclosing_class; name} : qualified_fieldname) =
  match TypeName.Hashtbl.find_opt decls.structs enclosing_class with
  | None ->
      false
  | Some struct_ ->
      List.exists struct_.fields ~f:(fun {FieldDecl.qualified_name} ->
          FieldName.equal qualified_name.name name )


let get_global decls vname = VarName.Hashtbl.find_opt decls.globals vname

let get_fielddecl decls ({name; enclosing_class} : qualified_fieldname) =
  let open IOption.Let_syntax in
  let* struct_ = TypeName.Hashtbl.find_opt decls.structs enclosing_class in
  List.find struct_.Struct.fields ~f:(fun ({qualified_name} : FieldDecl.t) ->
      FieldName.equal qualified_name.name name )


let rec get_procentry decls procsig =
  match procsig with
  | ProcSig.Hack {qualified_name; arity= Some _} ->
      (* Hack translation can have some procs declared with unknown formals, while at call sites the
         proc is called with some arguments. To accomodate this case we first look for a proc with
         the corresponding arity and then for its 'unknown formals' variation. *)
      ProcSig.Hashtbl.find_opt decls.procs procsig
      |> IOption.if_none_evalopt ~f:(fun () ->
             get_procentry decls (ProcSig.Hack {qualified_name; arity= None}) )
  | ProcSig.Python {qualified_name; arity= Some _} ->
      (* Python translation can have some procs declared with unknown formals, while at call sites the
         proc is called with some arguments. To accomodate this case we first look for a proc with
         the corresponding arity and then for its 'unknown formals' variation. *)
      ProcSig.Hashtbl.find_opt decls.procs procsig
      |> IOption.if_none_evalopt ~f:(fun () ->
             get_procentry decls (ProcSig.Python {qualified_name; arity= None}) )
  | ProcSig.Hack {arity= None; _} | ProcSig.Python {arity= None; _} | ProcSig.Other _ ->
      ProcSig.Hashtbl.find_opt decls.procs procsig


let get_procdecl decls procsig = get_procentry decls procsig |> Option.map ~f:ProcEntry.decl

let get_struct decls tname = TypeName.Hashtbl.find_opt decls.structs tname

let fold_globals decls ~init ~f =
  VarName.Hashtbl.fold (fun key data x -> f x key data) decls.globals init


let fold_procs decls ~init ~f = ProcSig.Hashtbl.fold (fun _ proc x -> f x proc) decls.procs init

let fold_procdecls decls ~init ~f =
  fold_procs decls ~init ~f:(fun x proc -> f x (ProcEntry.decl proc))


let fold_structs decls ~init ~f =
  TypeName.Hashtbl.fold (fun key data x -> f x key data) decls.structs init


let get_proc_entries_by_enclosing_class decls =
  fold_procs decls ~init:(TypeName.Map.empty, TypeName.Set.empty) ~f:(fun (map, set) proc ->
      let pdecl = ProcEntry.decl proc in
      match pdecl.ProcDecl.qualified_name.enclosing_class with
      | Enclosing tname ->
          let set =
            if TypeName.Hashtbl.mem decls.structs tname then set else TypeName.Set.add tname set
          in
          let methods = TypeName.Map.find_opt tname map |> Option.value ~default:[] in
          (TypeName.Map.add tname (proc :: methods) map, set)
      | TopLevel ->
          (map, set) )


let source_file {sourcefile} = sourcefile

let lang {lang} = lang

let check_fieldnames_not_declared_twice errors struct_ =
  List.fold struct_.Struct.fields ~init:(errors, FieldName.Set.empty)
    ~f:(fun (errors, seen) {FieldDecl.qualified_name} ->
      let name = qualified_name.name in
      let errors =
        if FieldName.Set.mem name seen then FieldDeclaredTwice qualified_name :: errors else errors
      in
      (errors, FieldName.Set.add name seen) )
  |> fst


let check_parameters_not_declared_twice errors procdesc =
  List.fold procdesc.ProcDesc.params ~init:(errors, VarName.Set.empty)
    ~f:(fun (errors, seen) vname ->
      let errors =
        if VarName.Set.mem vname seen then
          ParameterDeclatedTwice (procdesc.ProcDesc.procdecl.qualified_name, vname) :: errors
        else errors
      in
      (errors, VarName.Set.add vname seen) )
  |> fst


let check_global_not_declared_twice decls errors global =
  if is_global_declared decls global then GlobalDeclaredTwice global :: errors else errors


let check_struct_not_declared_twice decls errors struct_ =
  if is_struct_declared decls struct_ then StructDeclaredTwice struct_.Struct.name :: errors
  else errors


let check_nodes_not_implemented_twice errors procdesc =
  List.fold procdesc.ProcDesc.nodes ~init:(errors, NodeName.Set.empty)
    ~f:(fun (errors, seen) node ->
      let label = node.Node.label in
      let errors =
        if NodeName.Set.mem label seen then
          NodeImplementedTwice (procdesc.ProcDesc.procdecl.qualified_name, label) :: errors
        else errors
      in
      (errors, NodeName.Set.add label seen) )
  |> fst


let check_proc_not_implemented_twice decls errors procdecl =
  if is_proc_implemented decls procdecl then
    ProcImplementedTwice procdecl.ProcDecl.qualified_name :: errors
  else errors


let rec get_typ_name (typ : Typ.t) =
  match typ with Struct tname -> Some tname | Ptr typ | Array typ -> get_typ_name typ | _ -> None


let get_procdesc_referenced_types (pdesc : ProcDesc.t) =
  let referenced = TypeName.HashSet.create 17 in
  let add_to_referenced name = TypeName.HashSet.add name referenced in
  (* Helpers *)
  let rec from_exp (exp : Exp.t) =
    match exp with
    | Typ typ ->
        get_typ_name typ |> Option.iter ~f:add_to_referenced
    | Var _ | Lvar _ | Const _ ->
        ()
    | Field {exp} ->
        from_exp exp
    | Index (base, idx) ->
        from_exp base ;
        from_exp idx
    | Call {args} ->
        List.iter args ~f:from_exp
  and from_bexp (bexp : BoolExp.t) =
    match bexp with
    | Exp exp ->
        from_exp exp
    | Not bexp ->
        from_bexp bexp
    | And (bexp1, bexp2) | Or (bexp1, bexp2) ->
        from_bexp bexp1 ;
        from_bexp bexp2
  in
  let from_instr (ins : Instr.t) =
    match ins with
    | Load {exp; typ} ->
        get_typ_name typ |> Option.iter ~f:add_to_referenced ;
        from_exp exp
    | Store {exp1; typ; exp2} ->
        from_exp exp1 ;
        get_typ_name typ |> Option.iter ~f:add_to_referenced ;
        from_exp exp2
    | Prune {exp} | Let {exp} ->
        from_exp exp
  in
  let from_node_call ({ssa_args} : Terminator.node_call) = List.iter ssa_args ~f:from_exp in
  let rec from_terminator (t : Terminator.t) =
    match t with
    | If {bexp; then_; else_} ->
        from_bexp bexp ;
        from_terminator then_ ;
        from_terminator else_
    | Ret exp | Throw exp ->
        from_exp exp
    | Jump node_call ->
        List.iter node_call ~f:from_node_call
    | Unreachable ->
        ()
  in
  let from_node (node : Node.t) =
    let from_ssa =
      List.iter node.ssa_parameters ~f:(fun (_, typ) ->
          get_typ_name typ |> Option.iter ~f:add_to_referenced )
    in
    let from_instrs = List.iter node.instrs ~f:from_instr in
    let from_term = from_terminator node.last in
    from_ssa ;
    from_instrs ;
    from_term
  in
  let from_local (_, ({typ} : Typ.annotated)) =
    get_typ_name typ |> Option.iter ~f:add_to_referenced
  in
  (* Accumulate referenced type names *)
  List.iter pdesc.nodes ~f:from_node ;
  List.iter pdesc.locals ~f:from_local ;
  TypeName.HashSet.iter referenced |> Iter.to_list


let get_undefined_types decls =
  let referenced_tnames, defined_tnames =
    (TypeName.HashSet.create 17, TypeName.HashSet.create 17)
  in
  (* Helpers *)
  let register_tname tname set = TypeName.HashSet.add tname set in
  let register_tnames tnames set = List.iter tnames ~f:(fun x -> register_tname x set) in
  let register_typ typ set =
    Option.iter (get_typ_name typ) ~f:(fun tname -> register_tname tname set)
  in
  let register_annotated_typ ({typ} : Typ.annotated) set = register_typ typ set in
  let register_annotated_typs typs set =
    List.iter typs ~f:(fun annotated_typ -> register_annotated_typ annotated_typ set)
  in
  (* Collect type names from Globals *)
  VarName.Hashtbl.to_seq_values decls.globals
  |> Seq.iter (fun ({typ} : Global.t) -> register_typ typ referenced_tnames) ;
  (* Collect type names from Procdecls  *)
  ProcSig.Hashtbl.to_seq_values decls.procs
  |> Seq.iter (fun (proc : ProcEntry.t) ->
         let procdecl = ProcEntry.decl proc in
         register_annotated_typ procdecl.result_type referenced_tnames ;
         let formals_types = Option.value procdecl.formals_types ~default:[] in
         register_annotated_typs formals_types referenced_tnames ;
         Option.iter (ProcEntry.desc proc) ~f:(fun pdesc ->
             let types = get_procdesc_referenced_types pdesc in
             register_tnames types referenced_tnames ) ) ;
  (* Collect type names from Structs  *)
  TypeName.Hashtbl.to_seq_values decls.structs
  |> Seq.iter (fun (s : Struct.t) ->
         register_tname s.name referenced_tnames ;
         register_tname s.name defined_tnames ;
         register_tnames s.supers referenced_tnames ;
         List.iter s.fields ~f:(fun (field : FieldDecl.t) ->
             register_tname field.qualified_name.enclosing_class referenced_tnames ;
             register_typ field.typ referenced_tnames ) ) ;
  (* TODO(arr): collect types from expressions such as alloc and cast. We'll need to extend the
     decls with ProcDescs to have access to expressions. *)
  TypeName.HashSet.remove_all (TypeName.HashSet.iter defined_tnames) referenced_tnames ;
  TypeName.HashSet.seq referenced_tnames


let make_decls ({decls; sourcefile} as module_ : Module.t) : error list * t =
  let lang = Module.lang module_ in
  let decls_env = init sourcefile lang in
  let register errors decl =
    match (decl : Module.decl) with
    | Global global ->
        let errors = check_global_not_declared_twice decls_env errors global in
        declare_global decls_env global ;
        errors
    | Struct struct_ ->
        let errors = check_struct_not_declared_twice decls_env errors struct_ in
        let errors = check_fieldnames_not_declared_twice errors struct_ in
        declare_struct decls_env struct_ ;
        errors
    | Procdecl procdecl ->
        declare_proc decls_env (Decl procdecl) ;
        errors
    | Proc pdesc ->
        let procdecl = pdesc.procdecl in
        let errors = check_proc_not_implemented_twice decls_env errors procdecl in
        let errors = check_parameters_not_declared_twice errors pdesc in
        let errors = check_nodes_not_implemented_twice errors pdesc in
        declare_proc decls_env (Desc pdesc) ;
        errors
  in
  let errors = List.fold decls ~init:[] ~f:register in
  (errors, decls_env)
