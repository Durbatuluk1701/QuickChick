open Pp
open Loc
open Names
open Extract_env
open Tacmach
open Entries
open Declarations
open Declare
open Libnames
open Util
open Constrintern
open Topconstr
open Constrexpr
open Constrexpr_ops
open Decl_kinds
open GenericLib
open SetLib
open CoqLib
open GenLib
open Feedback
open Unify

(* arguments to handle_branch *)
let fail_exp (dt : coq_expr) =
  returnGen (gApp ~explicit:true (gInject "None") [dt])

let ret_exp (dt : coq_expr) (c : coq_expr) =
  returnGen (gApp ~explicit:true (gInject "Some") [dt; c])

let ret_type (s : var) f = hole

let class_method = (gInject "arbitrary")

let class_methodST (pred : coq_expr) = 
  gApp ~explicit:true (gInject "arbitraryST")
    [ hole (* Implicit argument - type A *)
    ; pred
    ; hole (* Implicit instance *)]

let rec_method (rec_name : coq_expr) (size : coq_expr) (l : coq_expr list) =
  gApp rec_name (size :: l)

let bind (opt : bool) (m : coq_expr) (x : string) (f : var -> coq_expr) =
  (if opt then bindGenOpt else bindGen) m x f

let stMaybe (opt : bool) (g : coq_expr) (bool_pred : coq_expr) =
  (gApp (gInject (if opt then "suchThatMaybeOpt" else "suchThatMaybe"))
     [ g (* Use the generator provided for base generator *)
     ; bool_pred
     ])

(* hoisting out base and ind gen to be able to call them from proof generation *)


let base_gens
      (size : coq_expr)
      (full_gtyp : coq_expr)
      (gen_ctr : ty_ctr)
      (dep_type : dep_type)
      (ctrs : dep_ctr list)
      (input_names : var list)
      (n : int)
      (register_arbitrary : dep_type -> unit)
      (rec_name : coq_expr) =
  (* partially applied handle_branch *)
  let handle_branch' size =
    handle_branch n dep_type input_names (fail_exp full_gtyp) (ret_exp full_gtyp) ret_type
      class_method class_methodST (rec_method rec_name size) bind stMaybe gen_ctr register_arbitrary
  in
  let base_branches =
    List.map
      fst
      (List.filter (fun (_, b) -> b) (List.map (handle_branch' size) ctrs)) in
  base_branches

let ind_gens
      (size : coq_expr)
      (full_gtyp : coq_expr)
      (gen_ctr : ty_ctr)
      (dep_type : dep_type)
      (ctrs : dep_ctr list)
      (input_names : var list)
      (n : int)
      (register_arbitrary : dep_type -> unit)
      (rec_name : coq_expr) =
  (* partially applied handle_branch *)
  let handle_branch' c =
    handle_branch n dep_type input_names (fail_exp full_gtyp) (ret_exp full_gtyp) ret_type
      class_method class_methodST (rec_method rec_name size) bind stMaybe gen_ctr register_arbitrary
  in
  let all_branches = List.map (fun x -> fst (handle_branch' size x)) ctrs in
  all_branches

(* Advanced Generators *)
let arbitrarySizedST
      (gen_ctr : ty_ctr)
      (ty_params : ty_param list)
      (ctrs : dep_ctr list)
      (dep_type : dep_type)
      (input_names : string list)
      (inputs : arg list)
      (n : int)
      (register_arbitrary : dep_type -> unit) =

  (* type constructor *)
  let coqTyCtr = gTyCtr gen_ctr in

  (* parameters of the type constructor *)
  let coqTyParams = List.map gTyParam ty_params in

  (* Fully applied type constructor *)
  let full_dt = gApp ~explicit:true coqTyCtr coqTyParams in

  (* The type we are generating for -- not the predicate! *)
  let full_gtyp = (gType ty_params (nthType n dep_type)) in

  (* The type of the dependent generator *)
  let gen_type = gGen (gOption full_gtyp) in

  let input_names = List.map fresh_name input_names in

  (*  List.iter (fun x -> ignore (handle_branch x)) ctrs;  *)

  let aux_arb rec_name size vars =
    gMatch (gVar size)
      [ (injectCtr "O", [],
         fun _ ->
           uniform_backtracking
             (base_gens (gVar size) full_gtyp gen_ctr dep_type ctrs input_names n register_arbitrary rec_name))
      ; (injectCtr "S", ["size'"],
         fun [size'] ->
           uniform_backtracking
             (ind_gens (gVar size') full_gtyp gen_ctr dep_type ctrs input_names n register_arbitrary rec_name))
      ]
  in

  let generator_body : coq_expr =
    gRecFunInWithArgs
      ~assumType:(gen_type)
      "aux_arb" (gArg ~assumName:(gVar (fresh_name "size")) () :: inputs) 
      (fun (rec_name, size::vars) -> aux_arb (gVar rec_name) size vars)
      (fun rec_name -> gFun ["size"] 
          (fun [size] -> gApp (gVar rec_name) 
              (gVar size :: List.map gVar input_names)
          ))
  in

  msg_debug (fnl () ++ fnl () ++ str "`Final body produced:" ++ fnl ());
  debug_coq_expr generator_body;
  msg_debug (fnl ());
  gRecord [("arbitrarySizeST", generator_body)]
