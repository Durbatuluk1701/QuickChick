open Pp
open Names
open Extract_env
open Tacmach
open Entries
open Declarations
open Declare
open Topconstr
open Libnames
open Util
open Constrintern

let message = "QuickChick"
let mk_ref s = CRef (Qualid (dummy_loc, qualid_of_string s))

(* Names corresponding to QuickChick's .v files *)
let showResult = mk_ref "QuickChick.Test.showResult"
let quickCheck = mk_ref "QuickChick.Test.quickCheck"

(* Locate QuickChick's files *)
(* The computation is delayed because QuickChick's libraries are not available
when the plugin is first loaded. *)
(* For trunk and forthcoming Coq 8.5:
let qid = Libnames.make_qualid (DirPath.make [Id.of_string "QuickChick"]) (Id.of_string "QuickChick")
*)
let qid = qualid_of_string "QuickChick.QuickChick"
let path =
  lazy (let (_,_,path) = Library.locate_qualified_library false qid in path)
let path = lazy (Filename.dirname (Lazy.force path))

(* Interface with OCaml compiler *)
let temp_dirname = Filename.get_temp_dir_name ()

let link_files = ["quickChickLib.cmx"]

(* TODO: in Coq 8.5, fetch OCaml's path from Coq's configure *)
let ocamlopt = "ocamlopt"
let ocamlc = "ocamlc"

let comp_mli_cmd fn =
  Printf.sprintf "%s -rectypes -I %s %s" ocamlc (Lazy.force path) fn

let comp_ml_cmd fn out =
  let path = Lazy.force path in
  let link_files = List.map (Filename.concat path) link_files in
  let link_files = String.concat " " link_files in
  Printf.sprintf "%s -rectypes -w a -I %s -I %s %s %s -o %s" ocamlopt
    temp_dirname path link_files fn out

(** [define c] introduces a fresh constant name for the term [c]. *)
let define c =
  let fresh_name =
    let base = Names.id_of_string "quickchick" in

  (** [is_visible_name id] returns [true] if [id] is already
      used on the Coq side. *)
    let is_visible_name id =
      try
        ignore (Nametab.locate (Libnames.qualid_of_ident id));
        true
      with Not_found -> false
    in
    (** Safe fresh name generation. *)
    Namegen.next_ident_away_from base is_visible_name
  in
  ignore (
    declare_constant ~internal:KernelVerbose fresh_name
      (DefinitionEntry {
        const_entry_body = c;
        const_entry_secctx = None;
        const_entry_type = None;
        const_entry_opaque = false
       },
       Decl_kinds.IsDefinition Decl_kinds.Definition)
  );
  fresh_name

(* TODO: clean leftover files *)
let quickcheck c =
  (** [c] is a constr_expr representing the property to test,
      so we first build a new constr_expr representing
      showResult (quickCheck c) **)
  let c = CApp(dummy_loc,(None,quickCheck), [(c,None)]) in
  let c = CApp(dummy_loc,(None,showResult), [(c,None)]) in
  (** Build the kernel term from the const_expr *)
  let env = Global.env () in
  let evd = Evd.empty in
  let c = interp_constr evd env c in
  (** Extract the term and its dependencies *)
  let main = define c in
  let mlf = Filename.temp_file "QuickChick" ".ml" in
  let execn = Filename.chop_extension mlf in
  let mlif = execn ^ ".mli" in
  let modn = Filename.basename execn in
  Flags.silently (full_extraction (Some mlf)) [Ident (dummy_loc, main)];
  (** Add a main function to get some output *)
  let oc = open_out_gen [Open_append;Open_text] 0o666 mlf in
  Printf.fprintf oc
    "\nlet _ = print_string (QuickChickLib.string_of_coqstring (%s))\n"
    (string_of_id main);
  close_out oc;
  (** Compile the extracted code *)
  if Sys.command (comp_mli_cmd mlif) <> 0 then
    msgerr (str "Could not compile test program interface" ++ fnl ())
  else if Sys.command (comp_ml_cmd mlf execn) <> 0 then
    msgerr (str "Could not compile test program" ++ fnl ())
  (** Run the test *)
  else if Sys.command execn <> 0 then
    msgerr (str "Could not run test" ++ fnl ())

VERNAC COMMAND EXTEND QuickCheck
  | ["QuickCheck" constr(c)] ->     [quickcheck c]
END;;
