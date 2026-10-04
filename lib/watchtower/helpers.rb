module Watchtower
  module Helpers
    def self.constantize(class_or_name)
      case class_or_name
      when String
        class_or_name.constantize
      else
        class_or_name
      end
    end

    # Invoke a value supplied to a watchtower DSL option the way the DSL accepts them: a Proc
    # (arity-aware — passed the receiver when it takes an argument), or a Symbol/String method name
    # sent to the receiver. Shared by trigger `callback`s, `affects` scopes, and `enabled` predicates.
    def self.evaluate(callable, receiver)
      case callable
      when Proc
        callable.arity.positive? ? callable.call(receiver) : callable.call
      when Symbol, String
        receiver.send(callable)
      else
        raise "Unhandled callable #{callable.inspect}"
      end
    end

    # Whether a trigger's `callback` takes the change (`Watchtower::OwnerChange`) as well as the record of `klass` it
    # runs on: a `Proc` with a second positional parameter, or a method with a required positional parameter. A
    # method whose parameters are all optional, such as `touch`, is sent to the record with no argument.
    def self.callback_wants_change?(callback, klass)
      parameters =
        case callback
        when Proc then callback.parameters.drop(1)
        when Symbol, String then klass.instance_method(callback).parameters
        else return false
        end
      callback.is_a?(Proc) ? parameters.any? { |type, _| %i[req opt rest].include?(type) } : parameters.any? { |type, _| type == :req }
    end

    # Calls a trigger's `callback` on `receiver` with `change`: a `Proc` is called with both, and a method is sent to
    # `receiver` with `change`.
    def self.evaluate_with_change(callback, receiver, change)
      callback.is_a?(Proc) ? callback.call(receiver, change) : receiver.send(callback, change)
    end
  end
end
