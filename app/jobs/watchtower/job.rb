module Watchtower
  class Job < Watchtower::ApplicationJob
    self.queue_adapter = :async if Rails.env.development? # Don't force Delayed Job to run just for indexing a single record in dev mode

    # Runs the queued triggers on a change the observer described (`Change#to_payload`).
    def perform(suppressed_trigger_keys: [], **payload)
      change = Change.from_payload(**payload)
      triggers = Watchtower::Observer.triggers.reject(&:inline).select { |trigger| change.watches_of(trigger).any? }
      Dispatch.run(triggers.reject { |trigger| trigger_suppressed?(trigger, suppressed_trigger_keys) }, change)
    end

    private

    # A trigger whose `enabled` predicate evaluated false in the saving thread (see
    # Observer#enqueue) is carried here by key. We honour that enqueue-time decision rather than
    # re-evaluating, since the context that informed it no longer exists on this thread.
    def trigger_suppressed?(trigger, suppressed_trigger_keys)
      suppressed_trigger_keys.include?(trigger.key)
    end
  end
end
