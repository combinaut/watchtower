class Book < ApplicationRecord
  belongs_to :author
  belongs_to :publisher, optional: true
  has_many :reviews
  has_many :comments, as: :commentable
  has_many :review_comments, through: :reviews, source: :comments
end
