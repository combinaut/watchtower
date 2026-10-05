# Enqueue Watchtower's jobs when `perform_later` is called, which a queued `at: :save` trigger needs. On Rails 7.2 only
# `:never` does that: `:always` defers the enqueue until the commit, and any other value leaves it to the queue adapter.
Rails.application.config.to_prepare do
  Watchtower::Job.enqueue_after_transaction_commit = Rails.gem_version < Gem::Version.new("8.0") ? :never : false
end
