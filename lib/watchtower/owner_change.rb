module Watchtower
  # A change to a watched record as one owner sees it. A callback that takes the change is given one for the owner it
  # runs on (`Helpers.takes_change?`).
  #
  # @!attribute kind
  #   @return [Symbol, nil] how the change affected the owner:
  #     - `:added`    the record became one of the owner's
  #     - `:removed`  the record stopped being one of the owner's, including by being destroyed
  #     - `:changed`  the record was one of the owner's before the change and after it
  #     - `nil`       the previous owners cannot be known (`Audience#owners_before`)
  # @!attribute record
  #   @return [ActiveRecord::Base, nil] the changed record; nil when a job runs after it was destroyed or deleted
  # @!attribute record_class
  #   @return [Class] the changed record's class
  # @!attribute record_id
  #   @return [Object] the changed record's id
  # @!attribute destroyed
  #   @return [Boolean] whether the record was destroyed (also `destroyed?`)
  # @!attribute changed_attributes
  #   @return [Array<String>] the attributes the change saved; empty for a destroy, unless a trigger that fires at the
  #     commit merged it with an earlier save
  # @!attribute previous_owners
  #   @return [ActiveRecord::Relation, nil] the owners the record had before the change, which for an added record
  #     says where it came from; nil when they cannot be known
  # @!attribute owners
  #   @return [ActiveRecord::Relation] the owners the record has after the change, which for a removed record says
  #     where it went; none when it was destroyed
  OwnerChange = Struct.new(:kind, :record, :record_class, :record_id, :destroyed, :changed_attributes, :previous_owners, :owners, keyword_init: true) do
    def destroyed?
      destroyed
    end
  end
end
