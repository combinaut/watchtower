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
  # triggers watching them fire as they would for a save of those attributes. Each `enabled:` is read now, and the
  # change is held for the commit, combined with the transaction's other changes to the same rows, and dropped if its
  # transaction or savepoint rolls back. Outside a transaction, the records on each connection fire together once a
  # transaction opened for them commits. Raises `ArgumentError`, recording nothing, for an attribute that ties a record
  # to its watchers.
  def self.record_changes(records, attributes:)
    Observer.instance.record_changes(records.to_a, attributes: attributes)
  end
end
