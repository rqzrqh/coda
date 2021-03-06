open Core
open Async
open Signature_lib
open Coda_base

module Client = Graphql_lib.Client.Make (struct
  let preprocess_variables_string = Fn.id

  let headers = String.Map.empty
end)

module Args = struct
  open Command.Param

  let zip2 = map2 ~f:(fun arg1 arg2 -> (arg1, arg2))

  let zip3 = map3 ~f:(fun arg1 arg2 arg3 -> (arg1, arg2, arg3))

  let zip4 arg1 arg2 arg3 arg4 =
    return (fun a b c d -> (a, b, c, d)) <*> arg1 <*> arg2 <*> arg3 <*> arg4

  let zip5 arg1 arg2 arg3 arg4 arg5 =
    return (fun a b c d e -> (a, b, c, d, e))
    <*> arg1 <*> arg2 <*> arg3 <*> arg4 <*> arg5

  let zip6 arg1 arg2 arg3 arg4 arg5 arg6 =
    return (fun a b c d e f -> (a, b, c, d, e, f))
    <*> arg1 <*> arg2 <*> arg3 <*> arg4 <*> arg5 <*> arg6

  let zip7 arg1 arg2 arg3 arg4 arg5 arg6 arg7 =
    return (fun a b c d e f g -> (a, b, c, d, e, f, g))
    <*> arg1 <*> arg2 <*> arg3 <*> arg4 <*> arg5 <*> arg6 <*> arg7
end

let or_error_str ~f_ok ~error = function
  | Ok x ->
      f_ok x
  | Error e ->
      sprintf "%s\n%s\n" error (Error.to_string_hum e)

let stop_daemon =
  let open Deferred.Let_syntax in
  let open Daemon_rpcs in
  let open Command.Param in
  Command.async ~summary:"Stop the daemon"
    (Cli_lib.Background_daemon.rpc_init (return ()) ~f:(fun port () ->
         let%map res = Daemon_rpcs.Client.dispatch Stop_daemon.rpc () port in
         printf "%s"
           (or_error_str res
              ~f_ok:(fun _ -> "Daemon stopping\n")
              ~error:"Daemon likely stopped") ))

