module Score
  record Invalid, reason : String do
    def report : Int32
      STDERR.puts "score: #{reason}"
      STDERR.puts "usage: score [<project>] [--check [--why] [--only <suffix>]] " \
                  "[--at <file>:<line>[:<column>]] [--verify <count> --main <file>] " \
                  "[--define <flag>]... [--no-macros]"
      1
    end
  end
end
