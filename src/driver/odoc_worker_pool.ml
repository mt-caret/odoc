open Eio

(* A pool of persistent [odoc worker] processes that run full odoc commands
   (compile / link / html-generate) over a small line protocol, reusing one
   process for many units so odoc's process-startup cost is paid once per worker
   rather than once per command. Separate processes keep independent GCs (real
   parallelism, no shared stop-the-world barrier), and the worker resets odoc's
   per-unit global state between requests so output is identical to one-shot. *)

type worker = { write : string -> unit; reader : Buf_read.t }

type t = { workers : worker Stream.t; respawn : unit -> worker }

let pool : t option ref = ref None

let spawn ~sw ~proc_mgr ~stderr odoc_cmd =
  let in_r, in_w = Process.pipe proc_mgr ~sw in
  let out_r, out_w = Process.pipe proc_mgr ~sw in
  let _child = Process.spawn ~sw proc_mgr ~stdin:in_r ~stdout:out_w ~stderr odoc_cmd in
  Flow.close in_r;
  Flow.close out_w;
  {
    write = (fun s -> Flow.copy_string s in_w);
    reader = Buf_read.of_flow out_r ~max_size:(100 * 1024 * 1024);
  }

(* Probe whether the configured odoc understands [worker]: an immediately-closed
   stdin makes a real worker exit 0 on EOF; an older odoc rejects the unknown
   subcommand and exits non-zero. *)
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
  match Sys.getenv_opt "ODOC_DRIVER_NO_WORKERS" with
  | Some _ -> ()
  | None ->
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let stderr = Eio.Stdenv.stderr env in
      let odoc_cmd = Bos.Cmd.(to_list (odoc % "worker")) in
      if not (supports_worker ~proc_mgr ~stderr odoc_cmd) then
        Logs.info (fun m ->
            m "odoc does not support 'worker' mode; using one-shot subprocesses")
      else begin
        let respawn () = spawn ~sw ~proc_mgr ~stderr odoc_cmd in
        let count = max 1 count in
        let workers = Stream.create count in
        for _ = 1 to count do
          Stream.add workers (respawn ())
        done;
        pool := Some { workers; respawn }
      end

(* [Some (Ok ())] on success, [Some (Error _)] if the command genuinely failed
   (treat as a failed unit), or [None] if there is no pool or the worker died (so
   the caller falls back to a one-shot run). *)
let run cmd =
  match !pool with
  | None -> None
  | Some { workers; respawn } -> (
      match Bos.Cmd.to_list cmd with
      | [] | [ _ ] -> None (* not an odoc subcommand invocation *)
      | _odoc :: args -> (
          let w = Stream.take workers in
          match
            (* Request: the argument count, then one line per argument. *)
            w.write (string_of_int (List.length args) ^ "\n");
            List.iter (fun a -> w.write (a ^ "\n")) args;
            Buf_read.line w.reader
          with
          | "OK" ->
              Stream.add workers w;
              Some (Ok ())
          | "ERR" ->
              Stream.add workers w;
              Some (Error (Failure (Bos.Cmd.to_string cmd ^ " failed")))
          | _unexpected ->
              (* Protocol desync — drop this worker and fall back. *)
              (try Stream.add workers (respawn ()) with _ -> ());
              None
          | exception exn ->
              Logs.warn (fun m ->
                  m "odoc worker failed (%s); falling back to a one-shot run"
                    (Printexc.to_string exn));
              (try Stream.add workers (respawn ()) with _ -> ());
              None))
