(* A pool of persistent [odoc compile-deps --worker] processes, so the driver can
   reuse one process for many files instead of spawning a fresh [odoc] per file. *)

val init :
  sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> odoc:Bos.Cmd.t -> count:int -> unit
(** [init ~sw env ~odoc ~count] spawns [count] persistent worker processes
    running [odoc compile-deps --worker]. They live until [sw] finishes. *)

val request : Fpath.t -> string list option
(** [request f] runs compile-deps for [f] on a free worker and returns its output
    lines, or [None] if the pool was never started (so callers can fall back to a
    one-shot subprocess). Blocks until a worker is free. *)
