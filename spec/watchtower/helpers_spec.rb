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
end
