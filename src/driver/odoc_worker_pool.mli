(* A pool of persistent [odoc worker] processes, so the driver can run many
   compile/link/html-generate commands without re-spawning [odoc] each time. *)

val init :
  sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> odoc:Bos.Cmd.t -> count:int -> unit
(** [init ~sw env ~odoc ~count] spawns [count] persistent [odoc worker]
    processes (if the configured odoc supports [worker] mode). They live until
    [sw] finishes. *)

val run : Bos.Cmd.t -> (unit, exn) result option
(** Run an [odoc <subcommand> ...] command on a free worker. [Some (Ok ())] on
    success, [Some (Error _)] if the command failed, [None] if there is no usable
    pool (caller should fall back to a one-shot subprocess). Blocks until a
    worker is free. *)
