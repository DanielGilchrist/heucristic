require "../index/identity"
require "../index/workspace"
require "../resolve/builtins"
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

        case identity
        in Index::Public      then provided(identity)
        in Index::FilePrivate then Answer.note("`#{identity}` has no declaration of its own")
        end
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

      private def provided(identity : Index::Public) : Answer
        name = identity.name
        unless Resolve::Builtins.includes?(name)
          return Answer.note("`#{name}` has no declaration of its own")
        end

        lines = ["# built into the compiler, no source file declares it"]
        Resolve::Builtins.summary(name).try { |summary| lines << "# #{summary}" }
        lines << builtin(name)
        Answer.described(fence(lines))
      end

      private def builtin(name : String) : String
        case (superclass = Resolve::Builtins.superclass(name))
        in String                          then "#{name} < #{superclass}"
        in Resolve::Builtins::NoSuperclass then name
        end
      end

      private def fence(lines : Array(String)) : String
        "```crystal\n#{lines.join('\n')}\n```"
      end

      private def fence(*lines : String) : String
        fence(lines.to_a)
      end
    end
  end
end
