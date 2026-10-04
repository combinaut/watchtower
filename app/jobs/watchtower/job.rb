module Watchtower
  class Job < Watchtower::ApplicationJob
    self.queue_adapter = :async if Rails.env.development? # Don't force Delayed Job to run just for indexing a single record in dev mode

    # Whether Active Job defers this job's enqueue until the surrounding transaction commits
    # (`enqueue_after_transaction_commit`). False on a Rails without the setting. On Rails 7.2 the setting is
    # `:always`, `:never`, or `:default`, and `:default` leaves the choice to the queue adapter.
    def self.enqueued_after_commit?
      return false unless respond_to?(:enqueue_after_transaction_commit)

      setting = enqueue_after_transaction_commit
      return queue_adapter.respond_to?(:enqueue_after_transaction_commit?) && queue_adapter.enqueue_after_transaction_commit? if setting == :default

      ![ false, nil, :never ].include?(setting)
    end

    # Runs the queued triggers on a change the observer described (`Change#to_payload`).
    def perform(suppressed_trigger_keys: [], **payload)
      change = Change.from_payload(**payload)
      triggers = Watchtower::Observer.triggers.reject(&:inline).select { |trigger| change.watches_of(trigger).any? }
      Dispatch.run(triggers.reject { |trigger| trigger_suppressed?(trigger, suppressed_trigger_keys) }, change)
    end

    private

    # Whether the observer marked `trigger` as not to run in this job (see `Observer#enqueue`): its `enabled`
    # predicate was false when it fired, or it fires at a different `at:` and gets a job of its own. The decision is
    # honoured rather than re-evaluated, because the context that informed it does not exist on this thread.
    def trigger_suppressed?(trigger, suppressed_trigger_keys)
      suppressed_trigger_keys.include?(trigger.key)
    end
  end
end