let get_balance_graphql =
  let open Command.Param in
  let pk_flag =
    flag "public-key"
      ~doc:"KEY Public key for which you want to check the balance"
      (required Cli_lib.Arg_type.public_key_compressed)
  in
  Command.async ~summary:"Get balance associated with a public key"
    (Cli_lib.Background_daemon.graphql_init pk_flag
       ~f:(fun graphql_endpoint public_key ->
         let%map response =
           Graphql_client.query_exn
             (Graphql_queries.Get_tracked_account.make
                ~public_key:(Graphql_client.Encoders.public_key public_key)
                ())
             graphql_endpoint
         in
         match response#account with
         | Some account ->
             printf "Balance: %s coda\n"
               (Currency.Balance.to_formatted_string (account#balance)#total)
         | None ->
             printf "There are no funds in this account\n" ))

let print_trust_status status json =
  if json then
    printf "%s\n"
      (Yojson.Safe.to_string (Trust_system.Peer_status.to_yojson status))
  else
    let ban_status =
      match status.banned with
      | Unbanned ->
          "Unbanned"
      | Banned_until tm ->
          sprintf "Banned_until %s" (Time.to_string_abs tm ~zone:Time.Zone.utc)
    in
    printf "%0.04f, %s\n" status.trust ban_status

let round_trust_score trust_status =
  let open Trust_system.Peer_status in
  let trust = Float.round_decimal trust_status.trust ~decimal_digits:4 in
  {trust_status with trust}

let get_trust_status =
  let open Command.Param in
  let open Deferred.Let_syntax in
  let address_flag =
    flag "ip-address"
      ~doc:
        "IP An IPv4 or IPv6 address for which you want to query the trust \
         status"
      (required Cli_lib.Arg_type.ip_address)
  in
  let json_flag = Cli_lib.Flag.json in
  let flags = Args.zip2 address_flag json_flag in
  Command.async ~summary:"Get the trust status associated with an IP address"
    (Cli_lib.Background_daemon.rpc_init flags
       ~f:(fun port (ip_address, json) ->
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Get_trust_status.rpc
             ip_address port
         with
         | Ok status ->
             print_trust_status (round_trust_score status) json
         | Error e ->
             printf "Failed to get trust status %s\n" (Error.to_string_hum e)
     ))

let ip_trust_statuses_to_yojson ip_trust_statuses =
  let items =
    List.map ip_trust_statuses ~f:(fun (ip_addr, status) ->
        `Assoc
          [ ("ip", `String (Unix.Inet_addr.to_string ip_addr))
          ; ("status", Trust_system.Peer_status.to_yojson status) ] )
  in
  `List items

let print_ip_trust_statuses ip_statuses json =
  if json then
    printf "%s\n"
      (Yojson.Safe.to_string @@ ip_trust_statuses_to_yojson ip_statuses)
  else
    List.iter ip_statuses ~f:(fun (ip_addr, status) ->
        printf "%s : " (Unix.Inet_addr.to_string ip_addr) ;
        print_trust_status status false )

let get_trust_status_all =
  let open Command.Param in
  let open Deferred.Let_syntax in
  let nonzero_flag =
    flag "nonzero-only" no_arg
      ~doc:"Only show trust statuses whose trust score is nonzero"
  in
  let json_flag = Cli_lib.Flag.json in
  let flags = Args.zip2 nonzero_flag json_flag in
  Command.async
    ~summary:"Get trust statuses for all peers known to the trust system"
    (Cli_lib.Background_daemon.rpc_init flags ~f:(fun port (nonzero, json) ->
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Get_trust_status_all.rpc ()
             port
         with
         | Ok ip_trust_statuses ->
             (* always round the trust scores for display *)
             let ip_rounded_trust_statuses =
               List.map ip_trust_statuses ~f:(fun (ip_addr, status) ->
                   (ip_addr, round_trust_score status) )
             in
             let filtered_ip_trust_statuses =
               if nonzero then
                 List.filter ip_rounded_trust_statuses
                   ~f:(fun (_ip_addr, status) ->
                     not Float.(equal status.trust zero) )
               else ip_rounded_trust_statuses
             in
             print_ip_trust_statuses filtered_ip_trust_statuses json
         | Error e ->
             printf "Failed to get trust statuses %s\n" (Error.to_string_hum e)
     ))

let reset_trust_status =
  let open Command.Param in
  let open Deferred.Let_syntax in
  let address_flag =
    flag "ip-address"
      ~doc:
        "IP An IPv4 or IPv6 address for which you want to reset the trust \
         status"
      (required Cli_lib.Arg_type.ip_address)
  in
  let json_flag = Cli_lib.Flag.json in
  let flags = Args.zip2 address_flag json_flag in
  Command.async ~summary:"Reset the trust status associated with an IP address"
    (Cli_lib.Background_daemon.rpc_init flags
       ~f:(fun port (ip_address, json) ->
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Reset_trust_status.rpc
             ip_address port
         with
         | Ok status ->
             print_trust_status status json
         | Error e ->
             printf "Failed to reset trust status %s\n" (Error.to_string_hum e)
     ))

let get_public_keys =
  let open Daemon_rpcs in
  let open Command.Param in
  let with_details_flag =
    flag "with-details" no_arg
      ~doc:"Show extra details (eg. balance, nonce) in addition to public keys"
  in
  let error_ctx = "Failed to get public-keys" in
  Command.async ~summary:"Get public keys"
    (Cli_lib.Background_daemon.rpc_init
       (Args.zip2 with_details_flag Cli_lib.Flag.json)
       ~f:(fun port (is_balance_included, json) ->
         if is_balance_included then
           Daemon_rpcs.Client.dispatch_pretty_message ~json
             ~join_error:Or_error.join ~error_ctx
             (module Cli_lib.Render.Public_key_with_details)
             Get_public_keys_with_details.rpc () port
         else
           Daemon_rpcs.Client.dispatch_pretty_message ~json
             ~join_error:Or_error.join ~error_ctx
             (module Cli_lib.Render.String_list_formatter)
             Get_public_keys.rpc () port ))

let generate_receipt =
  let open Daemon_rpcs in
  let open Command.Param in
  let open Cli_lib.Arg_type in
  let receipt_hash_flag =
    flag "receipt-chain-hash"
      ~doc:
        "RECEIPTHASH Receipt-chain-hash of the payment that you want to\n\
        \        generate a receipt for"
      (required receipt_chain_hash)
  in
  let address_flag =
    flag "address" ~doc:"PUBLICKEY Public-key address of sender"
      (required public_key_compressed)
  in
  let token_flag =
    (*flag "token" ~doc:"TOKEN_ID The token ID for the account"
      (optional_with_default Token_id.default Cli_lib.Arg_type.token_id)*)
    Command.Param.return Token_id.default
  in
  Command.async ~summary:"Generate a receipt for a sent payment"
    (Cli_lib.Background_daemon.rpc_init
       (Args.zip3 receipt_hash_flag address_flag token_flag)
       ~f:(fun port (receipt_chain_hash, pk, token_id) ->
         let account_id = Account_id.create pk token_id in
         Daemon_rpcs.Client.dispatch_with_message Prove_receipt.rpc
           (receipt_chain_hash, account_id)
           port ~success:Cli_lib.Render.Prove_receipt.to_text
           ~error:Error.to_string_hum ~join_error:Or_error.join ))

let read_json filepath ~flag =
  let%map res =
    Deferred.Or_error.try_with (fun () ->
        let%map json_contents = Reader.file_contents filepath in
        Ok (Yojson.Safe.from_string json_contents) )
  in
  match res with
  | Ok c ->
      c
  | Error e ->
      Or_error.errorf "Could not read %s at %s\n%s" flag filepath
        (Error.to_string_hum e)

let verify_receipt =
  let open Deferred.Let_syntax in
  let open Daemon_rpcs in
  let open Command.Param in
  let open Cli_lib.Arg_type in
  let proof_path_flag =
    flag "proof-path"
      ~doc:"PROOFFILE File to read json version of payment receipt"
      (required string)
  in
  let payment_path_flag =
    flag "payment-path"
      ~doc:"PAYMENTPATH File to read json version of verifying payment"
      (required string)
  in
  let address_flag =
    flag "address" ~doc:"PUBLICKEY Public-key address of sender"
      (required public_key_compressed)
  in
  let token_flag =
    (*flag "token" ~doc:"TOKEN_ID The token ID for the account"
      (optional_with_default Token_id.default Cli_lib.Arg_type.token_id)*)
    Command.Param.return Token_id.default
  in
  Command.async ~summary:"Verify a receipt of a sent payment"
    (Cli_lib.Background_daemon.rpc_init
       (Args.zip4 payment_path_flag proof_path_flag address_flag token_flag)
       ~f:(fun port (payment_path, proof_path, pk, token_id) ->
         let account_id = Account_id.create pk token_id in
         let dispatch_result =
           let open Deferred.Or_error.Let_syntax in
           let%bind payment_json =
             read_json payment_path ~flag:"payment-path"
           in
           let%bind proof_json = read_json proof_path ~flag:"proof-path" in
           let to_deferred_or_error result ~error =
             Result.map_error result ~f:(fun s ->
                 Error.of_string (sprintf "%s: %s" error s) )
             |> Deferred.return
           in
           let%bind payment =
             User_command.of_yojson payment_json
             |> to_deferred_or_error
                  ~error:
                    (sprintf "Payment file %s has invalid json format"
                       payment_path)
           and proof =
             [%of_yojson: Receipt.Chain_hash.t * User_command.t list]
               proof_json
             |> to_deferred_or_error
                  ~error:
                    (sprintf "Proof file %s has invalid json format" proof_path)
           in
           Daemon_rpcs.Client.dispatch Verify_proof.rpc
             (account_id, payment, proof)
             port
         in
         match%map dispatch_result with
         | Ok (Ok ()) ->
             printf "Payment is valid on the existing blockchain!\n"
         | Error e | Ok (Error e) ->
             eprintf "Error verifying the receipt: %s\n"
               (Error.to_string_hum e) ))

let get_nonce :
       rpc:(Account_id.t, Account.Nonce.t option Or_error.t) Rpc.Rpc.t
    -> Account_id.t
    -> Host_and_port.t
    -> (Account.Nonce.t, string) Deferred.Result.t =
 fun ~rpc account_id port ->
  let open Deferred.Let_syntax in
  let%map res = Daemon_rpcs.Client.dispatch rpc account_id port in
  match Or_error.join res with
  | Ok (Some n) ->
      Ok n
  | Ok None ->
      Error "No account found at that public_key"
  | Error e ->
      Error (Error.to_string_hum e)

let get_nonce_cmd =
  let open Command.Param in
  (* Ignores deprecation of public_key type for backwards compatibility *)
  let[@warning "-3"] address_flag =
    flag "address" ~doc:"PUBLICKEY Public-key address you want the nonce for"
      (required Cli_lib.Arg_type.public_key_compressed)
  in
  let token_flag =
    (*flag "token" ~doc:"TOKEN_ID The token ID for the account"
      (optional_with_default Token_id.default Cli_lib.Arg_type.token_id)*)
    Command.Param.return Token_id.default
  in
  let flags = Args.zip2 address_flag token_flag in
  Command.async ~summary:"Get the current nonce for an account"
    (Cli_lib.Background_daemon.rpc_init flags ~f:(fun port (pk, token_flag) ->
         let account_id = Account_id.create pk token_flag in
         match%bind
           get_nonce ~rpc:Daemon_rpcs.Get_nonce.rpc account_id port
         with
         | Error e ->
             eprintf "Failed to get nonce\n%s\n" e ;
             exit 2
         | Ok nonce ->
             printf "%s\n" (Account.Nonce.to_string nonce) ;
             exit 0 ))

let status =
  let open Daemon_rpcs in
  let flag = Args.zip2 Cli_lib.Flag.json Cli_lib.Flag.performance in
  Command.async ~summary:"Get running daemon status"
    (Cli_lib.Background_daemon.rpc_init flag
       ~f:(fun port (json, performance) ->
         Daemon_rpcs.Client.dispatch_pretty_message ~json ~join_error:Fn.id
           ~error_ctx:"Failed to get status"
           (module Daemon_rpcs.Types.Status)
           Get_status.rpc
           (if performance then `Performance else `None)
           port ))

let status_clear_hist =
  let open Daemon_rpcs in
  let flag = Args.zip2 Cli_lib.Flag.json Cli_lib.Flag.performance in
  Command.async ~summary:"Clear histograms reported in status"
    (Cli_lib.Background_daemon.rpc_init flag
       ~f:(fun port (json, performance) ->
         Daemon_rpcs.Client.dispatch_pretty_message ~json ~join_error:Fn.id
           ~error_ctx:"Failed to clear histograms reported in status"
           (module Daemon_rpcs.Types.Status)
           Clear_hist_status.rpc
           (if performance then `Performance else `None)
           port ))

let get_nonce_exn ~rpc public_key port =
  match%bind get_nonce ~rpc public_key port with
  | Error e ->
      eprintf "Failed to get nonce\n%s\n" e ;
      exit 3
  | Ok nonce ->
      return nonce

let batch_send_payments =
  let module Payment_info = struct
    type t =
      { receiver: string
      ; amount: Currency.Amount.t
      ; fee: Currency.Fee.t
      ; valid_until: Coda_numbers.Global_slot.t sexp_option }
    [@@deriving sexp]
  end in
  let payment_path_flag =
    Command.Param.(anon @@ ("payments-file" %: string))
  in
  let get_infos payments_path =
    match%bind
      Reader.load_sexp payments_path [%of_sexp: Payment_info.t list]
    with
    | Ok x ->
        return x
    | Error _ ->
        let sample_info () : Payment_info.t =
          let keypair = Keypair.create () in
          { Payment_info.receiver=
              Public_key.(
                Compressed.to_base58_check (compress keypair.public_key))
          ; valid_until= Some (Coda_numbers.Global_slot.random ())
          ; amount= Currency.Amount.of_int (Random.int 100)
          ; fee= Currency.Fee.of_int (Random.int 100) }
        in
        eprintf "Could not read payments from %s.\n" payments_path ;
        eprintf
          "The file should be a sexp list of payments with optional expiry \
           slot number \"valid_until\". Here is an example file:\n\
           %s\n"
          (Sexp.to_string_hum
             ([%sexp_of: Payment_info.t list]
                (List.init 3 ~f:(fun _ -> sample_info ())))) ;
        exit 5
  in
  let main port (privkey_path, payments_path) =
    let open Deferred.Let_syntax in
    let%bind keypair = Secrets.Keypair.Terminal_stdin.read_exn privkey_path
    and infos = get_infos payments_path in
    let ts : User_command_input.t list =
      List.map infos ~f:(fun {receiver; valid_until; amount; fee} ->
          let signer_pk = Public_key.compress keypair.public_key in
          User_command_input.create ~signer:signer_pk ~fee
            ~fee_token:Token_id.default (* TODO: Multiple tokens. *)
            ~fee_payer_pk:signer_pk ~memo:User_command_memo.empty
            ~valid_until:
              (Option.value valid_until
                 ~default:Coda_numbers.Global_slot.max_value)
            ~body:
              (Payment
                 { source_pk= signer_pk
                 ; receiver_pk=
                     Public_key.Compressed.of_base58_check_exn receiver
                 ; token_id= Token_id.default
                 ; amount })
            ~sign_choice:(User_command_input.Sign_choice.Keypair keypair) () )
    in
    Daemon_rpcs.Client.dispatch_with_message Daemon_rpcs.Send_user_commands.rpc
      ts port
      ~success:(fun _ -> "Successfully enqueued payments in pool")
      ~error:(fun e ->
        sprintf "Failed to send payments %s" (Error.to_string_hum e) )
      ~join_error:Or_error.join
  in
  Command.async ~summary:"Send multiple payments from a file"
    (Cli_lib.Background_daemon.rpc_init
       (Args.zip2 Cli_lib.Flag.privkey_read_path payment_path_flag)
       ~f:main)

let send_payment_graphql =
  let open Command.Param in
  let open Cli_lib.Arg_type in
  let receiver_flag =
    flag "receiver" ~doc:"PUBLICKEY Public key to which you want to send money"
      (required public_key_compressed)
  in
  let amount_flag =
    flag "amount" ~doc:"VALUE Payment amount you want to send"
      (required txn_amount)
  in
  let args =
    Args.zip3 Cli_lib.Flag.user_command_common receiver_flag amount_flag
  in
  Command.async ~summary:"Send payment to an address"
    (Cli_lib.Background_daemon.graphql_init args
       ~f:(fun graphql_endpoint
          ({Cli_lib.Flag.sender; fee; nonce; memo}, receiver, amount)
          ->
         let%map response =
           Graphql_client.(
             Graphql_client.query_exn
               (Graphql_queries.Send_payment.make
                  ~receiver:(Encoders.public_key receiver)
                  ~sender:(Encoders.public_key sender)
                  ~amount:(Encoders.amount amount) ~fee:(Encoders.fee fee)
                  ?nonce:(Option.map nonce ~f:Encoders.nonce)
                  ?memo ()))
             graphql_endpoint
         in
         printf "Dispatched payment with ID %s\n"
           ((response#sendPayment)#payment)#id ))

let delegate_stake_graphql =
  let open Command.Param in
  let open Cli_lib.Arg_type in
  let receiver_flag =
    flag "receiver"
      ~doc:"PUBLICKEY Public key to which you want to delegate your stake"
      (required public_key_compressed)
  in
  let args = Args.zip2 Cli_lib.Flag.user_command_common receiver_flag in
  Command.async ~summary:"Delegate your stake to another public key"
    (Cli_lib.Background_daemon.graphql_init args
       ~f:(fun graphql_endpoint
          ({Cli_lib.Flag.sender; fee; nonce; memo}, receiver)
          ->
         let%map response =
           Graphql_client.(
             Graphql_client.query_exn
               (Graphql_queries.Send_delegation.make
                  ~receiver:(Encoders.public_key receiver)
                  ~sender:(Encoders.public_key sender)
                  ~fee:(Encoders.fee fee)
                  ?nonce:(Option.map nonce ~f:Encoders.nonce)
                  ?memo ()))
             graphql_endpoint
         in
         printf "Dispatched stake delegation with ID %s\n"
           ((response#sendDelegation)#delegation)#id ))

let cancel_transaction_graphql =
  let txn_id_flag =
    Command.Param.(
      flag "id" ~doc:"ID Transaction ID to be cancelled"
        (required Cli_lib.Arg_type.user_command))
  in
  Command.async
    ~summary:
      "Cancel a transaction -- this submits a replacement transaction with a \
       fee larger than the cancelled transaction."
    (Cli_lib.Background_daemon.graphql_init txn_id_flag
       ~f:(fun graphql_endpoint user_command ->
         let receiver =
           user_command |> User_command.payload |> User_command.Payload.body
           |> User_command.Payload.Body.receiver
         in
         let receiver_pk = Account_id.public_key receiver in
         let cancel_sender = User_command.fee_payer user_command in
         let cancel_sender_pk = Account_id.public_key cancel_sender in
         let open Deferred.Let_syntax in
         let%bind nonce_response =
           let open Graphql_client.Encoders in
           Graphql_client.query_exn
             (Graphql_queries.Get_inferred_nonce.make
                ~public_key:(public_key cancel_sender_pk)
                ())
             graphql_endpoint
         in
         let maybe_inferred_nonce =
           let open Option.Let_syntax in
           let%bind account = nonce_response#account in
           let%map nonce = account#inferredNonce in
           int_of_string nonce
         in
         let cancelled_nonce =
           Coda_numbers.Account_nonce.to_int (User_command.nonce user_command)
         in
         let inferred_nonce =
           Option.value maybe_inferred_nonce ~default:cancelled_nonce
         in
         let cancel_fee =
           let diff =
             Unsigned.UInt64.of_int (inferred_nonce - cancelled_nonce)
           in
           let fee = Currency.Fee.to_uint64 (User_command.fee user_command) in
           let replace_fee =
             Currency.Fee.to_uint64 Network_pool.Indexed_pool.replace_fee
           in
           let open Unsigned.UInt64.Infix in
           (* fee amount "inspired by" network_pool/indexed_pool.ml *)
           Currency.Fee.of_uint64 (fee + (replace_fee * diff))
         in
         printf "Fee to cancel transaction is %s coda.\n"
           (Currency.Fee.to_formatted_string cancel_fee) ;
         let cancel_query =
           let open Graphql_client.Encoders in
           Graphql_queries.Send_payment.make
             ~sender:(public_key cancel_sender_pk)
             ~receiver:(public_key receiver_pk) ~fee:(fee cancel_fee)
             ~amount:(amount Currency.Amount.zero)
             ~nonce:
               (uint32
                  (Coda_numbers.Account_nonce.to_uint32
                     (User_command.nonce user_command)))
             ()
         in
         let%map cancel_response =
           Graphql_client.query_exn cancel_query graphql_endpoint
         in
         printf "🛑 Cancelled transaction! Cancel ID: %s\n"
           ((cancel_response#sendPayment)#payment)#id ))

let get_transaction_status =
  Command.async ~summary:"Get the status of a transaction"
    (Cli_lib.Background_daemon.rpc_init
       Command.Param.(anon @@ ("txn-id" %: string))
       ~f:(fun port serialized_transaction ->
         match User_command.of_base58_check serialized_transaction with
         | Ok user_command ->
             Daemon_rpcs.Client.dispatch_with_message
               Daemon_rpcs.Get_transaction_status.rpc user_command port
               ~success:(fun status ->
                 sprintf !"Transaction status : %s\n"
                 @@ Transaction_status.State.to_string status )
               ~error:(fun e ->
                 sprintf "Failed to get transaction status : %s"
                   (Error.to_string_hum e) )
               ~join_error:Or_error.join
         | Error _e ->
             eprintf "Could not deserialize user command" ;
             exit 16 ))

let wrap_key =
  Command.async ~summary:"Wrap a private key into a private key file"
    (let open Command.Let_syntax in
    let%map_open privkey_path = Cli_lib.Flag.privkey_write_path in
    Cli_lib.Exceptions.handle_nicely
    @@ fun () ->
    let open Deferred.Let_syntax in
    let%bind privkey =
      Secrets.Password.hidden_line_or_env "Private key: " ~env:"CODA_PRIVKEY"
    in
    let pk = Private_key.of_base58_check_exn (Bytes.to_string privkey) in
    let kp = Keypair.of_private_key_exn pk in
    Secrets.Keypair.Terminal_stdin.write_exn kp ~privkey_path)

let dump_keypair =
  Command.async ~summary:"Print out a keypair from a private key file"
    (let open Command.Let_syntax in
    let%map_open privkey_path = Cli_lib.Flag.privkey_read_path in
    Cli_lib.Exceptions.handle_nicely
    @@ fun () ->
    let open Deferred.Let_syntax in
    let%map kp = Secrets.Keypair.Terminal_stdin.read_exn privkey_path in
    printf "Public key: %s\nPrivate key: %s\n"
      ( kp.public_key |> Public_key.compress
      |> Public_key.Compressed.to_base58_check )
      (kp.private_key |> Private_key.to_base58_check))

let dump_ledger =
  let sl_hash_flag =
    Command.Param.(
      flag "staged-ledger-hash (default: hash of best staged ledger)"
        ~doc:"STAGED-LEDGER-HASH Staged ledger hash" (optional string))
  in
  let json_flag = Cli_lib.Flag.json in
  let flags = Args.zip2 sl_hash_flag json_flag in
  Command.async ~summary:"Print the ledger with given Merkle root"
    (Cli_lib.Background_daemon.rpc_init flags ~f:(fun port (sl_hash, json) ->
         (* TODO: allow input in Base58Check format: issue #3036 *)
         let staged_ledger_hash =
           Option.map sl_hash ~f:(fun s ->
               Sexp.of_string_conv_exn s Staged_ledger_hash.Stable.V1.t_of_sexp
           )
         in
         Daemon_rpcs.Client.dispatch Daemon_rpcs.Get_ledger.rpc
           staged_ledger_hash port
         >>| function
         | Error e ->
             Daemon_rpcs.Client.print_rpc_error e
         | Ok (Error e) ->
             printf !"Ledger not found: %s\n" (Error.to_string_hum e)
         | Ok (Ok accounts) ->
             if json then
               List.iter accounts ~f:(fun acct ->
                   printf "%s\n"
                     (Yojson.Safe.to_string
                        (Account.Stable.Latest.to_yojson acct)) )
             else printf !"%{sexp:Account.t list}\n" accounts ))

let constraint_system_digests =
  Command.async ~summary:"Print MD5 digest of each SNARK constraint"
    (Command.Param.return (fun () ->
         let all =
           Transaction_snark.constraint_system_digests ()
           @ Blockchain_snark.Blockchain_transition.constraint_system_digests
               ()
         in
         let all =
           List.sort ~compare:(fun (k1, _) (k2, _) -> String.compare k1 k2) all
         in
         List.iter all ~f:(fun (k, v) -> printf "%s\t%s\n" k (Md5.to_hex v)) ;
         Deferred.unit ))

let snark_job_list =
  let open Deferred.Let_syntax in
  let open Command.Param in
  Command.async
    ~summary:
      "List of snark jobs in JSON format that are yet to be included in the \
       blocks"
    (Cli_lib.Background_daemon.rpc_init (return ()) ~f:(fun port () ->
         match%map
           Daemon_rpcs.Client.dispatch_join_errors
             Daemon_rpcs.Snark_job_list.rpc () port
         with
         | Ok str ->
             printf "%s" str
         | Error e ->
             Daemon_rpcs.Client.print_rpc_error e ))

let snark_pool_list =
  let open Command.Param in
  Command.async ~summary:"List of snark works in the snark pool in JSON format"
    (Cli_lib.Background_daemon.graphql_init (return ())
       ~f:(fun graphql_endpoint () ->
         Deferred.map
           (Graphql_client.query_exn
              (Graphql_queries.Snark_pool.make ())
              graphql_endpoint)
           ~f:(fun response ->
             let lst =
               [%to_yojson: Cli_lib.Graphql_types.Completed_works.t]
                 (Array.to_list
                    (Array.map
                       ~f:(fun w ->
                         { Cli_lib.Graphql_types.Completed_works.Work.work_ids=
                             Array.to_list w#work_ids
                         ; fee= Currency.Fee.of_uint64 w#fee
                         ; prover= w#prover } )
                       response#snarkPool))
             in
             print_string (Yojson.Safe.to_string lst) ) ))

let pooled_user_commands =
  let public_key_flag =
    Command.Param.(
      anon @@ maybe @@ ("public-key" %: Cli_lib.Arg_type.public_key_compressed))
  in
  Command.async
    ~summary:
      "Retrieve all the user commands submitted by the current daemon that \
       are pending inclusion"
    (Cli_lib.Background_daemon.graphql_init public_key_flag
       ~f:(fun graphql_endpoint maybe_public_key ->
         let public_key =
           Yojson.Safe.to_basic
           @@ [%to_yojson: Public_key.Compressed.t option] maybe_public_key
         in
         let graphql =
           Graphql_queries.Pooled_user_commands.make ~public_key ()
         in
         let%map response =
           Graphql_client.query_exn graphql graphql_endpoint
         in
         let json_response : Yojson.Safe.json =
           `List
             ( List.map ~f:Graphql_client.User_command.to_yojson
             @@ Array.to_list response#pooledUserCommands )
         in
         print_string (Yojson.Safe.to_string json_response) ))

