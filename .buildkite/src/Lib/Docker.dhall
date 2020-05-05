-- Docker plugin specific settings for commands
--
-- See https://github.com/buildkite-plugins/docker-buildkite-plugin for options
-- if you'd like to extend this definition for example
--
-- TODO: Move volume to something in the cloud or artifacts from gcloud storage

let Config = {
  Type = {
    image: Text
  },
  default = {=}
}

let Result = {
  Type = {
     image: Text,
     `propagate-environment`: Bool,
     `propagate-uid-gid`: Bool,
     environment: List Text,
     volumes: List Text
  },
  default = {
    `propagate-environment` = True,
    `propagate-uid-gid` = True,
    environment = [ "BUILDKITE_AGENT_ACCESS_TOKEN" ],
    volumes = [
      "dhall-cache:/.cache",
    ]
  }
}

let build : Config.Type -> Result.Type = \(c: Config.Type) ->
  Result::{ image = c.image }

in

{Config = Config, build = build } /\ Result

