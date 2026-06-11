# End-to-end: a real save flows observer -> enqueued job -> callback on the audience.
RSpec.describe "Watchtower end-to-end", type: :model do
  let!(:author) { Author.create!(name: "Ada") }
  let!(:book) { Book.create!(author: author, title: "Original") }

  it "reindexes the owner when a watched association record changes" do
    Author.watches(association: :books, callback: :reindex!)

    expect { perform_enqueued_jobs { book.update!(title: "Changed") } }
      .to change { author.reload.reindex_count }.by(1)
  end

  it "reindexes the owner when a new watched association record is created" do
    Author.watches(association: :books, callback: :reindex!)

    expect { perform_enqueued_jobs { Book.create!(author: author, title: "Second") } }
      .to change { author.reload.reindex_count }.by(1)
  end

  it "does not reindex while the trigger's enabled predicate is false" do
    gate = { open: false }
    Author.watches(association: :books, callback: :reindex!, enabled: -> { gate[:open] })

    expect { perform_enqueued_jobs { book.update!(title: "Quiet") } }
      .not_to(change { author.reload.reindex_count })
  end

  it "reindexes once the enabled predicate opens again" do
    gate = { open: false }
    Author.watches(association: :books, callback: :reindex!, enabled: -> { gate[:open] })

    perform_enqueued_jobs { book.update!(title: "Quiet") }
    gate[:open] = true

    expect { perform_enqueued_jobs { book.update!(title: "Loud") } }
      .to change { author.reload.reindex_count }.by(1)
  end
end
