# GEMS
require "rails-observers"

# LOCAL
require "watchtower/version"
require "watchtower/engine"
require "watchtower/helpers"
require "watchtower/change"
require "watchtower/watcher_change"
require "watchtower/watchers"
require "watchtower/dispatch"
require "watchtower/active_record"

module Watchtower
  # Records that `attributes` of `records` changed without Active Record callbacks, e.g. by `update_all`, so the
  # triggers watching them fire as they would for a save of those attributes: each `enabled:` read now, the change
  # held for the commit and combined with the transaction's other changes to the same rows, and dropped if its
  # transaction or savepoint rolls back. Outside a transaction, opens one, so all of `records` fire together. Raises
  # `ArgumentError` for an attribute that ties a record to its watchers.
  def self.record_changes(records, attributes:)
    records = records.to_a
    return if records.empty?

    records.first.class.transaction { Observer.instance.record_changes(records, attributes: attributes) }
  end
end
