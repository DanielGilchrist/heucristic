require "../../spec_helper"
require "../../../tools/score/features/kind"

describe Score::Features::Kind do
  it "names a kind in words" do
    Score::Features::Kind::UnpackedBlockParameter.label.should eq "unpacked block parameter"
  end

  it "treats parameters and assignments as definitions and uses as not" do
    Score::Features::Kind::LocalDefinition.definition?.should be_true
    Score::Features::Kind::Parameter.definition?.should be_true
    Score::Features::Kind::BlockParameter.definition?.should be_true
    Score::Features::Kind::UnpackedBlockParameter.definition?.should be_true
    Score::Features::Kind::LocalUse.definition?.should be_false
  end

  it "verifies locals, paths, instance variables, def names and calls, nothing else" do
    Score::Features::Kind::TypePath.group.should eq Score::Features::Group::Path
    Score::Features::Kind::ClassVar.group.should eq Score::Features::Group::InstanceVariable
    Score::Features::Kind::LocalUse.group.should eq Score::Features::Group::Local
    Score::Features::Kind::DefName.group.should eq Score::Features::Group::DefName
    Score::Features::Kind::CallImplicit.group.should eq Score::Features::Group::Call
    Score::Features::Kind::SelfReference.group.should be_nil
  end

  it "names a group in words" do
    Score::Features::Group::InstanceVariable.label.should eq "instance variable"
  end
end
