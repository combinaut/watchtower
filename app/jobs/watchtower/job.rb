module Watchtower
  class Job < Watchtower::ApplicationJob
    self.queue_adapter = :async if Rails.env.development? # Don't force Delayed Job to run just for indexing a single record in dev mode

    # Whether Active Job defers this job's enqueue until the surrounding transaction commits
    # (`enqueue_after_transaction_commit`), by each Rails version's own reading of the setting:
    #   - 7.2:  `:never` does not defer, `:always` does, and any other value asks the queue adapter
    #   - 8.0:  `true` and `:always` defer; `false`, `:never` and `:default` do not
    #   - 8.1:  `true` defers and `false` does not
    def self.enqueued_after_commit?
      setting = enqueue_after_transaction_commit
      if ActiveJob.version < Gem::Version.new("8.0")
        return false if setting == :never

        return setting == :always || queue_adapter.enqueue_after_transaction_commit?
      end

      setting == true || setting == :always
    end

    # Runs the queued triggers on a change the observer described (`Change#to_payload`).
    def perform(suppressed_trigger_keys: [], **payload)
      change = Change.from_payload(**payload)
      triggers = Watchtower::Observer.triggers.reject(&:inline).select { |trigger| change.watches_of(trigger).any? }
      Dispatch.run(triggers.reject { |trigger| trigger_suppressed?(trigger, suppressed_trigger_keys) }, change)
    end

    private

    # Whether the observer marked `trigger` as not to run in this job (see `Observer#enqueue`): its `enabled`
    # predicate was false when it fired, or it fires at a different `at:` and is queued when it fires. The decision is
    # honoured rather than re-evaluated, because the context that informed it does not exist on this thread.
    def trigger_suppressed?(trigger, suppressed_trigger_keys)
      suppressed_trigger_keys.include?(trigger.key)
    end
  end
end
