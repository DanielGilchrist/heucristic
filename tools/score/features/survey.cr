require "../corpus"
require "../options"
require "./inquiry"
require "./report"
require "./verification"

module Score
  module Features
    class Survey
      def initialize(@corpus : Corpus, @options : Options) : Nil
      end

      def run : Int32
        inquiry = Inquiry.over(
          @corpus.workspace, @corpus.types, @corpus.methods, @corpus.receiver, @corpus.origins,
          @corpus.root
        )
        verifying = (@options.count || 0) > 0
        table = Table.new
        pool = Array(Observation).new
        definitions = Set(Place).new
        listed = paths
        elapsed = Time.measure do
          listed.each do |path|
            inquiry.observe(path, File.read(path)).each do |observation|
              table.add(observation)
              definitions << observation.place if observation.site.kind.definition?
              pool << observation if verifying && observation.answered_and_located?
            end
          end
        end

        Report.new(@corpus, table).print(listed.size, elapsed)
        failed = verifying ? verify(pool, definitions) : 0
        table.defects.zero? && failed.zero? ? 0 : 2
      end

      private def verify(pool : Array(Observation), definitions : Set(Place)) : Int32
        count = @options.count || 0
        Verification.new(@corpus, @options, definitions).run(pool, count)
      end

      private def paths : Array(String)
        roots = @options.specs ? {"src", "spec"} : {"src"}
        found = roots.flat_map { |root| Dir.glob(File.join(@corpus.root, root, "**", "*.cr")) }
        found.reject { |path| @corpus.in_lib?(path) }.sort!
      end
    end
  end
end
