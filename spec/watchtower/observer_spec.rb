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
    end
  end

  describe ".add_trigger" do
    it "registers the trigger and observes the changed class" do
      Author.watches(association: :books, callback: :reindex!)

      expect(described_class.observable_classes).to include(Book)
    end
  end

  describe "#after_save" do
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
          .with(hash_including(suppressed_trigger_keys: [ "Author/reindex!/books" ]))
      end
    end
  end
end
