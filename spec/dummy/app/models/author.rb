class Author < ApplicationRecord
  has_many :books
  has_many :reviews, through: :books

  # Stand-in "the indexed representation changed" callback used by the trigger specs.
  def reindex!
    increment!(:reindex_count)
  end
end