let to_signed_fee_exn sign magnitude =
  let sgn = match sign with `PLUS -> Sgn.Pos | `MINUS -> Neg in
  let magnitude = Currency.Fee.of_uint64 magnitude in
  Currency.Fee.Signed.create ~sgn ~magnitude

let pending_snark_work =
  let open Command.Param in
  Command.async
    ~summary:
      "List of snark works in JSON format that are not available in the pool \
       yet"
    (Cli_lib.Background_daemon.graphql_init (return ())
       ~f:(fun graphql_endpoint () ->
         Deferred.map
           (Graphql_client.query_exn
              (Graphql_queries.Pending_snark_work.make ())
              graphql_endpoint)
           ~f:(fun response ->
             let lst =
               [%to_yojson: Cli_lib.Graphql_types.Pending_snark_work.t]
                 (Array.map
                    ~f:(fun bundle ->
                      Array.map bundle#workBundle ~f:(fun w ->
                          let f = w#fee_excess in
                          let hash_of_string =
                            Coda_base.Frozen_ledger_hash.of_string
                          in
                          { Cli_lib.Graphql_types.Pending_snark_work.Work
                            .work_id= w#work_id
                          ; fee_excess=
                              to_signed_fee_exn f#sign f#fee_magnitude
                          ; supply_increase=
                              Currency.Amount.of_uint64 w#supply_increase
                          ; source_ledger_hash=
                              hash_of_string w#source_ledger_hash
                          ; target_ledger_hash=
                              hash_of_string w#target_ledger_hash } ) )
                    response#pendingSnarkWork)
             in
             print_string (Yojson.Safe.to_string lst) ) ))

let start_tracing =
  let open Deferred.Let_syntax in
  let open Command.Param in
  Command.async ~summary:"Start async tracing to $config-directory/$pid.trace"
    (Cli_lib.Background_daemon.rpc_init (return ()) ~f:(fun port () ->
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Start_tracing.rpc () port
         with
         | Ok () ->
             printf "Daemon started tracing!"
         | Error e ->
             Daemon_rpcs.Client.print_rpc_error e ))

let stop_tracing =
  let open Deferred.Let_syntax in
  let open Command.Param in
  Command.async ~summary:"Stop async tracing"
    (Cli_lib.Background_daemon.rpc_init (return ()) ~f:(fun port () ->
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Stop_tracing.rpc () port
         with
         | Ok () ->
             printf "Daemon stopped printing!"
         | Error e ->
             Daemon_rpcs.Client.print_rpc_error e ))

let set_staking_graphql =
  let open Command.Param in
  let open Cli_lib.Arg_type in
  let pk_flag =
    flag "public-key"
      ~doc:"PUBLICKEY Public key of account with which to produce blocks"
      (required public_key_compressed)
  in
  Command.async ~summary:"Start producing blocks"
    (Cli_lib.Background_daemon.graphql_init pk_flag
       ~f:(fun graphql_endpoint public_key ->
         let print_message msg arr =
           if not (Array.is_empty arr) then
             printf "%s: %s\n" msg
               (String.concat_array ~sep:", "
                  (Array.map ~f:Public_key.Compressed.to_base58_check arr))
         in
         let%map result =
           Graphql_client.(
             Graphql_client.query_exn
               (Graphql_queries.Set_staking.make
                  ~public_key:(Encoders.public_key public_key)
                  ()))
             graphql_endpoint
         in
         print_message "Stopped staking with" (result#setStaking)#lastStaking ;
         print_message
           "❌ Failed to start staking with keys (try `coda accounts unlock` \
            first)"
           (result#setStaking)#lockedPublicKeys ;
         print_message "Started staking with"
           (result#setStaking)#currentStakingKeys ))

let set_snark_worker =
  let open Command.Param in
  let public_key_flag =
    flag "address"
      ~doc:
        "PUBLICKEY Public-key address you wish to start snark-working on; \
         null to stop doing any snark work"
      (optional Cli_lib.Arg_type.public_key_compressed)
  in
  Command.async
    ~summary:"Set key you wish to snark work with or disable snark working"
    (Cli_lib.Background_daemon.graphql_init public_key_flag
       ~f:(fun graphql_endpoint optional_public_key ->
         let graphql =
           Graphql_queries.Set_snark_worker.make
             ~public_key:
               Graphql_client.Encoders.(
                 optional optional_public_key ~f:public_key)
             ()
         in
         Deferred.map (Graphql_client.query_exn graphql graphql_endpoint)
           ~f:(fun response ->
             ( match optional_public_key with
             | Some public_key ->
                 printf
                   !"New snark worker public key : %s\n"
                   (Public_key.Compressed.to_base58_check public_key)
             | None ->
                 printf "Will stop doing snark work\n" ) ;
             printf "Previous snark worker public key : %s\n"
               (Option.value_map (response#setSnarkWorker)#lastSnarkWorker
                  ~default:"None" ~f:Public_key.Compressed.to_base58_check) )
     ))

let set_snark_work_fee =
  Command.async ~summary:"Set fee reward for doing transaction snark work"
  @@ Cli_lib.Background_daemon.graphql_init
       Command.Param.(anon @@ ("fee" %: Cli_lib.Arg_type.txn_fee))
       ~f:(fun graphql_endpoint fee ->
         let graphql =
           Graphql_queries.Set_snark_work_fee.make
             ~fee:(Graphql_client.Encoders.uint64 @@ Currency.Fee.to_uint64 fee)
             ()
         in
         Deferred.map (Graphql_client.query_exn graphql graphql_endpoint)
           ~f:(fun response ->
             printf
               !"Updated snark work fee: %i\nOld snark work fee: %i\n"
               (Currency.Fee.to_int fee)
               (Unsigned.UInt64.to_int (response#setSnarkWorkFee)#lastFee) ) )

let import_key =
  let privkey_path = Cli_lib.Flag.privkey_read_path in
  let conf_dir = Cli_lib.Flag.conf_dir in
  let flags = Args.zip2 privkey_path conf_dir in
  Command.async
    ~summary:
      "Import a password protected private key to be tracked by the daemon.\n\
       Set CODA_PRIVKEY_PASS environment variable to use non-interactively \
       (key will be imported using the same password)."
    (Cli_lib.Background_daemon.graphql_init flags
       ~f:(fun graphql_endpoint (privkey_path, conf_dir) ->
         let open Deferred.Let_syntax in
         let%bind home = Sys.home_directory () in
         let conf_dir =
           Option.value
             ~default:(home ^/ Cli_lib.Default.conf_dir_name)
             conf_dir
         in
         let wallets_disk_location = conf_dir ^/ "wallets" in
         let%bind ({Keypair.public_key; _} as keypair) =
           Secrets.Keypair.Terminal_stdin.read_exn privkey_path
         in
         let pk = Public_key.compress public_key in
         let%bind wallets =
           Secrets.Wallets.load ~logger:(Logger.create ())
             ~disk_location:wallets_disk_location
         in
         (* Either we already are tracking it *)
         match Secrets.Wallets.check_locked wallets ~needle:pk with
         | Some _ ->
             printf
               !"Key already present, no need to import : %s\n"
               (Public_key.Compressed.to_base58_check
                  (Public_key.compress public_key)) ;
             Deferred.unit
         | None ->
             (* Or we import it *)
             let%bind _ =
               Secrets.Wallets.import_keypair_terminal_stdin wallets keypair
             in
             (* Attempt to reload, but if you can't connect to daemon, it's ok *)
             let%map _response =
               Graphql_client.query
                 (Graphql_queries.Reload_accounts.make ())
                 graphql_endpoint
             in
             printf
               !"\n😄 Imported account!\nPublic key: %s\n"
               (Public_key.Compressed.to_base58_check
                  (Public_key.compress public_key)) ))

let export_key =
  let privkey_path = Cli_lib.Flag.privkey_write_path in
  let pk_flag =
    let open Command.Param in
    flag "public-key" ~doc:"KEY Public key of account to be exported"
      (required Cli_lib.Arg_type.public_key_compressed)
  in
  let conf_dir = Cli_lib.Flag.conf_dir in
  let flags = Args.zip3 privkey_path pk_flag conf_dir in
  Command.async
    ~summary:
      "Export a tracked account so that it can be saved or transferred \
       between machines.\n\
      \ Set CODA_PRIVKEY_PASS environment variable to use non-interactively \
       (key will be exported using the same password)."
    (Cli_lib.Background_daemon.graphql_init flags
       ~f:(fun _ (export_path, pk, conf_dir) ->
         let open Deferred.Let_syntax in
         let%bind home = Sys.home_directory () in
         let conf_dir =
           Option.value
             ~default:(home ^/ Cli_lib.Default.conf_dir_name)
             conf_dir
         in
         let wallets_disk_location = conf_dir ^/ "wallets" in
         let%bind wallets =
           Secrets.Wallets.load ~logger:(Logger.create ())
             ~disk_location:wallets_disk_location
         in
         let password =
           lazy
             (Secrets.Password.hidden_line_or_env
                "Password for exported account: " ~env:Secrets.Keypair.env)
         in
         let%bind account =
           let open Deferred.Result.Let_syntax in
           let%bind _ = Secrets.Wallets.unlock wallets ~needle:pk ~password in
           Secrets.Wallets.find_identity wallets ~needle:pk
           |> Result.of_option ~error:`Not_found
           |> Deferred.return
         in
         let kp =
           match account with
           | Ok (`Keypair kp) ->
               Ok kp
           | Ok (`Hd_index i) ->
               Error
                 (sprintf
                    !"account is an HD account (hardware wallet), the \
                      associated index is %{Unsigned.UInt32}"
                    i)
           | Error `Bad_password ->
               Error
                 (sprintf
                    !"wrong password provided for account \
                      %{Public_key.Compressed.to_base58_check}"
                    pk)
           | Error `Not_found ->
               Error
                 (sprintf
                    !"account not found corresponding to account \
                      %{Public_key.Compressed.to_base58_check}"
                    pk)
         in
         match kp with
         | Ok kp ->
             let%bind () =
               Secrets.Keypair.Terminal_stdin.write_exn kp
                 ~privkey_path:export_path
             in
             printf
               !"😄 Account exported to %s: %s\n"
               export_path
               (Public_key.Compressed.to_base58_check pk) ;
             Deferred.unit
         | Error e ->
             printf "❌ Export failed -- %s\n" e ;
             Deferred.unit ))

let list_accounts =
  let open Command.Param in
  Command.async ~summary:"List all owned accounts"
    (Cli_lib.Background_daemon.graphql_init (return ())
       ~f:(fun graphql_endpoint () ->
         let%map response =
           Graphql_client.query_exn
             (Graphql_queries.Get_tracked_accounts.make ())
             graphql_endpoint
         in
         match response#trackedAccounts with
         | [||] ->
             printf
               "😢 You have no tracked accounts!\n\
                You can make a new one using `coda accounts create`\n"
         | accounts ->
             Array.iteri accounts ~f:(fun i w ->
                 printf
                   "Account #%d:\n\
                   \  Public key: %s\n\
                   \  Balance: %s\n\
                   \  Locked: %b\n"
                   (i + 1)
                   (Public_key.Compressed.to_base58_check w#public_key)
                   (Currency.Balance.to_formatted_string (w#balance)#total)
                   (Option.value ~default:true w#locked) ) ))

let create_account =
  let open Command.Param in
  Command.async ~summary:"Create new account"
    (Cli_lib.Background_daemon.graphql_init (return ())
       ~f:(fun graphql_endpoint () ->
         let%bind password =
           Secrets.Keypair.Terminal_stdin.prompt_password
             "Password for new account: "
         in
         let%map response =
           Graphql_client.query_exn
             (Graphql_queries.Create_account.make
                ~password:(Bytes.to_string password) ())
             graphql_endpoint
         in
         let pk_string =
           Public_key.Compressed.to_base58_check
             (response#createAccount)#public_key
         in
         printf "\n😄 Added new account!\nPublic key: %s\n" pk_string ))

let create_hd_account =
  Command.async ~summary:Secrets.Hardware_wallets.create_hd_account_summary
    (Cli_lib.Background_daemon.graphql_init Cli_lib.Flag.User_command.hd_index
       ~f:(fun graphql_endpoint hd_index ->
         let%map response =
           Graphql_client.(
             query_exn
               (Graphql_queries.Create_hd_account.make
                  ~hd_index:(Encoders.uint32 hd_index) ()))
             graphql_endpoint
         in
         let pk_string =
           Public_key.Compressed.to_base58_check
             (response#createHDAccount)#public_key
         in
         printf "\n😄 created HD account with HD-index %s!\nPublic key: %s\n"
           (Coda_numbers.Hd_index.to_string hd_index)
           pk_string ))

let unlock_account =
  let open Command.Param in
  let pk_flag =
    flag "public-key" ~doc:"KEY Public key to be unlocked"
      (required Cli_lib.Arg_type.public_key_compressed)
  in
  Command.async ~summary:"Unlock a tracked account"
    (Cli_lib.Background_daemon.graphql_init pk_flag
       ~f:(fun graphql_endpoint pk_str ->
         let password =
           Deferred.map ~f:Or_error.return
             (Secrets.Password.hidden_line_or_env
                "Password to unlock account: " ~env:Secrets.Keypair.env)
         in
         match%bind password with
         | Ok password_bytes ->
             let%map response =
               Graphql_client.query_exn
                 (Graphql_queries.Unlock_account.make
                    ~public_key:(Graphql_client.Encoders.public_key pk_str)
                    ~password:(Bytes.to_string password_bytes)
                    ())
                 graphql_endpoint
             in
             let pk_string =
               Public_key.Compressed.to_base58_check
                 (response#unlockAccount)#public_key
             in
             printf "\n🔓 Unlocked account!\nPublic key: %s\n" pk_string
         | Error e ->
             Deferred.return
               (printf "❌ Error unlocking account: %s\n"
                  (Error.to_string_hum e)) ))

let lock_account =
  let open Command.Param in
  let pk_flag =
    flag "public-key" ~doc:"KEY Public key of account to be locked"
      (required Cli_lib.Arg_type.public_key_compressed)
  in
  Command.async ~summary:"Lock a tracked account"
    (Cli_lib.Background_daemon.graphql_init pk_flag
       ~f:(fun graphql_endpoint pk ->
         let%map response =
           Graphql_client.query_exn
             (Graphql_queries.Lock_account.make
                ~public_key:(Graphql_client.Encoders.public_key pk)
                ())
             graphql_endpoint
         in
         let pk_string =
           Public_key.Compressed.to_base58_check
             (response#lockAccount)#public_key
         in
         printf "🔒 Locked account!\nPublic key: %s\n" pk_string ))

let generate_libp2p_keypair =
  Command.async
    ~summary:"Generate a new libp2p keypair and print out the peer ID"
    (let open Command.Let_syntax in
    let%map_open privkey_path = Cli_lib.Flag.privkey_write_path in
    Cli_lib.Exceptions.handle_nicely
    @@ fun () ->
    Deferred.ignore
      (let open Deferred.Let_syntax in
      (* FIXME: I'd like to accumulate messages into this logger and only dump them out in failure paths. *)
      let logger = Logger.null () in
      (* Using the helper only for keypair generation requires no state. *)
      File_system.with_temp_dir "coda-generate-libp2p-keypair" ~f:(fun tmpd ->
          match%bind Coda_net2.create ~logger ~conf_dir:tmpd with
          | Ok net ->
              let%bind me = Coda_net2.Keypair.random net in
              let%bind () = Coda_net2.shutdown net in
              let%map () =
                Secrets.Libp2p_keypair.Terminal_stdin.write_exn ~privkey_path
                  me
              in
              printf "libp2p keypair:\n%s\n" (Coda_net2.Keypair.to_string me)
          | Error e ->
              Logger.fatal logger "failed to generate libp2p keypair: $error"
                ~module_:__MODULE__ ~location:__LOC__
                ~metadata:[("error", `String (Error.to_string_hum e))] ;
              exit 20 )))

let trustlist_ip_flag =
  Command.Param.(
    flag "ip-address"
      ~doc:"CIDR An IPv4 CIDR mask for the client trustlist (eg, 10.0.0.0/8)"
      (required Cli_lib.Arg_type.cidr_mask))

let trustlist_add =
  let open Deferred.Let_syntax in
  let open Daemon_rpcs in
  Command.async ~summary:"Add an IP to the trustlist"
    (Cli_lib.Background_daemon.rpc_init trustlist_ip_flag
       ~f:(fun port trustlist_ip ->
         let trustlist_ip_string = Unix.Cidr.to_string trustlist_ip in
         match%map Client.dispatch Add_trustlist.rpc trustlist_ip port with
         | Ok (Ok ()) ->
             printf "Added %s to client trustlist" trustlist_ip_string
         | Ok (Error e) ->
             eprintf "Error adding %s to client trustlist: %s"
               trustlist_ip_string (Error.to_string_hum e)
         | Error e ->
             eprintf "Unknown error doing daemon RPC: %s"
               (Error.to_string_hum e) ))

let trustlist_remove =
  let open Deferred.Let_syntax in
  let open Daemon_rpcs in
  Command.async ~summary:"Remove a CIDR mask from the trustlist"
    (Cli_lib.Background_daemon.rpc_init trustlist_ip_flag
       ~f:(fun port trustlist_ip ->
         let trustlist_ip_string = Unix.Cidr.to_string trustlist_ip in
         match%map Client.dispatch Remove_trustlist.rpc trustlist_ip port with
         | Ok (Ok ()) ->
             printf "Removed %s to client trustlist" trustlist_ip_string
         | Ok (Error e) ->
             eprintf "Error removing %s from client trustlist: %s"
               trustlist_ip_string (Error.to_string_hum e)
         | Error e ->
             eprintf "Unknown error doing daemon RPC: %s"
               (Error.to_string_hum e) ))

let trustlist_list =
  let open Deferred.Let_syntax in
  let open Daemon_rpcs in
  let open Command.Param in
  Command.async ~summary:"List the CIDR masks in the trustlist"
    (Cli_lib.Background_daemon.rpc_init (return ()) ~f:(fun port () ->
         match%map Client.dispatch Get_trustlist.rpc () port with
         | Ok ips ->
             printf
               "The following IPs are permitted to connect to the daemon \
                control port:\n" ;
             List.iter ips ~f:(fun ip -> printf "%s\n" (Unix.Cidr.to_string ip))
         | Error e ->
             eprintf "Unknown error doing daemon RPC: %s"
               (Error.to_string_hum e) ))

let telemetry =
  let open Command.Param in
  let open Deferred.Let_syntax in
  let daemon_peers_flag =
    flag "daemon-peers" no_arg
      ~doc:"Get telemetry data for peers known to the daemon"
  in
  let peer_ids_flag =
    flag "peer-ids"
      (optional (Arg_type.comma_separated string))
      ~doc:"CSV-LIST Peer IDs for obtaining telemetry data"
  in
  let show_errors_flag =
    flag "show-errors" no_arg ~doc:"Include error responses in output"
  in
  let flags = Args.zip3 daemon_peers_flag peer_ids_flag show_errors_flag in
  Command.async ~summary:"Get the trust status associated with an IP address"
    (Cli_lib.Background_daemon.rpc_init flags
       ~f:(fun port (daemon_peers, peer_ids, show_errors) ->
         if
           (Option.is_none peer_ids && not daemon_peers)
           || (Option.is_some peer_ids && daemon_peers)
         then (
           eprintf
             "Must provide exactly one of daemon-peers or peer-ids flags\n%!" ;
           don't_wait_for (exit 33) ) ;
         let peer_ids_opt =
           Option.map peer_ids ~f:(fun peer_ids ->
               List.map peer_ids ~f:Network_peer.Peer.Id.unsafe_of_string )
         in
         match%map
           Daemon_rpcs.Client.dispatch Daemon_rpcs.Get_telemetry_data.rpc
             peer_ids_opt port
         with
         | Ok all_telem_data ->
             let all_telem_data =
               if show_errors then all_telem_data
               else
                 List.filter all_telem_data ~f:(fun td ->
                     match td with Ok _ -> true | Error _ -> false )
             in
             List.iter all_telem_data ~f:(fun peer_telem_data ->
                 printf "%s\n%!"
                   ( Yojson.Safe.to_string
                   @@ Coda_networking.Rpcs.Get_telemetry_data
                      .response_to_yojson peer_telem_data ) )
         | Error err ->
             printf "Failed to get telemetry data: %s\n%!"
               (Error.to_string_hum err) ))

module Visualization = struct
  let create_command (type rpc_response) ~name ~f
      (rpc : (string, rpc_response) Rpc.Rpc.t) =
    let open Deferred.Let_syntax in
    Command.async
      ~summary:(sprintf !"Produce a visualization of the %s" name)
      (Cli_lib.Background_daemon.rpc_init
         Command.Param.(anon @@ ("output-filepath" %: string))
         ~f:(fun port filename ->
           let%map message =
             match%map Daemon_rpcs.Client.dispatch rpc filename port with
             | Ok response ->
                 f filename response
             | Error e ->
                 sprintf "Could not save file: %s\n" (Error.to_string_hum e)
           in
           print_string message ))

  module Frontier = struct
    let name = "transition-frontier"

    let command =
      create_command ~name Daemon_rpcs.Visualization.Frontier.rpc
        ~f:(fun filename -> function
        | `Active () ->
            Visualization_message.success name filename
        | `Bootstrapping ->
            Visualization_message.bootstrap name )
  end

  module Registered_masks = struct
    let name = "registered-masks"

    let command =
      create_command ~name Daemon_rpcs.Visualization.Registered_masks.rpc
        ~f:(fun filename () -> Visualization_message.success name filename)
  end

  let command_group =
    Command.group ~summary:"Visualize data structures special to Coda"
      [ (Frontier.name, Frontier.command)
      ; (Registered_masks.name, Registered_masks.command) ]
end

let accounts =
  Command.group ~summary:"Client commands concerning account management"
    ~preserve_subcommand_order:()
    [ ("list", list_accounts)
    ; ("create", create_account)
    ; ("import", import_key)
    ; ("export", export_key)
    ; ("unlock", unlock_account)
    ; ("lock", lock_account) ]

let client =
  Command.group ~summary:"Lightweight client commands"
    ~preserve_subcommand_order:()
    [ ("get-balance", get_balance_graphql)
    ; ("send-payment", send_payment_graphql)
    ; ("delegate-stake", delegate_stake_graphql)
    ; ("cancel-transaction", cancel_transaction_graphql)
    ; ("set-staking", set_staking_graphql)
    ; ("set-snark-worker", set_snark_worker)
    ; ("set-snark-work-fee", set_snark_work_fee)
    ; ("stop-daemon", stop_daemon)
    ; ("status", status) ]

let client_trustlist_group =
  Command.group ~summary:"Client trustlist management"
    ~preserve_subcommand_order:()
    [ ("add", trustlist_add)
    ; ("list", trustlist_list)
    ; ("remove", trustlist_remove) ]

let advanced =
  Command.group ~summary:"Advanced client commands"
    [ ("get-nonce", get_nonce_cmd)
    ; ("client-trustlist", client_trustlist_group)
    ; ("get-trust-status", get_trust_status)
    ; ("get-trust-status-all", get_trust_status_all)
    ; ("get-public-keys", get_public_keys)
    ; ("reset-trust-status", reset_trust_status)
    ; ("batch-send-payments", batch_send_payments)
    ; ("status-clear-hist", status_clear_hist)
    ; ("wrap-key", wrap_key)
    ; ("dump-keypair", dump_keypair)
    ; ("dump-ledger", dump_ledger)
    ; ("constraint-system-digests", constraint_system_digests)
    ; ("start-tracing", start_tracing)
    ; ("stop-tracing", stop_tracing)
    ; ("snark-job-list", snark_job_list)
    ; ("pooled-user-commands", pooled_user_commands)
    ; ("snark-pool-list", snark_pool_list)
    ; ("pending-snark-work", pending_snark_work)
    ; ("generate-libp2p-keypair", generate_libp2p_keypair)
    ; ("telemetry", telemetry)
    ; ("visualization", Visualization.command_group)
    ; ("generate-receipt", generate_receipt)
    ; ("verify-receipt", verify_receipt)
    ; ("generate-keypair", Cli_lib.Commands.generate_keypair) ]
