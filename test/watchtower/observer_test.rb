require "test_helper"

class Watchtower::ObserverTest < ActiveSupport::TestCase
  class FakeObservingClass; end
  class FakeObservedClass; end

  test "build_trigger requires an observing_class" do
    error = assert_raises(ArgumentError) do
      Watchtower::Observer.build_trigger(class: FakeObservedClass, callback: :noop)
    end
    assert_match(/observing class/i, error.message)
  end

  test "build_trigger wraps a single attribute into an array" do
    trigger = Watchtower::Observer.build_trigger(
      observing_class: FakeObservingClass,
      class: FakeObservedClass,
      callback: :noop,
      attribute: :name
    )
    assert_equal [ :name ], trigger.attributes
  end

  test "build_trigger constantizes a String class option" do
    trigger = Watchtower::Observer.build_trigger(
      observing_class: FakeObservingClass,
      class: "Watchtower::ObserverTest::FakeObservedClass",
      callback: :noop
    )
    assert_equal FakeObservedClass, trigger.class
  end

  test "build_trigger returns a frozen Trigger" do
    trigger = Watchtower::Observer.build_trigger(
      observing_class: FakeObservingClass,
      class: FakeObservedClass,
      callback: :noop
    )
    assert_kind_of Watchtower::Observer::Trigger, trigger
    assert trigger.frozen?
  end
end
