module Probe
  record Invalid do
    def report : Int32
      STDERR.puts "usage: probe <file.cr> <line>:<column> [hover|definition|both|references|" \
                  "complete|rename:<name>|symbols|workspace:<query>]"
      STDERR.puts "positions are 1-based; HEUCRISTIC_BIN overrides the server binary"
      1
    end
  end
end
