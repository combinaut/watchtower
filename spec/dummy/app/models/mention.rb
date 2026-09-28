class Mention < ApplicationRecord
  belongs_to :author
  belongs_to :subject, polymorphic: true
end
