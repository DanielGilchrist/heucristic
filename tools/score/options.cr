require "./at"
require "./invalid"

module Score
  record Options,
    root : String,
    mode : Mode,
    why : Bool,
    only : String?,
    at : At?,
    verification : Verification?,
    defines : Array(String),
    macros : Bool do
    enum Mode
      Scan
      Check
    end

    record Verification, count : Int32, main : String

    def self.parse(args : Array(String)) : Options | Invalid
      first = args[0]?
      project = first unless first.nil? || first.starts_with?("--")
      root = File.expand_path(project || Dir.current)
      mode = Mode::Scan
      why = false
      macros = true
      only = nil
      at = nil
      count = nil
      main = nil
      defines = Array(String).new

      index = project ? 1 : 0
      while index < args.size
        argument = args[index]
        case argument
        when "--check"
          mode = Mode::Check
        when "--why"
          why = true
        when "--no-macros"
          macros = false
        when "--only", "--main", "--define", "--at", "--verify"
          value = args[index + 1]?
          return Invalid.new("#{argument} needs a value") unless value

          index += 1
          case argument
          when "--only"   then only = value
          when "--main"   then main = value
          when "--define" then defines << value
          when "--at"
            parsed = At.parse(value)
            return parsed if parsed.is_a?(Invalid)

            at = parsed
          else
            count = value.to_i32?
            return Invalid.new("--verify needs a number, got #{value}") unless count
          end
        else
          return Invalid.new("unknown argument #{argument}")
        end
        index += 1
      end

      verification = count && main && count > 0 ? Verification.new(count, main) : nil
      new(root, mode, why, only, at, verification, defines, macros)
    end
  end
end
