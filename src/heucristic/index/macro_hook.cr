module Heucristic
  module Index
    enum MacroHook
      Included
      Inherited
      Extended
      Finished
      MethodAdded
      MethodMissing

      def self.from_name(name : String) : MacroHook?
        each { |hook| return hook if hook.macro_name == name }
        nil
      end

      def macro_name : String
        case self
        in .included?       then "included"
        in .inherited?      then "inherited"
        in .extended?       then "extended"
        in .finished?       then "finished"
        in .method_added?   then "method_added"
        in .method_missing? then "method_missing"
        end
      end

      def generates_defs? : Bool
        case self
        in .included?, .inherited?, .extended?, .finished? then true
        in .method_added?, .method_missing?                then false
        end
      end
    end
  end
end
