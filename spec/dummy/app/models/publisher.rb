class Publisher < ApplicationRecord
  has_many :books
  has_many :reviews, through: :books
end
