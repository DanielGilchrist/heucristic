require "../../../src/heucristic/server/answer"
require "../../../src/heucristic/syntax/target"
require "./place"
require "./reply"
require "./site"

module Score
  module Features
    record Observation,
      path : String,
      site : Site,
      reply : Reply,
      target : Heucristic::Syntax::Target?,
      answer : Heucristic::Server::Answer? do
      def place : Place
        Place.new(path, site.line, site.column)
      end

      def answered_and_located? : Bool
        reply = self.reply
        reply.is_a?(Answered) && reply.located
      end
    end
  end
end
