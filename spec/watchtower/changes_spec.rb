RSpec.describe "Watchtower triggers on saves, moves and destroys" do
  let(:author) { Author.create!(name: "Ada") }
  let(:other_author) { Author.create!(name: "Grace") }
  let(:book) { Book.create!(author: author, title: "Original") }

  # Matches a block that reindexes each of `authors` `times` times, as `expect { ... }.to reindex(author)`.
  def reindex(*authors, times: 1)
    authors.map { |each| change { each.reload.reindex_count }.by(times) }.reduce(:and)
  end

  # Matches a block that reindexes none of `authors`.
  def not_reindex(*authors)
    authors.map { |each| not_change { each.reload.reindex_count } }.reduce(:and)
  end

  def selects_during
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].start_with?("SELECT") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  RSpec::Matchers.define_negated_matcher :not_change, :change
  RSpec::Matchers.define_negated_matcher :not_have_enqueued_job, :have_enqueued_job

  context "with a queued trigger" do
    around { |example| perform_enqueued_jobs { example.run } }

    context "on a direct association" do
      before { Author.watches(association: :books, callback: :reindex!) }

      it "runs on the owner of a destroyed record" do
        book
        expect { book.destroy! }.to reindex(author)
      end

      it "runs on the owners a record moves between" do
        book
        expect { book.update!(author: other_author) }.to reindex(author, other_author)
      end
    end

    it "runs on the owners a record moves between when the trigger watches other attributes" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      book

      expect { book.update!(author: other_author) }.to reindex(author, other_author)
    end

    it "reads no more in the saving thread than a save without the trigger" do
      book
      without_trigger = selects_during { perform_enqueued_jobs(only: []) { book.update!(title: "Untriggered") } }
      Author.watches(association: :books, callback: :reindex!)

      with_trigger = selects_during { perform_enqueued_jobs(only: []) { book.update!(author: other_author) } }
      expect(with_trigger).to eq(without_trigger)
    end

    context "on an association through another" do
      before { Author.watches(association: :reviews, callback: :reindex!) }

      let(:review) { Review.create!(book: book, rating: 5) }

      it "runs on the owner of a destroyed record" do
        review
        expect { review.destroy! }.to reindex(author)
      end

      it "runs on the owners a record moves between" do
        review
        other_book = Book.create!(author: other_author, title: "Other")

        expect { review.update!(book: other_book) }.to reindex(author, other_author)
      end

      it "runs on the owners the record it passes through moves between" do
        review
        expect { book.update!(author: other_author) }.to reindex(author, other_author)
      end

      it "does not run on another change to the record it passes through" do
        review
        expect { book.update!(title: "Renamed") }.to not_reindex(author)
      end
    end

    context "on an association through a record that holds the source's key" do
      before { Author.watches(association: :publishers, callback: :reindex!) }

      let(:publisher) { Publisher.create!(name: "Penguin") }

      it "runs on the owners of a destroyed record" do
        book.update!(publisher: publisher)
        expect { publisher.destroy! }.to reindex(author)
      end

      it "runs when the record it passes through changes the key" do
        book
        expect { book.update!(publisher: publisher) }.to reindex(author)
      end
    end

    context "on a polymorphic association" do
      before { Author.watches(association: :comments, callback: :reindex!) }

      it "runs on the owner a record moves away from to another type" do
        comment = Comment.create!(commentable: author, body: "Hi")
        expect { comment.update!(commentable: book) }.to reindex(author)
      end

      it "does not run on an owner of another type that shares the key" do
        comment = Comment.create!(commentable: Book.create!(author: other_author, title: "Same id"), body: "Hi")
        Author.where(id: comment.commentable_id).first_or_create!(name: "Shares the id")
        owner = Author.find(comment.commentable_id)

        expect { comment.destroy! }.to not_reindex(owner)
      end
    end

    it "runs on the audience an `affects:` scope returned for a destroyed record" do
      Author.watches(class: "Book", affects: ->(changed) { Author.where(id: changed.author_id) }, callback: :reindex!)
      book

      expect { book.destroy! }.to reindex(author)
    end

    it "watches the record it passes through for a trigger declared before the association, once the observer reinitializes" do
      late_author = Class.new(ApplicationRecord) do
        self.table_name = "authors"

        def reindex!
          increment!(:reindex_count)
        end
      end
      stub_const("LateAuthor", late_author)
      LateAuthor.watches(association: :reviews, class: "Review", callback: :reindex!)
      LateAuthor.has_many :books, foreign_key: :author_id
      LateAuthor.has_many :reviews, through: :books
      Watchtower::Observer.reinitialize
      Review.create!(book: book, rating: 5)

      expect { book.update!(author: other_author) }.to reindex(author, other_author)
    end

    it "does not run a trigger on one subclass for a destroyed record of a sibling subclass" do
      Author.watches(association: :books, callback: ->(_author) { })
      Author.watches(association: :novels, callback: :reindex!)
      poem = Poem.create!(author: author, title: "Ode")

      expect { poem.destroy! }.to not_reindex(author)
    end

    context "on an association through a polymorphic source" do
      before { Author.watches(association: :mentioned_books, callback: :reindex!) }

      it "runs on the owners of a destroyed record, and not on the owners of another type's record with its id" do
        mentioned = Book.create!(id: 500, author: other_author, title: "Mentioned")
        Mention.create!(author: author, subject: mentioned)
        Mention.create!(author: other_author, subject: Publisher.create!(id: 500, name: "Same id"))

        expect { mentioned.destroy! }.to reindex(author).and not_reindex(other_author)
      end
    end

    # The association's source, `Book#review_comments`, is itself a `has_many :through` the reviews. Watchtower
    # watches the comments and the books, but not the reviews inside the source.
    context "on an association whose source is itself an association through another" do
      let(:other_book) { Book.create!(author: other_author, title: "Other") }
      let(:review) { Review.create!(book: book, rating: 5) }
      let!(:comment) { Comment.create!(commentable: review, body: "Original") }

      before do
        other_book
        Author.watches(association: :review_comments, callback: :reindex!)
      end

      it "runs on the owner of a changed record" do
        expect { comment.update!(body: "Changed") }.to reindex(author).and not_reindex(other_author)
      end

      it "runs on the owners before and after a move of the record the association passes through first" do
        expect { book.update!(author: other_author) }.to reindex(author, other_author)
      end

      it "runs on the owner of a destroyed record the association passes through first" do
        expect { book.destroy! }.to reindex(author)
      end

      it "runs only on the new owner of a moved record" do
        other_review = Review.create!(book: other_book, rating: 1)

        expect { comment.update!(commentable: other_review) }.to reindex(other_author).and not_reindex(author)
      end

      it "runs on no owner of a destroyed record" do
        expect { comment.destroy! }.to not_reindex(author, other_author)
      end

      it "runs on no owner when a record inside the source moves or is destroyed" do
        aggregate_failures do
          expect { review.update!(book: other_book) }.to not_reindex(author, other_author)
          expect { review.destroy! }.to not_reindex(author, other_author)
        end
      end
    end

    it "runs an enabled trigger that shares its association and callback with a disabled one" do
      Author.watches(association: :books, callback: :reindex!, around: ->(&callbacks) { callbacks.call }, enabled: -> { false })
      Author.watches(association: :books, callback: :reindex!, around: ->(&callbacks) { callbacks.call })
      book

      expect { book.update!(title: "Renamed") }.to reindex(author)
    end

    it "runs a callback once per owner when several triggers reach it" do
      Author.watches(association: :books, attribute: :title, callback: :reindex!)
      Author.watches(association: :books, attribute: :genre, callback: :reindex!)
      book

      expect { book.update!(title: "Renamed", genre: "Poetry") }.to reindex(author)
    end
  end

  context "with an around block" do
    around { |example| perform_enqueued_jobs { example.run } }

    let(:calls) { [] }

    def wrapping(calls, name)
      lambda do |&run|
        calls << :"#{name}_before"
        run.call
        calls << :"#{name}_after"
      end
    end

    it "runs every callback of the change inside the block, once" do
      Author.watches(association: :books, callback: ->(_author) { calls << :callback }, around: wrapping(calls, :batch))
      book

      calls.clear
      book.update!(author: other_author)

      expect(calls).to eq(%i[batch_before callback callback batch_after])
    end

    it "runs an inline trigger's callbacks inside the block" do
      Author.watches(association: :books, callback: ->(_author) { calls << :callback }, inline: true, around: wrapping(calls, :batch))
      book

      calls.clear
      book.update!(title: "Renamed")

      expect(calls).to eq(%i[batch_before callback batch_after])
    end

    it "runs triggers that share a callback but not a block inside each of their blocks" do
      callback = ->(_author) { calls << :callback }
      Author.watches(association: :books, callback: callback, around: wrapping(calls, :first))
      Author.watches(association: :books, attribute: :title, callback: callback, around: wrapping(calls, :second))
      book

      calls.clear
      book.update!(title: "Renamed")

      expect(calls).to eq(%i[first_before callback first_after second_before callback second_after])
    end
  end

  context "with an inline trigger" do
    before { Author.watches(association: :books, callback: :reindex!, inline: true) }

    it "runs in the saving thread and queues no job" do
      book
      expect { book.update!(title: "Changed") }.to reindex(author).and not_have_enqueued_job(Watchtower::Job)
    end

    it "runs on the owner of a destroyed record" do
      book
      expect { book.destroy! }.to reindex(author)
    end

    it "does not run when the transaction rolls back" do
      book
      expect { Book.transaction { book.update!(title: "Changed") and raise ActiveRecord::Rollback } }.to not_reindex(author)
    end

    it "runs once at the commit, on the owners before and after the transaction, when a record moves twice" do
      third_author = Author.create!(name: "Barbara")
      book

      expect { Book.transaction { book.update!(author: other_author) and book.update!(author: third_author) } }
        .to reindex(author, third_author).and not_reindex(other_author)
    end

    it "runs on what an enclosing transaction commits when a savepoint within it rolls back" do
      book

      expect do
        Book.transaction do
          book.update!(title: "Outer")
          Book.transaction(requires_new: true) do
            book.update!(title: "Inner")
            raise ActiveRecord::Rollback
          end
        end
      end.to reindex(author)
    end

    it "does not run while its enabled predicate is false at the commit, though it was true at the save" do
      enabled = true
      Author.watches(association: :reviews, callback: :reindex!, inline: true, enabled: -> { enabled })
      review = Review.create!(book: book, rating: 5)

      expect { Review.transaction { review.update!(rating: 4) and enabled = false } }.to not_reindex(author)
    end
  end
end
