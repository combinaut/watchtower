require "test_helper"

class Watchtower::HelpersTest < ActiveSupport::TestCase
  test "constantize resolves a String to a constant" do
    assert_equal Watchtower::Observer, Watchtower::Helpers.constantize("Watchtower::Observer")
  end

  test "constantize returns a Class unchanged" do
    assert_equal Watchtower::Observer, Watchtower::Helpers.constantize(Watchtower::Observer)
  end

  test "constantize raises NameError for unknown constant names" do
    assert_raises(NameError) { Watchtower::Helpers.constantize("NoSuchConstantHere") }
  end
end
