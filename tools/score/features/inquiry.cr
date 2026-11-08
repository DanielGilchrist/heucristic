require "../../../src/heucristic/document/point"
require "../../../src/heucristic/document/text"
require "../../../src/heucristic/server/answerer"
require "../../../src/heucristic/server/parameter_hint"
require "../../../src/heucristic/server/references"
require "../../../src/heucristic/server/source_paths"
require "../../../src/heucristic/syntax"
require "../../../src/heucristic/syntax/cursor"
require "../origin_lookup"
require "./observation"
require "./walker"

module Score
  module Features
    class Inquiry
      NO_TARGET   = "no def, call, constant, variable or instance variable under the cursor"
      QUOTED      = /`[^`]*`/
      UNKNOWN     = /unknown \(([a-z ]+): .*/
      REASON_SIZE = 90

      def self.over(
        workspace : Heucristic::Index::Workspace,
        types : Heucristic::Resolve::Types,
        methods : Heucristic::Resolve::Methods,
        receiver : Heucristic::Resolve::Receiver,
        origins : Hash(String, Heucristic::Index::MacroSite),
        root : String,
      ) : Inquiry
        references = Heucristic::Server::References.new(workspace, types, receiver)
        hints = Heucristic::Server::ParameterHint.new(workspace, types, receiver, references)
        answerer = Heucristic::Server::Answerer.new(
          workspace, types, methods, receiver, hints, OriginLookup.new(origins),
          Heucristic::Server::SourcePaths.new
        )
        new(answerer, root, workspace.crystal_version)
      end

      def initialize(
        @answerer : Heucristic::Server::Answerer,
        @root : String,
        @version : Heucristic::CrystalVersion::Detected,
      ) : Nil
      end

      def observe(path : String, source : String) : Array(Observation)
        tree = Heucristic::Syntax.parse(source, path)
        return Array(Observation).new unless tree.is_a?(Crystal::ASTNode)

        text = Heucristic::Document::Text.new(source)
        Walker.sites(tree, source).map { |site| ask(tree, text, path, site) }
      end

      private def ask(
        tree : Crystal::ASTNode,
        text : Heucristic::Document::Text,
        path : String,
        site : Site,
      ) : Observation
        point = Heucristic::Document::Point.new(site.line, site.column)
        target = Heucristic::Syntax::Cursor.find(tree, point, path, @version)
        unless target
          return Observation.new(path, site, Unanswered.new(NO_TARGET, NO_TARGET), nil, nil)
        end

        answer = @answerer.answer(target, path, text, @root)
        Observation.new(path, site, reply_to(answer), target, answer)
      rescue error : Exception
        Observation.new(path, site, Crashed.new("#{error.class}: #{error.message}"), nil, nil)
      end

      private def reply_to(answer : Heucristic::Server::Answer) : Reply
        return Empty.new if @answerer.sections(answer, @root).empty?
        return unanswered(answer) unless answered?(answer)

        Answered.new(located?(answer))
      end

      private def answered?(answer : Heucristic::Server::Answer) : Bool
        !answer.entries.empty? || !answer.spans.empty? || !answer.macros.empty? ||
          !answer.files.empty? || !answer.descriptions.empty? ||
          answer.notes.any?(&.starts_with?("```"))
      end

      private def located?(answer : Heucristic::Server::Answer) : Bool
        !@answerer.locations(answer, "file:///").empty?
      end

      private def unanswered(answer : Heucristic::Server::Answer) : Unanswered
        detail = answer.notes.first?.try(&.lines.first?) || ""
        reason = detail.gsub(UNKNOWN) { "unknown (#{$1})" }.gsub(QUOTED, "_")
        Unanswered.new(reason.size > REASON_SIZE ? reason[0, REASON_SIZE] : reason, detail)
      end
    end
  end
end
