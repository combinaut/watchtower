RSpec.describe Watchtower::Job do
  let(:author) { Author.create!(name: "Ada") }
  let(:book) { Book.create!(author: author, title: "Original") }

  def perform(record, destroyed: false, changed_attributes: [ "title" ], **extra)
    described_class.perform_now(
      record_class: record.class.base_class.name,
      record_id: record.id,
      destroyed: destroyed,
      changed_attributes: changed_attributes,
      **extra
    )
  end

  describe "audience resolution" do
    it "runs the callback on owners reached through the trigger association" do
      Author.watches(association: :books, callback: :reindex!)
      expect { perform(book) }.to change { author.reload.reindex_count }.by(1)
    end

    it "runs the callback on the scope returned by an affects proc" do
      Author.watches(class: "Book", affects: ->(changed) { Author.where(id: changed.author_id) }, callback: :reindex!)
      expect { perform(book) }.to change { author.reload.reindex_count }.by(1)
    end

    it "supports a proc callback invoked with the owner" do
      Author.watches(association: :books, callback: ->(owner) { owner.reindex! })
      expect { perform(book) }.to change { author.reload.reindex_count }.by(1)
    end

    it "does not run a trigger whose class does not match the changed record" do
      review = Review.create!(book: book, rating: 5)
      Author.watches(association: :books, callback: :reindex!) # watches Book, not Review
      expect { perform(review) }.not_to(change { author.reload.reindex_count })
    end
  end

  describe "relevance" do
    it "runs when the trigger watches no specific attributes" do
      Author.watches(association: :books, callback: :reindex!)
      expect { perform(book, changed_attributes: [ "title" ]) }.to change { author.reload.reindex_count }.by(1)
    end

    it "runs when a watched attribute changed" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      expect { perform(book, changed_attributes: [ "title" ]) }.to change { author.reload.reindex_count }.by(1)
    end

    it "does not run when only unwatched attributes changed" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      expect { perform(book, changed_attributes: [ "created_at" ]) }.not_to(change { author.reload.reindex_count })
    end

    it "runs on destruction regardless of the watched attribute" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      expect { perform(book, destroyed: true, changed_attributes: []) }.to change { author.reload.reindex_count }.by(1)
    end
  end

  describe "suppressed triggers" do
    it "skips a trigger whose key is in suppressed_trigger_keys" do
      Author.watches(association: :books, callback: :reindex!)
      expect { perform(book, suppressed_trigger_keys: [ "Author/reindex!/books" ]) }
        .not_to(change { author.reload.reindex_count })
    end

    it "runs triggers whose key is not suppressed" do
      Author.watches(association: :books, callback: :reindex!)
      expect { perform(book, suppressed_trigger_keys: [ "Author/something_else/books" ]) }
        .to change { author.reload.reindex_count }.by(1)
    end

    it "defaults to running everything when no suppression is given" do
      Author.watches(association: :books, callback: :reindex!)
      expect { perform(book) }.to change { author.reload.reindex_count }.by(1)
    end
  end
end
