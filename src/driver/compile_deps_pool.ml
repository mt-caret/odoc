open Eio

(* A pool of persistent [odoc compile-deps --worker] processes. Each loads odoc
   once and then answers many requests over its stdin/stdout, so the driver pays
   odoc's (large) process-startup cost once per worker instead of once per file.
   Workers are separate processes — independent runtimes and GCs — so this keeps
   real parallelism without the shared stop-the-world GC that makes OCaml domains
   counterproductive for this work. *)

type worker = { write : string -> unit; reader : Buf_read.t }

type t = {
  workers : worker Stream.t;  (** free-worker queue: one request per worker *)
  respawn : unit -> worker;  (** replace a worker that has died *)
}

let pool : t option ref = ref None

let spawn ~sw ~proc_mgr ~stderr odoc_cmd =
  let in_r, in_w = Process.pipe proc_mgr ~sw in
  let out_r, out_w = Process.pipe proc_mgr ~sw in
  let _child = Process.spawn ~sw proc_mgr ~stdin:in_r ~stdout:out_w ~stderr odoc_cmd in
  Flow.close in_r;
  Flow.close out_w;
  {
    write = (fun s -> Flow.copy_string s in_w);
    (* Finite limit so a worker that never sends the terminator fails loudly
       rather than growing the buffer forever. *)
    reader = Buf_read.of_flow out_r ~max_size:(100 * 1024 * 1024);
  }

(* Probe whether the configured odoc understands [compile-deps --worker]: spawn
   one with an immediately-closed stdin; a worker exits 0 on EOF, an older odoc
   exits non-zero on the unknown flag. *)
let supports_worker ~proc_mgr ~stderr odoc_cmd =
  try
    Switch.run @@ fun sw ->
    let in_r, in_w = Process.pipe proc_mgr ~sw in
    let child =
      Process.spawn ~sw proc_mgr ~stdin:in_r ~stdout:stderr ~stderr odoc_cmd
    in
    Flow.close in_w;
    Flow.close in_r;
    match Process.await child with `Exited 0 -> true | _ -> false
  with _ -> false

let init ~sw env ~odoc ~count =
  (* Escape hatch for A/B measurement: fall back to one-shot subprocesses. *)
  match Sys.getenv_opt "ODOC_DRIVER_NO_DEP_WORKERS" with
  | Some _ -> ()
  | None ->
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let stderr = Eio.Stdenv.stderr env in
      let odoc_cmd = Bos.Cmd.(to_list (odoc % "compile-deps" % "--worker")) in
      if not (supports_worker ~proc_mgr ~stderr odoc_cmd) then
        Logs.info (fun m ->
            m
              "odoc does not support 'compile-deps --worker'; using one-shot \
               subprocesses")
      else begin
        let respawn () = spawn ~sw ~proc_mgr ~stderr odoc_cmd in
        let count = max 1 count in
        let workers = Stream.create count in
        for _ = 1 to count do
          Stream.add workers (respawn ())
        done;
        pool := Some { workers; respawn }
      end

let request f =
  match !pool with
  | None -> None
  | Some { workers; respawn } -> (
      let w = Stream.take workers in
      match
        w.write (Fpath.to_string f ^ "\n");
        (* The worker terminates each response with a blank line; dependency
           lines are never blank. *)
        let rec read acc =
          match Buf_read.line w.reader with
          | "" -> List.rev acc
          | line -> read (line :: acc)
        in
        read []
      with
      | lines ->
          Stream.add workers w;
          Some lines
      | exception exn ->
          (* The worker died mid-request: drop it (do not recycle a poison
             pill), start a replacement, and let the caller fall back to a
             one-shot subprocess for this file. *)
          Logs.warn (fun m ->
              m "compile-deps worker failed (%s); falling back for %a"
                (Printexc.to_string exn) Fpath.pp f);
          (try Stream.add workers (respawn ()) with _ -> ());
          None)
