module Heucristic
  module Index
    enum MacroTarget
      Main
      Spec

      def self.prefix : String
        "<macros"
      end

      def self.generated?(path : String) : Bool
        path.starts_with?(prefix)
      end

      def generated_path : String
        case self
        in .main? then "#{MacroTarget.prefix}>"
        in .spec? then "#{MacroTarget.prefix}:spec>"
        end
      end

      def title : String
        case self
        in .main? then "Expanding macros"
        in .spec? then "Expanding spec macros"
        end
      end

      def wire : String
        to_s.downcase
      end
    end
  end
end
