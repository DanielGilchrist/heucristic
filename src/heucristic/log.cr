module Heucristic
  module Log
    extend self

    def info(message : String) : Nil
      STDERR.puts("[heucristic] #{message}")
      STDERR.flush
    end
  end
end
