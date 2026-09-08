require "./file"

module Heucristic
  module Index
    record Started, total : Int32
    record Advanced, done : Int32, total : Int32
    record Finished, files : Array(File), shims : Array(File), elapsed : Time::Span

    alias Event = Started | Advanced | Finished
  end
end
