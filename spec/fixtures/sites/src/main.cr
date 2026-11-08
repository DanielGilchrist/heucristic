macro settings(name)
  HABITAT = [{decl: {{ name }}, example: nil}] of Nil

  class Inner
    def inner : Int32
      1
    end
  end
end

class Mail
  settings foo : String
end

Mail::Inner.new.inner
