module type PAF = sig
  val request :
    ?config:Httpaf.Config.t ->
    ctx:Mimic.ctx ->
    error_handler:
      (Mimic.flow ->
       (Ipaddr.t * int) option ->
       Httpaf.Client_connection.error_handler) ->
    response_handler:
      ((Ipaddr.t * int) option -> Httpaf.Client_connection.response_handler) ->
    Httpaf.Request.t ->
    ([ `write ] Httpaf.Body.t, [> Mimic.error ]) result Lwt.t
end

module Make (Paf : PAF) = struct
  open Paf

  type ctx = Mimic.ctx

  let sexp_of_ctx _ctx = assert false
  let default_ctx = Mimic.empty

  let httpaf_config = Mimic.make ~name:"httpaf-config"

  let error_handler mvar flow edn err =
    Lwt.async @@ fun () -> Lwt_mvar.put mvar (flow, edn, err)

  let response_handler mvar pusher _edn resp body =
    let on_eof () = pusher None in
    let rec on_read buf ~off ~len =
      let str = Bigstringaf.substring buf ~off ~len in
      pusher (Some str) ;
      Httpaf.Body.schedule_read ~on_eof ~on_read body in
    Httpaf.Body.schedule_read ~on_eof ~on_read body ;
    Lwt.async @@ fun () -> Lwt_mvar.put mvar resp

  let rec unroll body stream =
    let open Lwt.Infix in
    Lwt_stream.get stream >>= function
    | Some str -> Httpaf.Body.write_string body str ; unroll body stream
    | None -> Httpaf.Body.close_writer body ; Lwt.return_unit

  let transmit cohttp_body httpaf_body = match cohttp_body with
    | `Empty -> Httpaf.Body.close_writer httpaf_body
    | `String str ->
      Httpaf.Body.write_string httpaf_body str ;
      Httpaf.Body.close_writer httpaf_body
    | `Strings sstr ->
      List.iter (Httpaf.Body.write_string httpaf_body) sstr ;
      Httpaf.Body.close_writer httpaf_body
    | `Stream stream -> Lwt.async @@ fun () -> unroll httpaf_body stream

  exception Internal_server_error
  exception Invalid_response_body_length of Httpaf.Response.t
  exception Malformed_response of string

  let call ?(ctx= default_ctx) ?headers ?body:(cohttp_body= Cohttp_lwt.Body.empty) ?chunked:_ meth uri =
    let config = match Mimic.get httpaf_config ctx with
      | Some config -> config | None -> Httpaf.Config.default in
    let headers = match headers with
      | Some headers -> Httpaf.Headers.of_list (Cohttp.Header.to_list headers)
      | None -> Httpaf.Headers.empty in
    let meth = match meth with
      | #Httpaf.Method.t as meth -> meth
      | #Cohttp.Code.meth as meth -> `Other (Cohttp.Code.string_of_method meth) in
    let req = Httpaf.Request.create ~headers meth (Uri.path uri) in
    let stream, pusher = Lwt_stream.create () in
    let mvar_res = Lwt_mvar.create_empty () in
    let mvar_err = Lwt_mvar.create_empty () in
    let open Lwt.Infix in
    request ~config ~ctx ~error_handler:(error_handler mvar_err) ~response_handler:(response_handler mvar_res pusher) req >>= function
    | Error (#Mimic.error as err) -> Lwt.fail (Failure (Fmt.str "%a" Mimic.pp_error err))
    | Ok httpaf_body ->
      transmit cohttp_body httpaf_body ;
      Lwt.pick
        [ Lwt_mvar.take mvar_res >|= (fun res -> `Response res)
        ; Lwt_mvar.take mvar_err >|= (fun err -> `Error err) ] >>= function
      | `Error (flow, _, `Exn exn) ->
        Mimic.close flow >>= fun () -> Lwt.fail exn
      | `Error (flow, _, `Invalid_response_body_length resp) ->
        Mimic.close flow >>= fun () ->
        Lwt.fail (Invalid_response_body_length resp)
      | `Error (flow, _, `Malformed_response err) ->
        Mimic.close flow >>= fun () ->
        Lwt.fail (Malformed_response err)
      | `Response resp ->
        let version = match resp.Httpaf.Response.version with
          | { Httpaf.Version.major= 1; minor= 0; } -> `HTTP_1_0
          | { major= 1; minor= 1; } -> `HTTP_1_1
          | { major; minor; } -> `Other (Fmt.str "%d.%d" major minor) in
        let status = match (resp.Httpaf.Response.status :> [ Cohttp.Code.status | Httpaf.Status.t ]) with
          | #Cohttp.Code.status as status -> status
          | #Httpaf.Status.t as status -> `Code (Httpaf.Status.to_code status) in
        let encoding = match meth with
          | #Httpaf.Method.standard as meth ->
            ( match Httpaf.Response.body_length ~request_method:meth resp with
              | `Chunked | `Close_delimited -> Cohttp.Transfer.Chunked
              | `Error _err -> raise Internal_server_error
              | `Fixed length -> Cohttp.Transfer.Fixed length )
          | _ -> Cohttp.Transfer.Chunked in
        let headers = Cohttp.Header.of_list (Httpaf.Headers.to_list resp.Httpaf.Response.headers) in
        let resp = Cohttp.Response.make ~version ~status ~encoding ~headers () in
        Lwt.return (resp, `Stream stream)

  open Lwt.Infix

  let head ?ctx ?headers uri = call ?ctx ?headers `HEAD uri >|= fst
  let get ?ctx ?headers uri = call ?ctx ?headers `GET uri
  let delete ?ctx ?body ?chunked ?headers uri = call ?ctx ?body ?chunked ?headers `DELETE uri
  let post ?ctx ?body ?chunked ?headers uri = call ?ctx ?body ?chunked ?headers `POST uri
  let put ?ctx ?body ?chunked ?headers uri = call ?ctx ?body ?chunked ?headers `PUT uri
  let patch ?ctx ?body ?chunked ?headers uri = call ?ctx ?body ?chunked ?headers `PATCH uri
  let post_form ?ctx:_ ?headers:_ ~params:_ _uri = assert false (* TODO *)
  let callv ?ctx:_ _uri _stream = assert false (* TODO *)
end
