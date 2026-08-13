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
  # Crucially, a near-match is *not* evidence of a duplicate. Feadship's yards —
  # Royal Van Lent, De Voogt, De Vries — are separate legal entities that must
  # stay separate, parented to a Feadship group account. Only a human knows which
  # near-matches are the same business and which are siblings, so this reports
  # and defers rather than merging.
  #
  # Outcomes, of which only :matched is acted on unattended:
  #
  #   :matched     — Account_Name or a recorded alias matches; safe to link
  #   :ambiguous   — related accounts exist; may be the same business or a
  #                  sibling in the same group. A human decides.
  #   :vessel      — names a vessel or build project. Belongs in Vessels, linked
  #                  to an Account, never invented as a company.
  #   :placeholder — filler; names nothing
  #   :absent      — nothing resembling it exists; creating one is defensible
  #
  class AccountResolver
    Result = Struct.new(
      :status, :account_id, :account_name, :candidates, :company, :vessel_id, :vessel_name,
      keyword_init: true
    ) do
      def matched?     = status == :matched
      def ambiguous?   = status == :ambiguous
      def vessel?      = status == :vessel
      def placeholder? = status == :placeholder
      def absent?      = status == :absent

      # Only a genuinely new, genuinely company-shaped name may be created
      # unattended. A vessel may be created too, but only carrying its Vessel
      # link — see Runner.
      def creatable? = absent?

      def to_s
        case status
        when :matched
          "Company #{company.inspect} -> Account #{account_name.inspect} (#{account_id})."
        when :ambiguous
          listed = candidates.map { |c| "#{c["Account_Name"].inspect} (#{c["id"]})" }.join(", ")
          "Company #{company.inspect} resembles existing Accounts without matching one: #{listed}. " \
            "These may be the same business or separate entities in one group — linking and creation skipped. " \
            "Resolve it once by adding #{company.inspect} to that Account's Aliases field."
        when :vessel
          if vessel_id
            "Company #{company.inspect} names a vessel -> Vessel #{vessel_name.inspect} (#{vessel_id}). " \
              "Any Account created for it will be linked to that vessel rather than named after its builder."
          else
            "Company #{company.inspect} names a vessel or build project, but no matching Vessel record was found. " \
              "Add it to the Vessels module first — it must not become an Account named after its builder."
          end
        when :placeholder
          "Company #{company.inspect} is filler, not a company. No Account will be created."
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

      candidates = search_accounts(company)

      if (exact = exact_match(company, candidates))
        return Result.new(
          status: :matched,
          account_id: exact["id"],
          account_name: exact["Account_Name"],
          candidates: candidates,
          company: company
        )
      end

      # Checked after an exact/alias match, so a vessel-owning entity already
      # recorded as an Account still resolves straight to it.
      return vessel_result(company) if CompanyName.vessel?(company)

      related = candidates.select { |account| CompanyName.related?(company, account["Account_Name"]) }
      return Result.new(status: :ambiguous, candidates: related, company: company) if related.any?

      Result.new(status: :absent, candidates: [], company: company)
    end

    private
      attr_reader :client

      # An alias recorded by a human is as good as the name itself — better, in
      # fact, since it encodes a decision already made.
      def exact_match(company, candidates)
        candidates.find { |account| CompanyName.same?(company, account["Account_Name"]) } ||
          candidates.find { |account| alias_match?(company, account["Aliases"]) }
      end

      def alias_match?(company, aliases)
        aliases.to_s.split(/[\n,;]/).any? { |candidate| CompanyName.same?(company, candidate) }
      end

      def vessel_result(company)
        name = CompanyName.vessel_name(company)
        vessel = search_vessels(name).first

        Result.new(
          status: :vessel,
          candidates: [],
          company: company,
          vessel_id: vessel && vessel["id"],
          vessel_name: vessel && vessel["Name"]
        )
      end

      # Search on tokens rather than the whole string, so "Feadship Royal Van
      # Lent" still surfaces "FEADSHIP" and "MB92 Barcelona" surfaces "MB92".
      # Aliases are searched alongside the name.
      def search_accounts(company)
        tokens = CompanyName.search_tokens(company)
        return [] if tokens.empty?

        conditions = tokens.flat_map do |token|
          [ "Account_Name like '%#{escape(token)}%'", "Aliases like '%#{escape(token)}%'" ]
        end

        # A broad token ("van") can match dozens of unrelated accounts, so take
        # the maximum page rather than risk truncating the real match away.
        client.query(
          "select id, Account_Name, Aliases, Parent_Account from Accounts where #{or_clause(conditions)} limit 200"
        ).uniq { |account| account["id"] }
      end

      def search_vessels(name)
        tokens = CompanyName.search_tokens(name)
        return [] if tokens.empty?

        conditions = tokens.map { |token| "Name like '%#{escape(token)}%'" }
        results = client.query("select id, Name from Vessels where #{or_clause(conditions)} limit 50")

        # Prefer an exact name hit over a token-overlap one.
        exact = results.find { |vessel| CompanyName.same?(name, vessel["Name"]) }
        exact ? [ exact ] : results
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
