open Lwt.Infix

module Capability = Capnp_rpc_lwt.Capability
module Client = Ocaml_ci_api.Client
module Server = Cohttp_lwt_unix.Server
module Response = Cohttp.Response.Make(Server.IO)
module Transfer_IO = Cohttp__Transfer_io.Make(Server.IO)

let normal_response x =
  x >|= fun x -> `Response x

let respond_error status body =
  let headers = Cohttp.Header.init_with "Content-Type" "text/plain" in
  Server.respond_error ~status ~headers ~body () |> normal_response

let (>>!=) x f =
  x >>= function
  | Error `Capnp ex -> respond_error `Internal_server_error (Fmt.to_to_string Capnp_rpc.Error.pp ex)
  | Ok y -> f y

let org_url owner =
  Printf.sprintf "/github/%s" owner

let repo_url ~owner name =
  Printf.sprintf "/github/%s/%s" owner name

let job_url ~owner ~name ~hash variant =
  Printf.sprintf "/github/%s/%s/commit/%s/variant/%s" owner name hash variant

let commit_url ~owner ~name hash =
  Printf.sprintf "/github/%s/%s/commit/%s" owner name hash

let github_branch_url ~owner ~name ref =
  Printf.sprintf "https://github.com/%s/%s/tree/%s" owner name ref

let github_pr_url ~owner ~name id =
  Printf.sprintf "https://github.com/%s/%s/pull/%s" owner name id

let css = {|
  .statuses {
    list-style: none;
  }
  .statuses > li:before {
    display: inline-block;
    width: 1em;
    margin-right: 0.5em;
    margin-left: -1.5em;
    text-align: center;
    line-height: 1.1em;
  }
  .statuses > li.not-started:before { content: "●"; color:grey; }
  .statuses > li.aborted:before { content: "A"; color:red; }
  .statuses > li.failed:before { content: "╳"; color:red; }
  .statuses > li.passed:before { content: "✓"; color:green; }
  .statuses > li.active:before { content: "●"; color:orange; }
  .statuses > li.undefined:before { content: "?"; color:grey; }
|}

let breadcrumbs steps page_title =
  let open Tyxml.Html in
  let add (prefix, results) (label, link) =
    let prefix = Printf.sprintf "%s/%s" prefix link in
    let link = li [a ~a:[a_href prefix] [txt label]] in
    (prefix, link :: results)
  in
  let _, steps = List.fold_left add ("", []) steps in
  let steps = li [b [txt page_title]] :: steps in
  ol ~a:[a_class ["breadcrumbs"]] (
    List.rev steps
  )

let statuses ss =
  let open Tyxml.Html in
  let render_status (s, elms) =
    let s_class =
      match (s : Client.State.t) with
      | NotStarted -> "not-started"
      | Aborted -> "aborted"
      | Failed _ -> "failed"
      | Passed -> "passed"
      | Active -> "active"
      | Undefined _ -> "undefined"
    in
    li ~a:[a_class [s_class]] elms
  in
  ul ~a:[a_class ["statuses"]] (List.map render_status ss)

let format_refs ~owner ~name refs =
  let open Tyxml.Html in
  ul (
    Client.Ref_map.to_seq refs |> List.of_seq |> List.map @@ fun (branch, commit) ->
    li [a ~a:[a_href (commit_url ~owner ~name commit)] [txt branch]]
  )

let rec intersperse ~sep = function
  | [] -> []
  | [x] -> [x]
  | x :: xs -> x :: sep :: intersperse ~sep xs

let link_github_refs ~owner ~name =
  let open Tyxml.Html in
  function
  | [] -> txt "(not at the head of any monitored branch or PR)"
  | refs ->
    p (
      txt "(for " ::
      (
        intersperse ~sep:(txt ", ") (
          refs |> List.map @@ fun r ->
          match Astring.String.cuts ~sep:"/" r with
          | ["refs"; "heads"; branch] ->
            span [txt "branch "; a ~a:[a_href (github_branch_url ~owner ~name branch)] [ txt branch ]]
          | ["refs"; "pull"; id; "head"] ->
            span [txt "PR "; a ~a:[a_href (github_pr_url ~owner ~name id)] [ txt ("#" ^ id) ]]
          | _ ->
            txt (Printf.sprintf "Bad ref format %S" r)
        )
      ) @
      [txt ")"]
    )

let link_jobs ~owner ~name ~hash ?selected jobs =
  let open Tyxml.Html in
  let render_job { Client.variant; outcome } =
    let uri = job_url ~owner ~name ~hash variant in
    let label = txt (Fmt.strf "%s (%a)" variant Client.State.pp outcome) in
    let label = if selected = Some variant then b [label] else label in
    outcome, [a ~a:[a_href uri] [label]]
  in
  statuses (List.map render_job jobs)

let short_hash = Astring.String.with_range ~len:6

let stream_logs job ~owner ~name ~refs ~hash ~jobs ~variant ~status (data, next) writer =
  let header, footer =
    let can_rebuild = status.Current_rpc.Job.can_rebuild in
    let buttons =
      if can_rebuild then Tyxml.Html.[
          form ~a:[a_action (variant ^ "/rebuild"); a_method `Post] [
            input ~a:[a_input_type `Submit; a_value "Rebuild"] ()
          ]
      ] else []
    in
    let body = Template.instance Tyxml.Html.[
        breadcrumbs ["github", "github";
                     owner, owner;
                     name, name;
                     short_hash hash, "commit/" ^ hash;
                    ] variant;
        link_github_refs ~owner ~name refs;
        link_jobs ~owner ~name ~hash ~selected:variant jobs;
        div buttons;
        pre [txt "@@@"]
      ] in
    Astring.String.cut ~sep:"@@@" body |> Option.get
  in
  let ansi = Current_ansi.create () in
  Transfer_IO.write writer (header ^ (Current_ansi.process ansi data)) >>= fun () ->
  let rec aux next =
    Current_rpc.Job.log job ~start:next >>= function
    | Ok ("", _) ->
      Transfer_IO.write writer footer
    | Ok (data, next) ->
      Transfer_IO.write writer (Current_ansi.process ansi data) >>= fun () ->
      aux next
    | Error (`Capnp ex) ->
      Log.warn (fun f -> f "Error fetching logs: %a" Capnp_rpc.Error.pp ex);
      Transfer_IO.write writer (Fmt.strf "ocaml-ci error: %a@." Capnp_rpc.Error.pp ex)
  in
  aux next

let repo_handle ~meth ~owner ~name ~repo path =
  match meth, path with
  | `GET, [] ->
      Client.Repo.refs repo >>!= fun refs ->
      let body = Template.instance [
          breadcrumbs ["github", "github";
                       owner, owner] name;
          format_refs ~owner ~name refs
        ] in
      Server.respond_string ~status:`OK ~body () |> normal_response
  | `GET, ["commit"; hash] ->
    Capability.with_ref (Client.Repo.commit_of_hash repo hash) @@ fun commit ->
    let refs = Client.Commit.refs commit in
    Client.Commit.jobs commit >>!= fun jobs ->
    refs >>!= fun refs ->
    let body = Template.instance [
        breadcrumbs ["github", "github";
                     owner, owner;
                     name, name] (short_hash hash);
        link_github_refs ~owner ~name refs;
        link_jobs ~owner ~name ~hash jobs;
      ] in
    Server.respond_string ~status:`OK ~body () |> normal_response
  | `GET, ["commit"; hash; "variant"; variant] ->
    Capability.with_ref (Client.Repo.commit_of_hash repo hash) @@ fun commit ->
    let refs = Client.Commit.refs commit in
    let jobs = Client.Commit.jobs commit in
    Capability.with_ref (Client.Commit.job_of_variant commit variant) @@ fun job ->
    let status = Current_rpc.Job.status job in
    Current_rpc.Job.log job ~start:0L >>!= fun chunk ->
    (* (these will have resolved by now) *)
    refs >>!= fun refs ->
    jobs >>!= fun jobs ->
    status >>!= fun status ->
    let headers =
      (* Otherwise, an nginx reverse proxy will wait for the whole log before sending anything. *)
      Cohttp.Header.init_with "X-Accel-Buffering" "no"
    in
    let res = Cohttp.Response.make ~status:`OK ~flush:true ~encoding:Cohttp.Transfer.Chunked ~headers () in
    let write _ic oc =
      let flush = Cohttp.Response.flush res in
      let writer = Transfer_IO.make_writer ~flush Cohttp.Transfer.Chunked oc in
      Lwt.finalize
        (fun () ->
           stream_logs job ~owner ~name ~refs ~hash ~jobs ~variant ~status chunk writer >>= fun () ->
           Server.IO.write oc "0\r\n\r\n"
        )
        (fun () ->
           Capability.dec_ref job;
           Lwt.return_unit
        )
    in
    Capability.inc_ref job;
    Lwt.return (`Expert (res, write))
  | `POST, ["commit"; hash; "variant"; variant; "rebuild"] ->
    Capability.with_ref (Client.Repo.commit_of_hash repo hash) @@ fun commit ->
    Capability.with_ref (Client.Commit.job_of_variant commit variant) @@ fun job ->
    Capability.with_ref (Current_rpc.Job.rebuild job) @@ fun new_job ->
    Capability.wait_until_settled new_job >>= fun () ->
    begin match Capability.problem new_job with
      | None ->
        let uri = job_url ~owner ~name ~hash variant |> Uri.of_string in
        Server.respond_redirect ~uri () |> normal_response
      | Some { Capnp_rpc.Exception.reason; _ } ->
        Server.respond_error ~body:reason () |> normal_response
    end
  | _ ->
    Server.respond_not_found () |> normal_response

let format_org org =
  let open Tyxml.Html in
  li [a ~a:[a_href (org_url org)] [txt org]]

let list_orgs ci =
  Client.CI.orgs ci >>!= fun orgs ->
  let body = Template.instance Tyxml.Html.[
      breadcrumbs [] "github";
      ul (List.map format_org orgs)
    ] in
  Server.respond_string ~status:`OK ~body () |> normal_response

let format_repo ~owner name =
  let open Tyxml.Html in
  li [a ~a:[a_href (repo_url ~owner name)] [txt name]]

let list_repos ~owner org =
  Client.Org.repos org >>!= fun repos ->
  let body = Template.instance Tyxml.Html.[
      breadcrumbs ["github", "github"] owner;
      ul (List.map (format_repo ~owner) repos)
    ] in
  Server.respond_string ~status:`OK ~body () |> normal_response

let handle ~backend ~meth path =
  Backend.ci backend >>= fun ci ->
  match meth, path with
  | `GET, [] -> list_orgs ci
  | `GET, [owner] -> Capability.with_ref (Client.CI.org ci owner) @@ list_repos ~owner
  | meth, (owner :: name :: path) ->
    Capability.with_ref (Client.CI.org ci owner) @@ fun org ->
    Capability.with_ref (Client.Org.repo org name) @@ fun repo ->
    repo_handle ~meth ~owner ~name ~repo path
  | _ ->
    Server.respond_not_found () |> normal_response
