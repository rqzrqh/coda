let Pipeline = ../../Lib/Pipeline.dhall
let Command = ../../Lib/Command.dhall
let Size = ../../Lib/Size.dhall

in

Pipeline.build
  Pipeline.Config::{
    spec = ./Spec.dhall,
    steps = [
      Command.Config::{ command = [ "echo \"hello\"" ], label = "Test Echo", key = "hello", target = Size.Small }
    ]
  }
