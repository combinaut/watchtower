RSpec.describe "Watchtower triggers on saves, moves and destroys" do
  let(:author) { Author.create!(name: "Ada") }
  let(:other_author) { Author.create!(name: "Grace") }
  let(:book) { Book.create!(author: author, title: "Original") }

  def reindexes(*authors)
    authors.map { |each| change { each.reload.reindex_count }.by(1) }.reduce(:and)
  end

  context "with a queued trigger" do
    around { |example| perform_enqueued_jobs { example.run } }

    it "runs a callback once per owner when several triggers reach it" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      Author.watches(association: :books, attribute: :genre, callback: :reindex!)
      book

      expect { book.update!(title: "Renamed", genre: "Poetry") }.to reindexes(author)
    end
  end
end
