open Core

module Stable : sig
  module V1 : sig
    type t [@@deriving bin_io, version]
  end

  module Latest = V1
end

type t = Stable.V1.t

module Level : sig
  type t = Spam | Trace | Debug | Info | Warn | Error | Faulty_peer | Fatal
  [@@deriving sexp, compare, yojson, show {with_path= false}, enumerate]

  val of_string : string -> (t, string) result
end

module Time : sig
  include module type of Time

  val to_yojson : t -> Yojson.Safe.json

  val of_yojson : Yojson.Safe.json -> (t, string) Result.t
end

module Source : sig
  type t = {module_: string [@key "module"]; location: string}
  [@@deriving yojson]

  val create : module_:string -> location:string -> t
end

module Metadata : sig
  module Stable : sig
    module V1 : sig
      type t = Yojson.Safe.json String.Map.t
      [@@deriving yojson, bin_io, version]
    end

    module Latest = V1
  end

  type t = Stable.V1.t
end

(** Used only when dealing with the raw logging function *)
val metadata : t -> Metadata.t

module Message : sig
  type t =
    { timestamp: Time.t
    ; level: Level.t
    ; source: Source.t option
    ; message: string
    ; metadata: Metadata.t }
  [@@deriving yojson]
end

(** A Processor is a module which processes structured log
 *  messages into strings. This is used as part of defining
 *  a Consumer. *)
module Processor : sig
  type t

  val raw : ?log_level:Level.t -> unit -> t

  val pretty : log_level:Level.t -> config:Logproc_lib.Interpolator.config -> t
end

(** A Transport is a module which represent a destination
 *  for a log strings. This is used as part of defining a
 *  Consumer. *)
module Transport : sig
  type t

  val stdout : unit -> t

  module File_system : sig
    (** Dumb_logrotate is a Transport which persists logs
     *  to the file system by using 2 log files. This
     *  Transport will rotate the 2 logs, ensuring that
     *  each log file is less than some maximum size
     *  before writing to it. When the logs reach max
     *  size, the old log is deleted and a new log is
     *  started. *)
    val dumb_logrotate :
      directory:string -> log_filename:string -> max_size:int -> t
  end
end

(** The Consumer_registry is a global registry where consumers
 *  of the Logger can be registered. Each Consumer consists of
 *  a Processor and a Transport. The processor filters and
 *  serializes structured log messages to strings, and the
 *  transport encapsulates the side effects of the consumer.
 *  Every Consumer is registered under some unique id to
 *  ensure the code does not accidentally attach the same
 *  consumer multiple times. *)
module Consumer_registry : sig
  val register :
    id:string -> processor:Processor.t -> transport:Transport.t -> unit
end

type 'a log_function =
     t
  -> module_:string
  -> location:string
  -> ?metadata:(string, Yojson.Safe.json) List.Assoc.t
  -> ('a, unit, string, unit) format4
  -> 'a

val create :
  ?metadata:(string, Yojson.Safe.json) List.Assoc.t -> ?id:string -> unit -> t

val null : unit -> t

val extend : t -> (string, Yojson.Safe.json) List.Assoc.t -> t

val change_id : t -> id:string -> t

val raw : t -> Message.t -> unit

val trace : _ log_function

val debug : _ log_function

val info : _ log_function

val warn : _ log_function

val error : _ log_function

(** spam is a special log level that omits location information *)
val spam :
     t
  -> ?metadata:(string, Yojson.Safe.json) List.Assoc.t
  -> ('a, unit, string, unit) format4
  -> 'a

val faulty_peer : _ log_function [@@deprecated "use Trust_system.record"]

val faulty_peer_without_punishment : _ log_function

val fatal : _ log_function

val append_to_global_metadata : (string * Yojson.Safe.json) list -> unit
