module Watchtower
  class Job < Watchtower::ApplicationJob
    self.queue_adapter = :async if Rails.env.development? # Don't force Delayed Job to run just for indexing a single record in dev mode

    # Whether Active Job defers this job's enqueue until the surrounding transaction commits
    # (`enqueue_after_transaction_commit`), by each Rails version's own reading of the setting:
    #   - 7.2:  `:never` does not defer, `:always` does, and any other value asks the queue adapter
    #   - 8.0:  `true` and `:always` defer; `false`, `:never` and `:default` do not
    #   - 8.1:  any truthy value defers, including a `:never` or `:default` kept from an earlier version
    def self.enqueued_after_commit?
      setting = enqueue_after_transaction_commit
      if ActiveJob.version < Gem::Version.new("8.0")
        return false if setting == :never

        return setting == :always || queue_adapter.enqueue_after_transaction_commit?
      end
      return setting == true || setting == :always if ActiveJob.version < Gem::Version.new("8.1")

      setting ? true : false
    end

    # Runs the queued triggers that fire `at` on the `changes` the observer described (`Change#to_payload`), each
    # leaving out the triggers it marks as suppressed. A job enqueued without `at` fires the commit-time triggers, and
    # one enqueued without `changes` by an earlier version of Watchtower carries a single change as its arguments.
    def perform(at: :commit, changes: nil, **payload)
      triggers = Watchtower::Observer.triggers.reject(&:inline).select { |trigger| trigger.fires_at?(at) }
      pairs = (changes || [ payload ]).flat_map do |entry|
        entry = entry.symbolize_keys
        suppressed_trigger_keys = entry.delete(:suppressed_trigger_keys) || []
        change = Change.from_payload(**entry)
        triggers.select { |trigger| change.watches_of(trigger).any? && !trigger_suppressed?(trigger, suppressed_trigger_keys) }.map { |trigger| [ trigger, change ] }
      end
      Dispatch.run(pairs)
    end

    private

    # Whether the observer marked `trigger` as not to run in this job (see `Observer#enqueue`), because its `enabled`
    # predicate was false at every save or destroy the job's change covers. The decision is honoured rather than
    # re-evaluated, because the context that informed it does not exist on this thread.
    def trigger_suppressed?(trigger, suppressed_trigger_keys)
      suppressed_trigger_keys.include?(trigger.key)
    end
  end
end
