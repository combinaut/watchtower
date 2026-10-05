RSpec.describe Watchtower::Helpers do
  describe ".constantize" do
    it "resolves a string to the named class" do
      expect(described_class.constantize("Author")).to eq(Author)
    end

    it "returns a class unchanged" do
      expect(described_class.constantize(Author)).to eq(Author)
    end
  end

  describe ".evaluate" do
    let(:author) { Author.new(name: "Ada") }

    it "calls a zero-arity proc without the receiver" do
      expect(described_class.evaluate(-> { 42 }, author)).to eq(42)
    end

    it "calls a positive-arity proc with the receiver" do
      expect(described_class.evaluate(->(record) { record.name }, author)).to eq("Ada")
    end

    it "sends a symbol to the receiver" do
      expect(described_class.evaluate(:name, author)).to eq("Ada")
    end

    it "sends a string to the receiver" do
      expect(described_class.evaluate("name", author)).to eq("Ada")
    end

    it "raises for an unsupported callable" do
      expect { described_class.evaluate(42, author) }.to raise_error(/Unhandled callable/)
    end
  end

  describe ".callback_wants_change?" do
    it "is true for a proc with a second parameter" do
      expect(described_class.callback_wants_change?(->(_author, _change) { }, Author)).to be(true)
    end

    it "is false for a proc that takes only the record" do
      expect(described_class.callback_wants_change?(->(_author) { }, Author)).to be(false)
    end

    it "is true for a method with a required parameter" do
      klass = Class.new(Author) { def book_changed(change) = change }

      expect(described_class.callback_wants_change?(:book_changed, klass)).to be(true)
    end

    it "is false for a method the class answers through method_missing" do
      klass = Class.new(Author) do
        def method_missing(name, *args) = name == :dynamic_callback ? :called : super
        def respond_to_missing?(name, include_private = false) = name == :dynamic_callback || super
      end

      expect(described_class.callback_wants_change?(:dynamic_callback, klass)).to be(false)
    end

    it "is false for a method with no parameters, or only optional ones" do
      aggregate_failures do
        expect(described_class.callback_wants_change?(:reindex!, Author)).to be(false)
        expect(described_class.callback_wants_change?(:touch, Author)).to be(false), "touch takes only optional arguments"
      end
    end
  end
end
