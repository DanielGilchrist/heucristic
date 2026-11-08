require "./group"

module Score
  module Features
    enum Kind
      CallWithReceiver
      CallImplicit
      StatementCall
      LocalDefinition
      LocalUse
      SelfReference
      Parameter
      InstanceVarParameter
      BlockParameter
      UnpackedBlockParameter
      InstanceVar
      ClassVar
      ConstantPath
      TypePath
      DeclarationPath
      EnumMember
      DefName
      Require

      def label : String
        to_s.underscore.tr("_", " ")
      end

      def definition? : Bool
        local_definition? || parameter? || block_parameter? || unpacked_block_parameter?
      end

      def group : Group?
        case self
        in .call_with_receiver?, .call_implicit?
          Group::Call
        in .constant_path?, .type_path?, .declaration_path?
          Group::Path
        in .instance_var?, .class_var?
          Group::InstanceVariable
        in .local_definition?, .local_use?, .parameter?, .instance_var_parameter?, .block_parameter?
          Group::Local
        in .def_name?
          Group::DefName
        in .statement_call?, .self_reference?, .unpacked_block_parameter?, .enum_member?, .require?
          nil
        end
      end
    end
  end
end
