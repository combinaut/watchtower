module Watchtower
  # A save of an observed record, as the triggers it fires read it.
  #
  # @!attribute record_class
  #   @return [String] the record's base class name
  # @!attribute record_id
  #   @return [Integer]
  # @!attribute record
  #   @return [ActiveRecord::Base]
  # @!attribute destroyed
  #   @return [Boolean]
  # @!attribute changed_attributes
  #   @return [Array<String>] the attributes the change saved
  Change = Struct.new(:record_class, :record_id, :record, :destroyed, :changed_attributes, keyword_init: true) do
    # The change `record` just saved.
    def self.capture(record)
      new(
        record_class: record.class.base_class.name,
        record_id: record.id,
        record: record,
        destroyed: record.destroyed?,
        changed_attributes: record.saved_changes.keys
      )
    end

    # The change a job reads from its payload.
    def self.from_payload(record_class:, record_id:, destroyed:, changed_attributes:)
      record = record_class.constantize.find(record_id)
      new(record_class: record_class, record_id: record_id, record: record, destroyed: destroyed, changed_attributes: changed_attributes)
    end

    def to_payload
      { record_class: record_class, record_id: record_id, destroyed: destroyed, changed_attributes: changed_attributes }
    end

    # The watches of `trigger` that observe the changed record's base class.
    def watches_of(trigger)
      trigger.watches_on(record_class.constantize)
    end
  end
end
