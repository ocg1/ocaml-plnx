open Core
open Async

open Bs_devkit
open Plnx

module Yojson_encoding = Json_encoding.Make(Json_repr.Yojson)

open Cohttp_async

exception Client of string
exception Server of string
exception Poloniex of string

module Http_error = struct
  type t =
    | Cohttp of exn
    | Client of string
    | Server of string
    | Poloniex of string
    | Data_encoding of string
    | Data_shape of string

  let poloniex_str msg = Poloniex msg
  let poloniex k =
    Format.kasprintf (fun msg -> Poloniex msg) k

  let poloniex_fail msg = Result.fail (Poloniex msg)

  let poloniex_failf k =
    Format.kasprintf (fun msg -> Result.fail (Poloniex msg)) k

  let data_encoding exn =
    let msg =
      Format.asprintf "%a" (Json_encoding.print_error ?print_unknown:None) exn in
    Result.fail (Data_encoding msg)

  let data_shape msg = Result.fail (Data_shape msg)

  let to_string = function
    | Cohttp exn -> Exn.to_string exn
    | Client msg -> "HTTP Client error: " ^ msg
    | Server msg -> "HTTP Server error: " ^ msg
    | Poloniex msg -> "Poloniex error: " ^ msg
    | Data_encoding msg -> "Data encoding error: " ^ msg
    | Data_shape msg -> "Data_shape error: " ^ msg
end

let safe_get ?buf url =
  let ssl_config = Conduit_async.Ssl.configure ~version:Tlsv1_2 () in
  Monitor.try_with begin fun () ->
    Client.get ~ssl_config url >>= fun (resp, body) ->
    let status_code = Cohttp.Code.code_of_status resp.status in
    Body.to_string body >>| fun body_str ->
    let body_json = Yojson.Safe.from_string ?buf body_str in
    if Cohttp.Code.is_client_error status_code then raise (Client body_str)
    else if Cohttp.Code.is_server_error status_code then raise (Server body_str)
    else match body_json with
      | `Assoc ["error", `String msg] -> raise (Poloniex msg)
      | #Yojson.Safe.json as json -> json
  end >>| Result.map_error ~f:begin function
    | Client str -> Http_error.Client str
    | Server str -> Server str
    | Poloniex str -> Poloniex str
    | exn -> Cohttp exn
  end

