type log_dest =
  [ `Compile
  | `Compile_src
  | `Link
  | `Count_occurrences
  | `Generate
  | `Index
  | `Sherlodoc
  | `Classify ]

type log_line = { log_dest : log_dest; prefix : string; run : Run.t }

(* Accumulated newest-first for O(1) insertion; read back with [get_outputs],
   which reverses to restore execution order. Appending at the tail here would
   be O(n) per command, i.e. O(n^2) over a run. *)
let outputs : log_line list ref = ref []

let maybe_log log_dest run =
  match log_dest with
  | Some (log_dest, prefix) ->
      outputs := { log_dest; run; prefix } :: !outputs
  | None -> ()

(* The logged command outputs, in execution order. *)
let get_outputs () = List.rev !outputs

(* When [ODOC_DRIVER_KEEP_GOING] is set, a failed odoc command is logged and
   skipped instead of aborting the whole run -- quarantines a single bad unit so
   the rest of the switch is still documented, and lets a full crash inventory be
   collected in one pass. *)
let keep_going = Sys.getenv_opt "ODOC_DRIVER_KEEP_GOING" <> None

let submit log_dest desc cmd output_file =
  match Worker_pool.submit desc cmd output_file with
  | Ok x ->
      maybe_log log_dest x;
      String.split_on_char '\n' x.output
  | Error exn when keep_going ->
      Logs.err (fun m ->
          m "[keep-going] skipping failed command: %s" (Printexc.to_string exn));
      []
  | Error exn -> raise exn

let submit_ignore_failures log_dest desc cmd output_file =
  match Worker_pool.submit desc cmd output_file with
  | Ok x ->
      maybe_log log_dest x;
      ()
  | Error exn ->
      Logs.err (fun m -> m "Error: %s" (Printexc.to_string exn));
      ()
