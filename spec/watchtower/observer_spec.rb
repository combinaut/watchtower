RSpec.describe Watchtower::Observer do
  describe ".build_trigger" do
    it "raises without an observing class" do
      expect { described_class.build_trigger(callback: :reindex!) }
        .to raise_error(ArgumentError, /observing class/)
    end

    it "infers the observed class from the association reflection" do
      trigger = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!)
      expect(trigger.class).to eq(Book)
    end

    it "raises for an unknown association" do
      expect { described_class.build_trigger(observing_class: Author, association: :nonsense, callback: :reindex!) }
        .to raise_error(ArgumentError, /Unknown association/)
    end

    it "constantizes an explicit string class" do
      trigger = described_class.build_trigger(observing_class: Author, class: "Book", affects: -> { }, callback: :reindex!)
      expect(trigger.class).to eq(Book)
    end

    it "aliases :attribute to an :attributes array" do
      trigger = described_class.build_trigger(observing_class: Author, association: :books, attribute: :title, callback: :reindex!)
      expect(trigger.attributes).to eq([ :title ])
    end

    it "defaults enabled to nil" do
      trigger = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!)
      expect(trigger.enabled).to be_nil
    end

    it "fires at the commit unless told otherwise" do
      trigger = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!)
      expect(trigger.at).to eq(:commit)
    end

    it "answers which point it fires at" do
      at_commit = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!)
      at_save = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, at: :save, inline: true)

      expect([ at_commit.at_commit?, at_commit.at_save?, at_save.at_commit?, at_save.at_save? ]).to eq([ true, false, false, true ])
    end

    it "raises for an at: other than :commit or :save" do
      [ :before_save, 1, false ].each do |at|
        expect { described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, at: at) }
          .to raise_error(ArgumentError, /at: must be one of \[:commit, :save\]/), "at: #{at.inspect}"
      end
    end

    context "while Active Job enqueues Watchtower::Job after the transaction commits" do
      around do |example|
        original = Watchtower::Job.enqueue_after_transaction_commit
        Watchtower::Job.enqueue_after_transaction_commit = true
        example.run
      ensure
        Watchtower::Job.enqueue_after_transaction_commit = original
      end

      it "raises for a queued trigger that fires at the save, whose job would wait for the commit" do
        expect { described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, at: :save) }
          .to raise_error(ArgumentError, /enqueue_after_transaction_commit/)
      end

      it "reads a truthy value kept from an earlier Rails as deferring on Rails 8.1" do
        skip "Rails before 8.1 reads :never as not deferring" if ActiveJob.version < Gem::Version.new("8.1")

        Watchtower::Job.enqueue_after_transaction_commit = :never

        expect(Watchtower::Job.enqueued_after_commit?).to be(true)
      end

      it "accepts an inline trigger that fires at the save, which enqueues nothing" do
        expect { described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, at: :save, inline: true) }
          .not_to raise_error
      end
    end

    it "retains an enabled predicate" do
      predicate = -> { true }
      trigger = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, enabled: predicate)
      expect(trigger.enabled).to eq(predicate)
    end
  end

  describe Watchtower::Observer::Trigger do
    describe "#key" do
      it "is a stable string of observing class, callback, and association" do
        trigger = described_class.new(observing_class: Author, callback: :reindex!, association: :books)
        expect(trigger.key).to eq("Author/reindex!/books")
      end

      it "keeps triggers on one association with one callback apart by their attributes, enabled and around" do
        plain = described_class.new(observing_class: Author, callback: :reindex!, association: :books)
        keys = [
          plain,
          plain.dup.tap { |trigger| trigger.attributes = [ :title ] },
          plain.dup.tap { |trigger| trigger.enabled = -> { false } },
          plain.dup.tap { |trigger| trigger.around = ->(&block) { block.call } }
        ].map(&:key)

        expect(keys.uniq.size).to eq(4)
      end

      it "names a Proc by where it is defined rather than by its address" do
        trigger = described_class.new(observing_class: Author, callback: ->(author) { author.reindex! }, association: :books)

        expect(trigger.key).to match(%r{\AAuthor/\S*spec/watchtower/observer_spec\.rb:\d+/books\z})
      end
    end
  end

  describe ".add_trigger" do
    it "registers the trigger and observes the changed class" do
      Author.watches(association: :books, callback: :reindex!)

      expect(described_class.observable_classes).to include(Book)
    end
  end

  describe "a queued trigger" do
    let(:author) { Author.create!(name: "Ada") }
    let(:book) { Book.create!(author: author, title: "Original") }

    before { book } # ensure it exists before clearing the queue

    it "enqueues a job carrying the change payload" do
      Author.watches(association: :books, callback: :reindex!)
      clear_enqueued_jobs

      expect { book.update!(title: "Changed") }
        .to have_enqueued_job(Watchtower::Job)
        .with(hash_including(record_class: "Book", record_id: book.id, destroyed: false))
    end

    context "with an enabled predicate" do
      it "enqueues normally when the only trigger is enabled" do
        Author.watches(association: :books, callback: :reindex!, enabled: -> { true })
        clear_enqueued_jobs

        expect { book.update!(title: "Changed") }.to have_enqueued_job(Watchtower::Job)
      end

      it "does not enqueue when every matching trigger is disabled" do
        Author.watches(association: :books, callback: :reindex!, enabled: -> { false })
        clear_enqueued_jobs

        expect { book.update!(title: "Changed") }.not_to have_enqueued_job(Watchtower::Job)
      end

      it "enqueues but records the disabled trigger's key when another trigger stays enabled" do
        Author.watches(association: :books, callback: :reindex!, enabled: -> { false })
        Author.watches(association: :books, callback: :touch, enabled: -> { true })
        clear_enqueued_jobs

        expect { book.update!(title: "Changed") }
          .to have_enqueued_job(Watchtower::Job)
          .with(hash_including(suppressed_trigger_keys: [ a_string_starting_with("Author/reindex!/books/enabled:") ]))
      end

      it "enqueues nothing when the only save that enabled it rolled back in a savepoint" do
        Author.watches(association: :books, callback: :reindex!, enabled: -> { Thread.current[:watchtower_spec_enabled] == true })
        clear_enqueued_jobs

        expect do
          Book.transaction do
            book.update!(title: "Outer")
            Book.transaction(requires_new: true) do
              Thread.current[:watchtower_spec_enabled] = true
              book.update!(title: "Inner")
              Thread.current[:watchtower_spec_enabled] = false
              raise ActiveRecord::Rollback
            end
          end
        end.not_to have_enqueued_job(Watchtower::Job)
      ensure
        Thread.current[:watchtower_spec_enabled] = nil
      end

      it "reads the predicate when the change is saved, not when it commits" do
        Author.watches(association: :books, callback: :reindex!, enabled: -> { Thread.current[:watchtower_spec_enabled] == true })
        clear_enqueued_jobs

        expect do
          Book.transaction do
            Thread.current[:watchtower_spec_enabled] = false
            book.update!(title: "Changed")
            Thread.current[:watchtower_spec_enabled] = true
          end
        end.not_to have_enqueued_job(Watchtower::Job)
      ensure
        Thread.current[:watchtower_spec_enabled] = nil
      end
    end

    it "enqueues nothing for a change that rolls back" do
      Author.watches(association: :books, callback: :reindex!)
      clear_enqueued_jobs

      expect do
        Book.transaction do
          book.update!(title: "Changed")
          raise ActiveRecord::Rollback
        end
      end.not_to have_enqueued_job(Watchtower::Job)
    end

    it "enqueues one job for a row at the commit, carrying the changes saved through every instance of it" do
      Author.watches(association: :books, callback: :reindex!)
      other = Author.create!(name: "Grace")
      first = Book.find(book.id)
      second = Book.find(book.id)
      clear_enqueued_jobs

      Book.transaction do
        first.update!(title: "Changed")
        second.update!(author: other)
        expect(enqueued_jobs).to be_empty, "nothing is enqueued before the commit"
      end

      payloads = enqueued_jobs.select { |job| job["job_class"] == "Watchtower::Job" }.map { |job| ActiveJob::Arguments.deserialize(job["arguments"]).first }
      expect(payloads.size).to eq(1)
      expect(payloads.first).to include(changed_attributes: a_collection_including("title", "author_id"), previous_foreign_keys: { "author_id" => author.id })
    end

    it "holds nothing for a row whose only change rolls back" do
      Author.watches(association: :books, callback: :reindex!)

      Book.transaction do
        book.update!(title: "Changed")
        raise ActiveRecord::Rollback
      end

      expect(Book.connection.instance_variable_get(:@watchtower_held_changes)).to be_blank
    end

    it "enqueues one job for a record saved several times in one transaction, with the watcher from before the first save" do
      Author.watches(association: :books, callback: :reindex!)
      other = Author.create!(name: "Grace")
      third = Author.create!(name: "Hedy")
      clear_enqueued_jobs

      Book.transaction do
        book.update!(author: other)
        book.update!(author: third)
      end

      expect(enqueued_jobs.select { |job| job["job_class"] == "Watchtower::Job" }.size).to eq(1)
      expect(Watchtower::Job).to have_been_enqueued.with(hash_including(previous_foreign_keys: { "author_id" => author.id }))
    end

    it "reads a predicate against the instance the row was last saved through" do
      other = Author.create!(name: "Grace")
      Author.watches(association: :books, callback: :reindex!, enabled: ->(changed) { changed.author_id == other.id })
      first = Book.find(book.id)
      second = Book.find(book.id)
      clear_enqueued_jobs

      Book.transaction do
        first.update!(title: "Changed")
        second.update!(author: other)
      end

      expect(Watchtower::Job).to have_been_enqueued
    end

    it "enqueues a job of its own for a save made in a committing transaction's after_commit block" do
      Author.watches(association: :books, callback: :reindex!)
      other = Author.create!(name: "Grace")
      third = Author.create!(name: "Hedy")
      clear_enqueued_jobs

      Book.transaction do
        book.update!(author: other)
        Book.current_transaction.after_commit { book.update!(author: third) }
      end

      expect(Watchtower::Job).to have_been_enqueued.with(hash_including(previous_foreign_keys: { "author_id" => author.id }))
      expect(Watchtower::Job).to have_been_enqueued.with(hash_including(previous_foreign_keys: { "author_id" => other.id }))
    end
  end

  describe "a trigger that fires at: :save" do
    let(:author) { Author.create!(name: "Ada") }
    let(:book) { Book.create!(author: author, title: "Original") }

    before { book }

    it "has a key of its own" do
      at_commit = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!)
      at_save = described_class.build_trigger(observing_class: Author, association: :books, callback: :reindex!, at: :save)

      expect(at_save.key).to eq("#{at_commit.key}/at:save")
    end

    it "enqueues its job as the record saves, reading the predicate then" do
      gate = { open: true }
      Author.watches(association: :books, callback: :reindex!, at: :save, enabled: -> { gate[:open] })
      clear_enqueued_jobs

      Book.transaction do
        book.update!(title: "Changed")
        expect(Watchtower::Job).to have_been_enqueued, "the job is enqueued before the commit"
        gate[:open] = false
      end
    end

    it "reads a queued trigger's predicate after the inline callbacks have run" do
      gate = { open: true }
      Author.watches(association: :books, callback: ->(_author) { gate[:open] = false }, inline: true, at: :save)
      Author.watches(association: :books, callback: :reindex!, at: :save, enabled: -> { gate[:open] })
      clear_enqueued_jobs

      expect { book.update!(title: "Changed") }.not_to have_enqueued_job(Watchtower::Job)
    end

    it "runs an inline callback inside the transaction, so a rollback undoes what it wrote" do
      Author.watches(association: :books, callback: :reindex!, inline: true, at: :save)

      Book.transaction do
        book.update!(title: "Changed")
        expect(author.reload.reindex_count).to eq(1), "the callback runs before the commit"
        raise ActiveRecord::Rollback
      end

      expect(author.reload.reindex_count).to eq(0)
    end

    it "leaves the change a commit-time trigger fires on intact when a save-time predicate reloads the record" do
      Author.watches(association: :books, callback: :touch, inline: true, at: :save, enabled: ->(changed) { changed.reload && false })
      Author.watches(association: :books, callback: :reindex!)
      other = Author.create!(name: "Grace")
      clear_enqueued_jobs

      book.update!(author: other)

      expect(Watchtower::Job).to have_been_enqueued.with(hash_including(previous_foreign_keys: { "author_id" => author.id }))
    end

    it "enqueues a job apart from a trigger that fires at the commit, each naming the point it fires at" do
      Author.watches(association: :books, callback: :reindex!, at: :save)
      Author.watches(association: :books, callback: :touch)
      clear_enqueued_jobs

      book.update!(title: "Changed")

      jobs = enqueued_jobs.select { |job| job["job_class"] == "Watchtower::Job" }.map { |job| ActiveJob::Arguments.deserialize(job["arguments"]).first }
      aggregate_failures do
        expect(jobs.pluck(:at)).to contain_exactly(:save, :commit)
        expect(jobs.pluck(:suppressed_trigger_keys).compact).to be_empty, "no trigger is disabled"
      end
    end
  end
end
