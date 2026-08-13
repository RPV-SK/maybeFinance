require "test_helper"

class Zoho::AccountResolverTest < ActiveSupport::TestCase
  # Mirrors the real Accounts module: Feadship already exists twice, MB92 once
  # under a shorter name than any lead uses.
  ACCOUNTS = [
    { "id" => "1", "Account_Name" => "FEADSHIP" },
    { "id" => "2", "Account_Name" => "Royal van Lent Shipyard B.V. (Feadship)" },
    { "id" => "3", "Account_Name" => "MB92" },
    { "id" => "4", "Account_Name" => "Alewijnse Marine Systems" },
    { "id" => "5", "Account_Name" => "Alewijnse" },
    { "id" => "6", "Account_Name" => "Sunreef Yachts" }
  ].freeze

  class FakeClient
    attr_reader :queries

    def initialize
      @queries = []
    end

    def query(coql)
      @queries << coql
      tokens = coql.scan(/like '%(.*?)%'/).flatten.map(&:downcase)
      ACCOUNTS.select { |account| tokens.any? { |token| account["Account_Name"].downcase.include?(token) } }
    end
  end

  setup do
    @client = FakeClient.new
    @resolver = Zoho::AccountResolver.new(client: @client)
  end

  test "links only on an exact normalised match" do
    result = @resolver.resolve("Sunreef Yachts B.V.")

    assert result.matched?
    assert_equal "6", result.account_id
  end

  test "refuses to act when the company resembles existing accounts" do
    result = @resolver.resolve("Feadship Royal Van Lent")

    assert result.ambiguous?
    assert_not result.creatable?
    assert_equal %w[1 2], result.candidates.map { |c| c["id"] }.sort
    assert_match "not an exact match", result.to_s
  end

  test "MB92 Barcelona does not become a second MB92" do
    result = @resolver.resolve("MB92 Barcelona")

    assert result.ambiguous?
    assert_equal [ "3" ], result.candidates.map { |c| c["id"] }
  end

  test "vessels and placeholders never become accounts" do
    [ "87m Feadship", "Private Yacht", "M/Y Amadeus", "Motoryacht" ].each do |value|
      result = @resolver.resolve(value)

      assert result.placeholder?, "#{value.inspect} should be a placeholder"
      assert_not result.creatable?
    end
  end

  test "a genuinely new company is creatable" do
    result = @resolver.resolve("INTERNATIONAL MARINE SYSTEM SARL")

    assert result.absent?
    assert result.creatable?
  end

  test "searches on every identifying token, not just the longest" do
    @resolver.resolve("Feadship Royal Van Lent")

    assert_match "feadship", @client.queries.first
    assert_match "royal", @client.queries.first
  end
end
