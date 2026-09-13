module Heucristic
  module Index
    enum MacroTarget
      Main
      Spec
      Loose

      def self.prefix : String
        "<macros"
      end

      def self.generated?(path : String) : Bool
        path.starts_with?(prefix)
      end

      def generated_path : String
        case self
        in .main?  then "#{MacroTarget.prefix}>"
        in .spec?  then "#{MacroTarget.prefix}:spec>"
        in .loose? then "#{MacroTarget.prefix}:loose>"
        end
      end

      def title : String
        case self
        in .main?  then "Expanding macros"
        in .spec?  then "Expanding spec macros"
        in .loose? then "Expanding macros of files outside the targets"
        end
      end

      def wire : String
        to_s.downcase
      end
    end
  end
end
