require "lsprotocol"

module Heucristic
  module Protocol
    enum Method
      Initialize
      Initialized
      Shutdown
      Exit
      DidOpen
      DidChange
      DidClose
      DidSave
      PublishDiagnostics
      Hover
      Definition
      References
      DocumentSymbol
      Completion
      Rename
      WorkspaceSymbol
      Progress
      WorkDoneProgressCreate

      def self.from_wire(name : String) : Method?
        each { |method| return method if method.wire == name }
        nil
      end

      def wire : String
        case self
        in .initialize?                then LSProtocol::INITIALIZE
        in .initialized?               then LSProtocol::INITIALIZED
        in .shutdown?                  then LSProtocol::SHUTDOWN
        in .exit?                      then LSProtocol::EXIT
        in .did_open?                  then LSProtocol::TEXT_DOCUMENT_DID_OPEN
        in .did_change?                then LSProtocol::TEXT_DOCUMENT_DID_CHANGE
        in .did_close?                 then LSProtocol::TEXT_DOCUMENT_DID_CLOSE
        in .did_save?                  then LSProtocol::TEXT_DOCUMENT_DID_SAVE
        in .publish_diagnostics?       then LSProtocol::TEXT_DOCUMENT_PUBLISH_DIAGNOSTICS
        in .hover?                     then LSProtocol::TEXT_DOCUMENT_HOVER
        in .definition?                then LSProtocol::TEXT_DOCUMENT_DEFINITION
        in .references?                then LSProtocol::TEXT_DOCUMENT_REFERENCES
        in .document_symbol?           then LSProtocol::TEXT_DOCUMENT_DOCUMENT_SYMBOL
        in .completion?                then LSProtocol::TEXT_DOCUMENT_COMPLETION
        in .rename?                    then LSProtocol::TEXT_DOCUMENT_RENAME
        in .workspace_symbol?          then LSProtocol::WORKSPACE_SYMBOL
        in .progress?                  then LSProtocol::PROGRESS
        in .work_done_progress_create? then LSProtocol::WINDOW_WORK_DONE_PROGRESS_CREATE
        end
      end
    end
  end
end
