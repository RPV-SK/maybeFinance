module Zoho
  # Decides which Account a lead's free-text company belongs to — or refuses to
  # decide, which is usually the right answer.
  #
  # Matching Account_Name exactly against lead Company finds a match about one
  # time in eight in practice, so an exact-match-then-create rule does not
  # "create the missing account", it manufactures duplicates. Measured against
  # this org's data: Feadship alone is spelled twelve ways across its leads
  # ("Royal Van Lent Shipyard", "Feadship Royal Van Lent", "87m Feadship") while
  # two Feadship Accounts already exist.
  #
  # So this returns one of four outcomes and only ever acts on the first:
  #
  #   :matched     — normalised names are identical; safe to link
  #   :ambiguous   — related accounts exist; a human picks, nothing is created
  #   :placeholder — the value names a vessel or is filler; never an Account
  #   :absent      — nothing resembling it exists; creating one is defensible
  #
  class AccountResolver
    Result = Struct.new(:status, :account_id, :account_name, :candidates, :company, keyword_init: true) do
      def matched?     = status == :matched
      def ambiguous?   = status == :ambiguous
      def placeholder? = status == :placeholder
      def absent?      = status == :absent
      def creatable?   = absent?

      def to_s
        case status
        when :matched
          "Company #{company.inspect} -> Account #{account_name.inspect} (#{account_id})."
        when :ambiguous
          listed = candidates.map { |c| "#{c["Account_Name"].inspect} (#{c["id"]})" }.join(", ")
          "Company #{company.inspect} looks like an existing Account but is not an exact match: #{listed}. " \
            "Not linking and not creating — pass the account id you want."
        when :placeholder
          "Company #{company.inspect} names a vessel or is a placeholder, not a company. No Account will be created."
        else
          "No Account resembles #{company.inspect}."
        end
      end
    end

    def initialize(client:)
      @client = client
    end

    def resolve(company)
      company = company.to_s.strip
      return Result.new(status: :absent, candidates: [], company: company) if company.blank?
      return Result.new(status: :placeholder, candidates: [], company: company) if CompanyName.placeholder?(company)

      candidates = search(company)

      exact = candidates.find { |account| CompanyName.same?(company, account["Account_Name"]) }
      if exact
        return Result.new(
          status: :matched,
          account_id: exact["id"],
          account_name: exact["Account_Name"],
          candidates: candidates,
          company: company
        )
      end

      related = candidates.select { |account| CompanyName.related?(company, account["Account_Name"]) }
      return Result.new(status: :ambiguous, candidates: related, company: company) if related.any?

      Result.new(status: :absent, candidates: [], company: company)
    end

    private
      attr_reader :client

      # Search on tokens rather than the whole string, so "Feadship Royal Van
      # Lent" still surfaces "FEADSHIP" and "MB92 Barcelona" surfaces "MB92".
      def search(company)
        tokens = CompanyName.search_tokens(company)
        return [] if tokens.empty?

        conditions = tokens.map { |token| "Account_Name like '%#{escape(token)}%'" }

        # A broad token ("van") can match dozens of unrelated accounts, so take
        # the maximum page rather than risk truncating the real match away.
        client.query("select id, Account_Name from Accounts where #{or_clause(conditions)} limit 200")
          .uniq { |account| account["id"] }
      end

      # COQL rejects a flat `a or b or c`; conditions past the second must be
      # explicitly nested.
      def or_clause(conditions)
        conditions.reduce { |combined, condition| "(#{combined} or #{condition})" }
      end

      def escape(token)
        token.gsub("'", "''")
      end
  end
end
