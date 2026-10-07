module Watchtower
  # The change to an associated record, described relative to the watcher a callback runs on: whether the record was
  # added to that watcher's association, removed from it, or changed within it, and where it came from or went to.
  #
  # @!attribute kind
  #   @return [Symbol, nil] how the change affected the watcher:
  #     - `:added`    the record became one of the watcher's associated records
  #     - `:removed`  the record stopped being one of the watcher's associated records, including by being destroyed
  #     - `:changed`  the record was one of the watcher's associated records before the change and after it
  #     - `nil`       the previous watchers cannot be known (`Watchers#before`)
  # @!attribute record
  #   @return [ActiveRecord::Base, nil] the associated record: for an inline trigger, the instance last saved or
  #     destroyed, so it shows anything written through that instance since; for a queued trigger, loaded when the job
  #     starts, and nil when it was destroyed or deleted by then
  # @!attribute record_class
  #   @return [Class] the associated record's class
  # @!attribute record_id
  #   @return [Object] the associated record's id
  # @!attribute destroyed
  #   @return [Boolean] whether the record was destroyed (also `destroyed?`)
  # @!attribute changed_attributes
  #   @return [Array<String>] the attributes the change saved; empty for a destroy, unless a trigger that fires at the
  #     commit merged it with an earlier save
  # @!attribute previous_watchers
  #   @return [ActiveRecord::Relation, nil] the watchers the record had before the change, which for an added record
  #     says where it came from; nil when they cannot be known
  # @!attribute watchers
  #   @return [ActiveRecord::Relation] the watchers the record has after the change, which for a removed record says
  #     where it went; none when it was destroyed
  WatcherChange = Struct.new(:kind, :record, :record_class, :record_id, :destroyed, :changed_attributes, :previous_watchers, :watchers, keyword_init: true) do
    def destroyed?
      destroyed
    end
  end
end
