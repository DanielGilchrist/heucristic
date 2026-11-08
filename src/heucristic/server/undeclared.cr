require "../index/identity"
require "../index/workspace"
require "./answer"

module Heucristic
  module Server
    class Undeclared
      LISTED  = 5
      IMPLIED = "# no declaration of its own, implied by the declarations nested in it"

      def initialize(@workspace : Index::Workspace) : Nil
      end

      def answer(identity : Index::Identity, root : String) : Answer
        nested = @workspace.enclosed(identity)
        return implied(identity, nested, root) unless nested.empty?

        Answer.note("`#{identity}` has no declaration of its own")
      end

      private def implied(
        identity : Index::Identity,
        nested : Array(Index::Namespace),
        root : String,
      ) : Answer
        places = nested.first(LISTED).map do |entry|
          "- `#{entry.name}` at #{entry.path.sub(root + "/", "")}:#{entry.name_span.start_line + 1}"
        end
        places << "- and #{nested.size - LISTED} more" if nested.size > LISTED
        header = fence("# #{identity}", IMPLIED)
        Answer.described("#{header}\n\n#{places.join('\n')}")
      end

      private def fence(*lines : String) : String
        "```crystal\n#{lines.join('\n')}\n```"
      end
    end
  end
end
