require "../syntax/type_reader"

module Heucristic
  module Index
    record Unrestricted

    alias Restriction = Syntax::Type | Syntax::TypeReader::Unsupported | Unrestricted

    module Restrictions
      def self.of(node : Crystal::ASTNode?) : Restriction
        return Unrestricted.new unless node

        Syntax::TypeReader.read(node)
      end

      def self.write(io : IO, restriction : Restriction) : Nil
        case restriction
        in Unrestricted                    then nil
        in Syntax::TypeReader::Unsupported then io << " : " << restriction.source
        in Syntax::Type                    then io << " : " << restriction
        end
      end
    end
  end
end
