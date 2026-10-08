RSpec.describe "Watchtower.report_changes" do
  let(:author) { Author.create!(name: "Ada") }
  let(:other_author) { Author.create!(name: "Grace") }
  let!(:persuasion) { Book.create!(author: author, title: "Persuasion") }
  let!(:emma) { Book.create!(author: author, title: "Emma") }

  # Retitles `books` without callbacks, as `update_all` does, and reports the change.
  def retitle_without_callbacks(*books)
    Book.where(id: books.map(&:id)).update_all(title: "Retitled")
    Watchtower.report_changes(books, attributes: [ :title ])
  end

  def reindex(*authors, times: 1)
    authors.map { |each| change { each.reload.reindex_count }.by(times) }.reduce(:and)
  end

  def not_reindex(*authors)
    authors.map { |each| not_change { each.reload.reindex_count } }.reduce(:and)
  end

  RSpec::Matchers.define_negated_matcher :not_change, :change

  it "runs a queued trigger on the watchers of the reported records, once per watcher" do
    Author.watches(association: :books, callback: :reindex!)

    expect { perform_enqueued_jobs { retitle_without_callbacks(persuasion, emma) } }.to reindex(author)
  end

  it "reads a record's predicate against the record as written" do
    Author.watches(association: :books, callback: :reindex!, inline: true, enabled: :published?)

    expect do
      Book.where(id: persuasion.id).update_all(published: true)
      Watchtower.report_changes([ persuasion ], attributes: [ :published ])
    end.to reindex(author)
  end

  it "fires at the commit of the transaction it is called in" do
    Author.watches(association: :books, callback: :reindex!, inline: true)

    Book.transaction do
      expect { retitle_without_callbacks(persuasion) }.to not_reindex(author)
    end

    expect(author.reload.reindex_count).to eq(1)
  end

  it "reads an enabled predicate when the change is reported" do
    enabled = true
    Author.watches(association: :books, callback: :reindex!, inline: true, enabled: -> { enabled })

    expect do
      Book.transaction do
        enabled = false
        retitle_without_callbacks(persuasion)
        enabled = true
      end
    end.to not_reindex(author)
  end

  it "fires nothing for a change reported in a savepoint that rolls back" do
    Author.watches(association: :books, callback: :reindex!, inline: true)

    expect do
      Book.transaction do
        Book.transaction(requires_new: true) do
          retitle_without_callbacks(persuasion)
          raise ActiveRecord::Rollback
        end
      end
    end.to not_reindex(author)
  end

  it "combines a reported change with a save of the same row" do
    Author.watches(association: :books, callback: :reindex!, inline: true)

    expect do
      Book.transaction do
        retitle_without_callbacks(persuasion)
        persuasion.reload.update!(title: "Persuasion: A Novel")
      end
    end.to reindex(author)
  end

  it "runs an at: :save trigger as the change is reported" do
    Author.watches(association: :books, callback: :reindex!, inline: true, at: :save)

    Book.transaction do
      retitle_without_callbacks(persuasion)
      expect(author.reload.reindex_count).to eq(1), "the callback runs before the commit"
    end
  end

  it "raises for an attribute that ties the record to its watchers, and records nothing" do
    Author.watches(association: :books, callback: :reindex!, inline: true)

    expect { Watchtower.report_changes([ persuasion ], attributes: [ :author_id ]) }
      .to raise_error(ArgumentError, /author_id/)
      .and not_reindex(author)
  end

  it "fires commit-time triggers when the observer records a change outside a transaction" do
    Author.watches(association: :books, callback: :reindex!, inline: true)
    Book.where(id: persuasion.id).update_all(title: "Retitled")

    expect { Watchtower::Observer.instance.report_changes([ persuasion ], attributes: [ :title ]) }.to reindex(author)
  end

  it "returns nil" do
    Author.watches(association: :books, callback: :reindex!)
    expect(retitle_without_callbacks(persuasion)).to be_nil
  end

  it "does nothing for records no trigger watches" do
    expect { Watchtower.report_changes([ other_author ], attributes: [ :name ]) }.not_to raise_error
  end
end
