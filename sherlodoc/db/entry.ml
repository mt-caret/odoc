let empty_string = String.make 0 '_'

let non_empty_string s =
  (* to protect against `ancient` segfaulting on statically allocated values *)
  if s = "" then empty_string else s

(* Base URL under which the odoc/odig HTML is served. Links are [<doc_base>/<pkg>/<path>],
   matching odig's [html/<pkg>/<Module>/.../index.html] layout. Defaults to the [/doc/]
   route served by [sherlodoc serve]; override for an external static host. *)
let doc_base =
  match Sys.getenv_opt "SHERLODOC_DOC_BASE" with
  | Some base -> base
  | None -> "/doc"

module Kind = struct
  type t =
    | Doc (** Standalone doc comment *)
    | Page (** Mld page *)
    | Impl (** Source page *)
    | Module
    | Module_type
    | Class
    | Class_type
    | Method
    | Val of Typexpr.t
    | Type_decl of string option
    | Type_extension
    | Extension_constructor of Typexpr.t
    | Exception of Typexpr.t
    | Constructor of Typexpr.t
    | Field of Typexpr.t

  let equal = ( = )

  let get_type t =
    match t with
    | Val typ | Extension_constructor typ | Exception typ | Constructor typ | Field typ ->
        Some typ
    | Doc | Page | Impl | Module | Module_type | Class | Class_type | Method | Type_decl _
    | Type_extension ->
        None
end

module Package = struct
  type t =
    { name : string
    ; version : string
    }

  let v ~name ~version =
    { name = non_empty_string name; version = non_empty_string version }

  let compare a b = String.compare a.name b.name
  let link { name; version = _ } = doc_base ^ "/" ^ name ^ "/index.html"
end

type t =
  { name : string
  ; rhs : string option
  ; url : string
  ; kind : Kind.t
  ; cost : int
  ; doc_html : string
  ; pkg : Package.t
  }

let pp fmt { name; rhs; url; kind = _; cost; doc_html; pkg = _ } =
  Format.fprintf
    fmt
    "{ name = %s ; rhs = %a ; url = %s ; kind = . ; cost = %d ; doc_html = %s ; pkg = . }\n"
    name
    (Fmt.option Fmt.string)
    rhs
    url
    cost
    doc_html

let string_compare_shorter a b =
  match Int.compare (String.length a) (String.length b) with
  | 0 -> String.compare a b
  | c -> c

let structural_compare a b =
  match string_compare_shorter a.name b.name with
  | 0 -> begin
      match Package.compare a.pkg b.pkg with
      | 0 -> begin
          match Stdlib.compare a.kind b.kind with
          | 0 -> begin
              match string_compare_shorter a.doc_html b.doc_html with
              | 0 -> String.compare a.url b.url
              | c -> c
            end
          | c -> c
        end
      | c -> c
    end
  | c -> c

let compare a b =
  if a == b
  then 0
  else begin
    match Int.compare a.cost b.cost with
    | 0 -> structural_compare a b
    | cmp -> cmp
  end

let equal a b = compare a b = 0

(* [t.url] is the odoc/odig HTML path from the doc root, already including the package
   segment ([<pkg>/<lib>/<Module>/.../index.html#anchor] for odoc-driver output). *)
let link t = doc_base ^ "/" ^ t.url

let v ~name ~kind ~cost ~rhs ~doc_html ~url ~pkg () =
  { name = non_empty_string name
  ; kind
  ; url = non_empty_string url
  ; cost
  ; doc_html = non_empty_string doc_html
  ; pkg
  ; rhs = Option.map non_empty_string rhs
  }
