require "./heucristic/server/loop"

Heucristic::Server::Loop.new(STDIN, STDOUT).run
