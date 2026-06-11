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
  end
end
