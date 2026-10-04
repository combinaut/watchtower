class Author < ApplicationRecord
  has_many :books
  has_many :published_books, -> { where(published: true) }, class_name: "Book"
  has_many :reviews, through: :books
  has_many :publishers, through: :books
  has_many :review_comments, through: :books
  has_many :publisher_reviews, through: :publishers, source: :reviews
  has_many :comments, as: :commentable
  has_many :novels
  has_many :mentions
  has_many :mentioned_books, through: :mentions, source: :subject, source_type: "Book"

  # Stand-in "the indexed representation changed" callback used by the trigger specs.
  def reindex!
    increment!(:reindex_count)
  end
end