let make_sign () =
  let bigbuf = Bigstring.create 1024 in
  fun ~key ~secret ~data ->
    let nonce = Time_ns.(now () |> to_int_ns_since_epoch) / 1_000 in
    let data = ("nonce", [Int.to_string nonce]) :: data in
    let data_str = Uri.encoded_of_query data in
    let prehash = Cstruct.of_string ~allocator:(fun len -> Cstruct.of_bigarray bigbuf ~len) data_str in
    let `Hex signature = Nocrypto.Hash.SHA512.hmac ~key:secret prehash |> Hex.of_cstruct in
    data_str,
    Cohttp.Header.of_list [
      "content-type", "application/x-www-form-urlencoded";
      "Key", key;
      "Sign", signature;
    ]

let sign = make_sign ()

let safe_post ?buf ?log ~key ~secret ~data url =
  let body, headers = sign ~key ~secret ~data in
  let body = Body.of_string body in
  let ssl_config = Conduit_async.Ssl.configure ~version:Tlsv1_2 () in
  Monitor.try_with begin fun () ->
    Client.post ~ssl_config ~headers ~body url >>= fun (resp, body) ->
    let status_code = Cohttp.Code.code_of_status resp.status in
    Body.to_string body >>| fun body_str ->
    Option.iter log ~f:(fun log -> Log.debug log "%s" body_str) ;
    let body_json = Yojson.Safe.from_string ?buf body_str in
    if Cohttp.Code.is_client_error status_code then raise (Client body_str)
    else if Cohttp.Code.is_server_error status_code then raise (Server body_str)
    else match body_json with
      | `Assoc ["error", `String msg] -> raise (Poloniex msg)
      | #Yojson.Safe.json as json -> json
  end >>| Result.map_error ~f:begin function
    | Client str -> Http_error.Client str
    | Server str -> Server str
    | Poloniex str -> Poloniex str
    | exn -> Cohttp exn
  end

  let base_url = Uri.of_string "https://poloniex.com/public"
  let trading_url = Uri.of_string "https://poloniex.com/tradingApi"

  let tickers ?buf () =
    let url = Uri.with_query' base_url ["command", "returnTicker"] in
    safe_get ?buf url >>| Result.bind ~f:begin function
      | `Assoc tickers ->
        begin try
            Ok (List.rev_map tickers ~f:begin fun (symbol, t) ->
                Yojson_encoding.destruct (Ticker.encoding symbol) t
              end)
          with exn -> Http_error.data_encoding exn
        end
      | #Yojson.Safe.json -> Http_error.data_shape "expected object"
    end

  let bids_asks_of_yojson side records =
    List.map records ~f:(function
      | `List [`String price; `Int qty] ->
        DB.{ side ; price = satoshis_of_string price ; qty = qty * 100_000_000 }
      | `List [`String price; `Float qty] ->
        DB.{ side ; price = satoshis_of_string price ; qty = satoshis_int_of_float_exn qty }
      | #Yojson.Safe.json -> invalid_arg "bids_asks_of_yojson")

  let bids_asks_of_yojson side = function
    | `List records -> bids_asks_of_yojson side records
    | #Yojson.Safe.json -> invalid_arg "bids_asks_of_yojson"

  let bids_of_yojson = bids_asks_of_yojson `Buy
  let asks_of_yojson = bids_asks_of_yojson `Sell

  type books = {
    asks: DB.book_entry list;
    bids: DB.book_entry list;
    isFrozen: bool;
    seq: int;
  }

  let books_encoding =
    let open Json_encoding in
    conv
      (fun { asks ; bids ; isFrozen ; seq } ->
         Json_repr.(repr_to_any (module Yojson) `Null),
         Json_repr.(repr_to_any (module Yojson) `Null),
         isFrozen, seq)
      (fun (asks, bids, isFrozen, seq) ->
         let asks = Json_repr.(any_to_repr (module Yojson) asks) |> asks_of_yojson in
         let bids = Json_repr.(any_to_repr (module Yojson) bids) |> bids_of_yojson in
         { asks ; bids ; isFrozen ; seq })
      (obj4
         (req "asks" any_value)
         (req "bids" any_value)
         (req "isFrozen" bool)
         (req "seq" int))

  let books ?buf ?depth symbol =
    let url = Uri.with_query' base_url @@ List.filter_opt [
        Some ("command", "returnOrderBook");
        Some ("currencyPair", symbol);
        Option.map depth ~f:(fun lvls -> "depth", Int.to_string lvls);
      ] in
    safe_get url >>| Result.bind ~f:begin fun json ->
      try
        Ok (Yojson_encoding.destruct books_encoding json)
      with exn -> Http_error.data_encoding exn
    end

  let trades_exn ?log ?start_ts ?end_ts symbol =
    let start_ts_sec = Option.map start_ts ~f:begin fun ts ->
        Time_ns.to_int_ns_since_epoch ts / 1_000_000_000 |> Int.to_string
      end in
    let end_ts_sec = Option.map end_ts ~f:begin fun ts ->
        Time_ns.to_int_ns_since_epoch ts / 1_000_000_000 |> Int.to_string
      end in
    let url = Uri.add_query_params' base_url @@ List.filter_opt Option.[
        some ("command", "returnTradeHistory");
        some ("currencyPair", symbol);
        map start_ts_sec ~f:(fun t -> "start", t);
        map end_ts_sec ~f:(fun t -> "end", t);
      ]
    in
    let decoder = Jsonm.decoder `Manual in
    let fold_trades_exn trades_w (nb_decoded, name, tmp) chunk =
      let chunk_len = String.length chunk in
      let chunk = Caml.Bytes.unsafe_of_string chunk in
      Jsonm.Manual.src decoder chunk 0 chunk_len;
      let rec decode nb_decoded name tmp =
        match Jsonm.decode decoder with
        | `Error err ->
          let err_str = Format.asprintf "%a" Jsonm.pp_error err in
          Option.iter log ~f:(fun log -> Log.error log "%s" err_str) ;
          failwith err_str
        | `Lexeme (`Float f) -> decode nb_decoded "" ((name, `Int (Float.to_int f))::tmp)
        | `Lexeme (`String s) -> decode nb_decoded "" ((name, `String s)::tmp)
        | `Lexeme (`Name name) -> decode nb_decoded name tmp
        | `Lexeme `Oe ->
          let trade = Yojson_encoding.destruct Trade.encoding (`Assoc tmp) in
          Pipe.write trades_w trade >>= fun () ->
          decode (succ nb_decoded) "" []
        | `Lexeme `Ae -> return (nb_decoded, name, tmp)
        | `Lexeme #Jsonm.lexeme -> decode nb_decoded name tmp
        | `Await -> return (nb_decoded, name, tmp)
        | `End -> return (nb_decoded, name, tmp)
      in
      decode nb_decoded name tmp
    in
    Option.iter log ~f:(fun log -> Log.debug log "GET %s" (Uri.to_string url)) ;
    Client.get url >>| fun (resp, body) ->
    Pipe.create_reader ~close_on_exception:false begin fun w ->
      let body_pipe = Body.to_pipe body in
      Deferred.ignore @@ Pipe.fold body_pipe
        ~init:(0, "", [])
        ~f:(fold_trades_exn w)
    end

  let all_trades_exn
      ?log
      ?(wait=Time_ns.Span.min_value)
      ?(start_ts=Time_ns.epoch)
      ?(end_ts=Time_ns.now ())
      symbol =
    let rec inner cur_end_ts w =
      trades_exn ?log ~end_ts:cur_end_ts symbol >>= fun trades ->
      let oldest_ts = ref @@ Time_ns.max_value in
      Pipe.transfer trades w ~f:(fun t -> oldest_ts := t.ts; t) >>= fun () ->
      if !oldest_ts = Time_ns.max_value || Time_ns.(!oldest_ts < start_ts) then
        (Pipe.close w; Deferred.unit)
      else
      Clock_ns.after wait >>= fun () ->
      inner Time_ns.(sub !oldest_ts @@ Span.of_int_sec 1) w
    in
    Pipe.create_reader ~close_on_exception:false (inner end_ts)

module Currency = struct
  type t = {
    id: int;
    name: string;
    txFee: string;
    minConf: int;
    depositAddress: string option;
    disabled: int;
    delisted: int;
    frozen: int;
  } [@@deriving sexp]

  let encoding =
    let open Json_encoding in
    conv
      (fun { id ; name ; txFee ; minConf ; depositAddress ;
             disabled ; delisted ; frozen } ->
        id, name, txFee, minConf, depositAddress, disabled, delisted, frozen)
      (fun (id, name, txFee, minConf, depositAddress, disabled, delisted, frozen) ->
         { id ; name ; txFee ; minConf ; depositAddress ;
           disabled ; delisted ; frozen })
      (obj8
         (req "id" int)
         (req "name" string)
         (req "txFee" string)
         (req "minConf" int)
         (req "depositAddress" (option string))
         (req "disabled" int)
         (req "delisted" int)
         (req "frozen" int))
end

let currencies ?buf () =
  let url = Uri.add_query_params' base_url ["command", "returnCurrencies"] in
  safe_get ?buf url >>| Result.bind ~f:begin function
    | `Assoc currs ->
      begin try
          Ok (List.map currs ~f:begin fun (code, obj) ->
              code, (Yojson_encoding.destruct Currency.encoding obj)
            end)
        with exn -> Http_error.data_encoding exn
      end
    | #Yojson.Safe.json -> Result.fail (Http_error.Poloniex "currencies")
  end

let symbols ?buf () =
  let url =
    Uri.with_query' base_url ["command", "returnOrderBook";
                              "currencyPair", "all"; "depth", "0"] in
  safe_get ?buf url >>| Result.bind ~f:begin function
    | `Assoc syms -> Result.return @@ List.rev_map syms ~f:fst
    | #Yojson.Safe.json -> Http_error.poloniex_fail "symbols"
  end

module Balance = struct
  type t = {
    available: float;
    on_orders: float;
    btc_value: float;
  } [@@deriving sexp]

  let encoding =
    let open Json_encoding in
    conv
      (fun _ -> (0., 0., 0.))
      (fun (available, on_orders, btc_value) -> { available ; on_orders ; btc_value })
      (obj3
         (req "available" flstring)
         (req "onOrders" flstring)
         (req "btcValue" flstring))
end

let balances ?buf ?(all=true) ~key ~secret () =
  let data = List.filter_opt [
      Some ("command", ["returnCompleteBalances"]);
      if all then Some ("account", ["all"]) else None
    ] in
  safe_post ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin function
    | `Assoc balances -> begin
        try
          Result.return @@
          List.Assoc.map balances ~f:(Yojson_encoding.destruct Balance.encoding)
        with exn -> Http_error.data_encoding exn
      end
    | #Yojson.Safe.json -> Http_error.poloniex_fail "balances"
  end

module Account = struct
  type t =
    | Exchange
    | Margin
    | Lending [@@deriving sexp]

  let of_string = function
    | "exchange" -> Exchange
    | "margin" -> Margin
    | "lending" -> Lending
    | s -> invalid_argf "account_of_string: %s" s ()

  let to_string = function
    | Exchange -> "exchange"
    | Margin -> "margin"
    | Lending -> "lending"
end

let positive_balances ?buf ~key ~secret () =
  let data = ["command", ["returnAvailableAccountBalances"]] in
  safe_post ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin function
    | `Assoc balances -> begin
        try
          Result.return @@
          List.map balances ~f:begin function
            | account, `Assoc bs ->
              Account.of_string account, List.Assoc.map bs ~f:begin function
                | `String bal -> Float.of_string bal
                | json -> raise Exit
              end
            | account, #Yojson.Safe.json -> raise Exit
          end
        with exn -> Http_error.data_encoding exn
      end
    | #Yojson.Safe.json -> Http_error.data_shape "expected object"
  end

module MarginAccountSummary = struct
  type t = {
    total_value: float ;
    pl: float ;
    lending_fees: float ;
    net_value: float ;
    total_borrowed_value: float ;
    current_margin: float ;
  } [@@deriving sexp]

  let empty = {
    total_value = 0. ;
    pl = 0. ;
    lending_fees = 0. ;
    net_value = 0. ;
    total_borrowed_value = 0. ;
    current_margin = 0.
  }

  let encoding =
    let open Json_encoding in
    conv
      (fun _ -> ("", "", "", "", "", ""))
      (fun (totalValue, pl, lendingFees, netValue,
            totalBorrowedValue, currentMargin) ->
        let total_value = Float.of_string totalValue in
        let pl = Float.of_string pl in
        let lending_fees = Float.of_string lendingFees in
        let net_value = Float.of_string netValue in
        let total_borrowed_value = Float.of_string totalBorrowedValue in
        let current_margin = Float.of_string currentMargin in
        { total_value ; pl ; lending_fees ; net_value ;
          total_borrowed_value ; current_margin })
      (obj6
         (req "totalValue" string)
         (req "pl" string)
         (req "lendingFees" string)
         (req "netValue" string)
         (req "totalBorrowedValue" string)
         (req "currentMargin" string))
end

let margin_account_summary ?buf ~key ~secret () =
  let data = ["command", ["returnMarginAccountSummary"]] in
  safe_post ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin fun json ->
    Ok (Yojson_encoding.destruct MarginAccountSummary.encoding json)
  end

let or_error encoding =
  let open Json_encoding in
  let error_encoding =
    conv
      (fun _ -> ((), ""))
      (fun ((), error) -> Http_error.Poloniex error)
      (merge_objs unit (obj1 (req "error" string))) in
  union [
    case error_encoding
      (function Ok _ -> None | Error msg -> Some msg)
      (fun msg -> Error msg) ;
    case encoding
      (function Ok v -> Some v | Error _ -> None)
      (fun v -> Ok v)
  ]

module OrderResponse = struct
  type t = {
    id : int ;
    trades : Trade.t list ;
    amount_unfilled : float ;
  } [@@deriving sexp]

  let encoding =
    let open Json_encoding in
    conv
      (fun _ -> ((), ("", [], None)))
      (fun ((), (id, trades, amount_unfilled)) ->
         let id = Int.of_string id in
         let amount_unfilled =  Option.value amount_unfilled ~default:0. in
         { id ; trades ; amount_unfilled })
      (merge_objs unit
         (obj3
            (req "orderNumber" string)
            (dft "resultingTrades" (list Trade.encoding) [])
            (opt "amountUnfilled" flstring)))
end

let order ?buf ?tif ?(post_only=false)
    ~key ~secret ~side ~symbol ~price ~qty () =
  let data = List.filter_opt [
      Some ("command", [match side with `Buy -> "buy" | `Sell -> "sell" ]);
      Some ("currencyPair", [symbol]);
      Some ("rate", [Float.to_string price]);
      Some ("amount", [Float.to_string qty]);
      (match tif with
       | Some `Fill_or_kill -> Some ("fillOrKill", ["1"])
       | Some `Immediate_or_cancel -> Some ("immediateOrCancel", ["1"])
       | _ -> None);
      (if post_only then Some ("postOnly", ["1"]) else None)
    ] in
  safe_post ?buf ~key ~secret ~data trading_url >>|
  Result.bind ~f:(Yojson_encoding.destruct (or_error OrderResponse.encoding))

let cancel_order ?buf ~key ~secret ~order_id () =
  let response_encoding = or_error Json_encoding.unit in
  let data = [
    "command", ["cancelOrder"];
    "orderNumber", [Int.to_string order_id];
  ] in
  safe_post ?buf ~key ~secret ~data trading_url >>|
  Result.bind ~f:(Yojson_encoding.destruct response_encoding)

let modify_order ?buf ?qty ~key ~secret ~price ~order_id () =
  let data = List.filter_opt [
      Some ("command", ["moveOrder"]);
      Some ("orderNumber", [Int.to_string order_id]);
      Some ("rate", [Float.to_string price]);
      Option.map qty ~f:(fun amount -> "amount", [Float.to_string amount])
    ] in
  safe_post ?buf ~key ~secret ~data trading_url >>|
  Result.bind ~f:(Yojson_encoding.destruct (or_error OrderResponse.encoding))

let margin_order
    ?buf
    ?tif
    ?(post_only=false)
    ?max_lending_rate
    ~key ~secret ~side ~symbol ~price ~qty () =
  let data = List.filter_opt [
      Some ("command", [match side with `Buy -> "marginBuy" | `Sell -> "marginSell" ]);
      Some ("currencyPair", [symbol]);
      Some ("rate", [Float.to_string price]);
      Some ("amount", [Float.to_string qty]);
      Option.map max_lending_rate ~f:(fun r -> "lendingRate", [Float.to_string r]);
      (match tif with
       | Some `Fill_or_kill -> Some ("fillOrKill", ["1"])
       | Some `Immediate_or_cancel -> Some ("immediateOrCancel", ["1"])
       | _ -> None);
      (if post_only then Some ("postOnly", ["1"]) else None)
    ] in
  safe_post ?buf ~key ~secret ~data trading_url >>|
  Result.bind ~f:(Yojson_encoding.destruct (or_error OrderResponse.encoding))

(*   let close_position ?buf ~key ~secret symbol = *)
(*     let data = [ *)
(*       "command", ["closeMarginPosition"]; *)
(*       "currencyPair", [symbol]; *)
(*     ] *)
(*     in *)
(*     let data_str, headers = sign ~key ~secret ~data in *)
(*     Monitor.try_with_or_error begin fun () -> *)
(*       Client.post ~body:(Body.of_string data_str) ~headers trading_uri >>= fun (resp, body) -> *)
(*       Body.to_string body >>| fun body_str -> *)
(*       let resp = Yojson.Safe.from_string ?buf body_str in *)
(*       match order_response_raw_of_yojson resp with *)
(*       | Ok resp -> order_response_of_raw resp |> Result.ok_or_failwith *)
(*       | Error _ -> failwith body_str *)
(*     end *)

module OpenOrders = struct
  module T = struct
    type t = {
      id: int ;
      ts: Time_ns.t ;
      side: side ;
      price: float ;
      starting_qty: float ;
      qty: float ;
      margin: int ;
    } [@@deriving sexp]

    let compare t t' = Int.compare t.id t'.id
  end
  include T
  module Set = Set.Make(T)

  let encoding =
    let open Json_encoding in
    conv
      (fun { id ; ts ; side ; price ; starting_qty ; qty ; margin } ->
         ("", "", "", "", "", "", "", 0))
      (fun (orderNumber, typ, rate, startingAmount, amount, total, date, margin) ->
         let id = Int.of_string orderNumber in
         let side = Side.of_string typ in
         let price = Float.of_string rate in
         let qty = Float.of_string amount in
         let starting_qty = Float.of_string startingAmount in
         let ts = Time_ns.of_string (date ^ "Z") in
         let margin = margin in
         { id ; ts ; side ; price ; starting_qty ; qty ; margin })
      (obj8
         (req "orderNumber" string)
         (req "type" string)
         (req "rate" string)
         (req "startingAmount" string)
         (req "amount" string)
         (req "total" string)
         (req "date" string)
         (req "margin" int))
end

let open_orders ?buf ?(symbol="all") ~key ~secret () =
  let data = [
    "command", ["returnOpenOrders"];
    "currencyPair", [symbol];
  ] in
  let map_f = Yojson_encoding.destruct OpenOrders.encoding in
  safe_post ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin function
    | `List oos ->
      Result.return [symbol, List.map oos ~f:map_f]
    | `Assoc oo_assoc -> begin
        try
          Result.return @@
          List.Assoc.map oo_assoc ~f:begin function
            | `List oos -> List.map oos ~f:map_f
            | #Yojson.Safe.json -> raise Exit
          end
        with exn -> Http_error.data_encoding exn
      end
    | #Yojson.Safe.json -> Http_error.data_shape "expected object"
  end

module TradeHistory = struct
  type trade_category =
    | Exchange
    | Margin
    | Settlement [@@deriving sexp]

  let trade_category_of_string = function
  | "exchange" -> Exchange
  | "marginTrade" -> Margin
  | "settlement" -> Settlement
  | s -> invalid_argf "trade_category_of_string: %s" s ()

  module T = struct
    type t = {
      gid: int;
      id: int;
      ts: Time_ns.t;
      price: float ;
      qty: float ;
      fee: float ;
      order_id: int;
      side: side;
      category: trade_category
    } [@@deriving sexp]

    let compare t t' = Int.compare t.id t'.id
  end
  include T
  module Set = Set.Make(T)

  let encoding =
    let open Json_encoding in
    conv
      (fun _ -> (0, "", "", "", "", "", "", "", "", ""))
      (fun (globalTradeID, tradeID, date, rate, amount,
            total, fee, orderNumber, typ, category) ->
        let id = Int.of_string tradeID in
        let ts = Time_ns.of_string @@ date ^ "Z" in
        let price = Float.of_string rate in
        let qty = Float.of_string amount in
        let fee = Float.of_string fee in
        let order_id = Int.of_string orderNumber in
        let side = Side.of_string typ in
        let category = trade_category_of_string category in
        { gid = globalTradeID ; id ; ts ; price ; qty ; fee ; order_id ; side ; category })
      (obj10
         (req "globalTradeID" int)
         (req "tradeID" string)
         (req "date" string)
         (req "rate" string)
         (req "amount" string)
         (req "total" string)
         (req "fee" string)
         (req "orderNumber" string)
         (req "type" string)
         (req "category" string))
end

let trade_history ?buf ?(symbol="all") ?start ?stop ~key ~secret () =
  let data = List.filter_opt [
      Some ("command", ["returnTradeHistory"]);
      Some ("currencyPair", [symbol]);
      Option.map start ~f:begin fun ts ->
        "start", [Int.to_string @@ Time_ns.to_int_ns_since_epoch ts / 1_000_000_000]
      end ;
      Option.map stop ~f:begin fun ts ->
        "end", [Int.to_string @@ Time_ns.to_int_ns_since_epoch ts / 1_000_000_000]
      end ;
    ] in
  let map_f = Yojson_encoding.destruct TradeHistory.encoding in
  safe_post ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin function
    | `List ths -> Result.return @@ [symbol, List.map ths ~f:map_f]
    | `Assoc oo_assoc ->
      begin
        try
          Result.return @@ List.Assoc.map oo_assoc ~f:begin function
            | `List oos -> List.map oos ~f:map_f
            | #Yojson.Safe.json -> raise Exit
          end
        with exn -> Http_error.data_encoding exn
      end
    | #Yojson.Safe.json -> Http_error.data_shape "expected object"
  end

module MarginPosition = struct
  type t = {
    price: float ;
    qty: float ;
    total: float ;
    pl: float ;
    lending_fees: float ;
    side: side ;
  } [@@deriving sexp]

  type side = Long | Short | Flat

  let side_encoding =
    let open Json_encoding in
    string_enum [
      "long", Long ;
      "short", Short ;
      "none", Flat ;
    ]

  let position_encoding =
    let open Json_encoding in
    conv
      (fun _ -> ((), (0., 0., 0., 0., 0., Flat)))
      (fun ((), (price, qty, total, pl, lending_fees, side)) ->
         match side with
         | Flat -> None
         | Long ->
           Some { price ; qty ; total ; pl ; lending_fees ; side = `Buy }
         | Short ->
           Some { price ; qty ; total ; pl ; lending_fees ; side = `Sell })
      (merge_objs unit (obj6
         (req "basePrice" flstring)
         (req "amount" flstring)
         (req "total" flstring)
         (req "pl" flstring)
         (req "lendingFees" flstring)
         (req "type" side_encoding)))
end

let margin_positions ?log ?buf ~key ~secret () =
  let data = ["command", ["getMarginPosition"]; "currencyPair", ["all"]] in
  let destruct = Yojson_encoding.destruct MarginPosition.position_encoding in
  safe_post ?log ?buf ~key ~secret ~data trading_url >>| Result.bind ~f:begin function
    | `Assoc ps_assoc ->
      Ok (List.map ps_assoc ~f:(fun (symbol, p) -> symbol, destruct p))
    | #Yojson.Safe.json -> Http_error.data_shape "expected object"
  end
