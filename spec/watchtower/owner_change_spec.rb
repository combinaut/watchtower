RSpec.describe "A callback given the change" do
  let(:ada) { Author.create!(name: "Ada") }
  let(:grace) { Author.create!(name: "Grace") }
  let(:hedy) { Author.create!(name: "Hedy") }
  let(:book) { Book.create!(author: ada, title: "Original") }
  let(:seen) { [] }
  let(:record_change) { ->(author, change) { seen << [ author.name, change ] } }

  def change_for(name)
    seen.select { |owner, _| owner == name }.map(&:last)
  end

  context "on a direct association" do
    it "tells each owner of a moved record whether it was added or removed, and from or to whom" do
      book
      Author.watches(association: :books, callback: record_change, inline: true, at: :save)

      book.update!(author: grace)

      removed, = change_for("Ada")
      added, = change_for("Grace")
      aggregate_failures do
        expect(removed).to have_attributes(kind: :removed, record: book, record_class: Book, record_id: book.id)
        expect(removed.owners).to contain_exactly(grace), "where it went"
        expect(added.kind).to eq(:added)
        expect(added.previous_owners).to contain_exactly(ada), "where it came from"
      end
    end

    it "tells an owner its record changed, with the attributes that changed" do
      book
      Author.watches(association: :books, callback: record_change, inline: true)

      book.update!(title: "Changed")

      expect(change_for("Ada").sole).to have_attributes(kind: :changed, changed_attributes: a_collection_including("title"))
    end

    it "tells the owner of a destroyed record it was removed, and that it went nowhere" do
      book
      Author.watches(association: :books, callback: record_change, inline: true)

      book.destroy!

      change = change_for("Ada").sole
      aggregate_failures do
        expect(change).to have_attributes(kind: :removed, record_id: book.id)
        expect(change).to be_destroyed
        expect(change.owners).to be_empty
      end
    end

    it "at the commit, reports a record moved twice in one transaction once, from the first owner to the last" do
      book
      Author.watches(association: :books, callback: record_change, inline: true)

      Book.transaction do
        book.update!(author: grace)
        book.update!(author: hedy)
      end

      aggregate_failures do
        expect(change_for("Ada").sole).to have_attributes(kind: :removed)
        expect(change_for("Ada").sole.owners).to contain_exactly(hedy)
        expect(change_for("Hedy").sole).to have_attributes(kind: :added)
        expect(change_for("Hedy").sole.previous_owners).to contain_exactly(ada)
        expect(change_for("Grace")).to be_empty, "the callback ran on Grace, who held the book only inside the transaction"
      end
    end

    it "at the save, reports each step of a record moved twice in one transaction" do
      book
      Author.watches(association: :books, callback: record_change, inline: true, at: :save)

      Book.transaction do
        book.update!(author: grace)
        book.update!(author: hedy)
      end

      expect(seen.map { |owner, change| [ owner, change.kind ] })
        .to contain_exactly([ "Ada", :removed ], [ "Grace", :added ], [ "Grace", :removed ], [ "Hedy", :added ])
    end

    it "gives a queued callback the change, with no record once the record is destroyed" do
      book
      Author.watches(association: :books, callback: record_change)

      perform_enqueued_jobs { book.destroy! }

      expect(change_for("Ada").sole).to have_attributes(kind: :removed, record: nil, record_id: book.id)
    end
  end

  it "tells each owner of a record moved through a polymorphic association whether it was added or removed" do
    comment = Comment.create!(commentable: ada, body: "Hello")
    Author.watches(association: :comments, callback: record_change, inline: true)

    comment.update!(commentable: grace)

    expect(seen.map { |owner, change| [ owner, change.kind ] }).to contain_exactly([ "Ada", :removed ], [ "Grace", :added ])
  end

  it "reports the record an association passes through when it moves the association's records" do
    Review.create!(book: book, rating: 5)
    Author.watches(association: :reviews, callback: record_change, inline: true)

    book.update!(author: grace)

    aggregate_failures do
      expect(seen.map { |owner, change| [ owner, change.kind ] }).to contain_exactly([ "Ada", :removed ], [ "Grace", :added ])
      expect(seen.map { |_, change| change.record }.uniq).to eq([ book ])
    end
  end

  it "tells the owner of a record reached through a belongs_to source that it changed, whatever keys of its own it changes" do
    Mention.create!(author: ada, subject: book)
    Author.watches(association: :mentioned_books, callback: record_change, inline: true)

    book.update!(author: grace)

    expect(change_for("Ada").sole).to have_attributes(kind: :changed, record: book)
  end

  it "tells the records that belong to a changed record that it changed" do
    book
    Book.watches(association: :author, callback: ->(changed_book, change) { seen << [ changed_book.title, change ] }, inline: true)

    ada.update!(name: "Ada Lovelace")

    expect(seen.sole.last).to have_attributes(kind: :changed, record: ada, changed_attributes: a_collection_including("name"))
  end

  it "leaves the kind and previous owners unknown for a scoped association, whose scope can take in a record without a key changing" do
    book
    Author.watches(association: :published_books, callback: record_change, inline: true)

    book.update!(published: true)

    change = change_for("Ada").sole
    aggregate_failures do
      expect(change).to have_attributes(kind: nil, previous_owners: nil)
      expect(change.owners).to contain_exactly(ada)
    end
  end

  context "on an association whose source is itself an association through another" do
    let(:other_book) { Book.create!(author: grace, title: "Other") }
    let(:review) { Review.create!(book: book, rating: 5) }
    let!(:comment) { Comment.create!(commentable: review, body: "Original") }

    before do
      other_book
      Author.watches(association: :review_comments, callback: record_change, inline: true)
    end

    it "leaves the kind and previous owners unknown when the record changes its own key" do
      comment.update!(commentable: Review.create!(book: other_book, rating: 1))

      change = change_for("Grace").sole
      aggregate_failures do
        expect(change).to have_attributes(kind: nil, previous_owners: nil, record: comment)
        expect(change.owners).to contain_exactly(grace)
      end
    end

    it "tells the owners of a moved record the association passes through first whether it was added or removed" do
      book.update!(author: grace)

      expect(seen.map { |owner, change| [ owner, change.kind ] }).to contain_exactly([ "Ada", :removed ], [ "Grace", :added ])
    end
  end

  context "with an affects: scope" do
    before do
      book
      Author.watches(class: "Book", affects: ->(changed) { Author.where(id: changed.author_id) }, callback: record_change, inline: true)
    end

    it "leaves the kind and previous owners unknown, since the scope may select owners by anything" do
      book.update!(title: "Changed")

      expect(change_for("Ada").sole).to have_attributes(kind: nil, previous_owners: nil)
    end

    it "tells the previous owners of a destroyed record it was removed" do
      book.destroy!

      expect(change_for("Ada").sole).to have_attributes(kind: :removed)
    end
  end
end
