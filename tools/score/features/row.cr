require "./bucket"
require "./inquiry"
require "./observation"

module Score
  module Features
    class Row
      record Crash, place : Place, message : String
      record Unlocated, place : Place, via : String

      getter total = 0
      getter answered = 0
      getter unanswered = 0
      getter empties = Array(Place).new
      getter crashes = Array(Crash).new
      getter without_definition = Array(Unlocated).new
      getter untargeted = Array(Place).new
      getter reasons = Hash(String, Bucket).new

      def add(observation : Observation) : Nil
        @total += 1
        reply = observation.reply
        case reply
        in Answered
          @answered += 1
          unless declared?(reply, observation)
            @without_definition << Unlocated.new(observation.place, via(observation))
          end
        in Unanswered
          @unanswered += 1
          @untargeted << observation.place if reply.reason == Inquiry::NO_TARGET
          @reasons[reply.reason] ||= Bucket.new
          @reasons[reply.reason].add(observation.place, reply.detail)
        in Empty
          @empties << observation.place
        in Crashed
          @crashes << Crash.new(observation.place, reply.message)
        end
      end

      private def via(observation : Observation) : String
        observation.target.try(&.class.name.split("::").last) || "-"
      end

      private def declared?(reply : Answered, observation : Observation) : Bool
        reply.located || observation.site.kind.self_reference?
      end
    end
  end
end
