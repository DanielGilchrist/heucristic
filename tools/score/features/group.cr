module Score
  module Features
    enum Group
      Call
      Path
      InstanceVariable
      Local
      DefName

      def label : String
        to_s.underscore.tr("_", " ")
      end
    end
  end
end
