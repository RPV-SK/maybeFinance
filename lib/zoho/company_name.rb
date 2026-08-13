require "set"

module Zoho
  # Normalising company names so "Royal Van Lent Shipyard", "Feadship Royal Van
  # Lent" and "Royal van Lent Shipyard B.V. (Feadship)" can be recognised as the
  # same yard rather than becoming three Accounts.
  #
  # Lead `Company` is free text typed by whoever filled the form or scraped from
  # LinkedIn, so exact string matching against Account_Name finds a match roughly
  # one time in eight. Everything else would become a duplicate.
  module CompanyName
    extend self

    # True legal forms only. Descriptive words like "Group", "Shipyard" or
    # "Marine" stay put — they are part of the name, and token overlap handles
    # them without guessing.
    LEGAL_SUFFIXES = %w[
      bv nv gmbh mbh ag kg ohg gbr sarl sas sa spa srl sl slu snc
      ltd ltda limited llc llp lp plc inc incorporated corp corporation
      oy oyj ab as asa aps apS pte pty kft doo dooel zoo sro
    ].freeze

    # Tokens too generic to establish identity on their own. Two names sharing
    # only these are not evidence of anything.
    GENERIC_TOKENS = %w[
      marine maritime marina marinas yacht yachts yachting boat boats ship ships
      shipping shipyard shipyards group holding holdings international worldwide
      global services service solutions systems technologies technology company
      companies design designs consulting consultants management the and of
    ].freeze

    # Filler: names nothing identifiable at all. Never an Account, never a Vessel.
    PLACEHOLDER_EXACT = [
      "private", "private yacht", "private company", "private client", "private owner",
      "yacht", "yachts", "motoryacht", "motor yacht", "sailing yacht", "superyacht",
      "super yacht", "super yachts", "none", "n a", "na", "nil", "unknown", "self",
      "self employed", "freelance", "retired", "student", "home", "confidential"
    ].freeze

    # Names a *specific* vessel or build project. Unlike filler, these are real
    # entities — they just belong in the Vessels module, linked to an Account,
    # rather than being invented as a company named after the builder.
    VESSEL_PATTERNS = [
      %r{\Am[/.]?[yv]\b}i,                       # "M/Y Amadeus", "MY Virtuosity"
      %r{\As[/.]?[yv]\b}i,                       # "S/Y Lionheart"
      /\A\d+\s*(m|ft|feet|metre|meter)s?\b/i,    # "87m Feadship", "96m Feadship"
      /\b\d+\s*(m|ft|feet|metre|meter)s?\+?\b/i, # "M/Y Feadship 75m+", "Sunseeker predator 82 feet"
      /\A(motor|sailing|sail)\s*yacht\s+\S/i,    # "Motor Yacht Serenity" (but not "Motor Yacht Build ltd")
      /\A(new ?build|hull)\b/i
    ].freeze

    # Prefixes stripped to recover the vessel's own name for a registry lookup.
    VESSEL_PREFIX = %r{\A(m[/.]?[yv]|s[/.]?[yv]|motor\s*yacht|sailing\s*yacht|superyacht)\b[\s.:-]*}i

    # Lowercased, de-accented, stripped of legal form and punctuation.
    #
    #   normalize("Royal van Lent Shipyard B.V. (Feadship)")
    #   # => "royal van lent shipyard feadship"
    def normalize(value)
      text = transliterate(value.to_s.downcase)
      # Drop periods before anything else, so "B.V." collapses to "bv" and is
      # recognisable as a legal suffix rather than splitting into "b" and "v".
      text = text.delete(".")
      text = text.gsub(/[^a-z0-9]+/, " ").squeeze(" ").strip
      tokens = text.split(" ") - LEGAL_SUFFIXES
      tokens.join(" ")
    end

    def tokens(value)
      normalize(value).split(" ")
    end

    def distinctive_tokens(value)
      tokens(value) - GENERIC_TOKENS
    end

    # Do these two names refer to the same company beyond reasonable doubt?
    # Only identical normalised forms qualify — anything looser is a suggestion
    # for a human, not something to act on unattended.
    def same?(a, b)
      normalized = normalize(a)
      normalized.present? && normalized == normalize(b)
    end

    # One name's tokens contained in the other's, sharing at least one token that
    # actually identifies something. "MB92 Barcelona" vs "MB92" qualifies;
    # "Prime Marine" vs "Euro Marine Group" does not.
    def related?(a, b)
      a_tokens, b_tokens = tokens(a), tokens(b)
      return false if a_tokens.empty? || b_tokens.empty?
      return false unless a_tokens.to_set.subset?(b_tokens.to_set) || b_tokens.to_set.subset?(a_tokens.to_set)

      (distinctive_tokens(a) & distinctive_tokens(b)).any?
    end

    # Names nothing identifiable — filler, not a company and not a vessel.
    def placeholder?(value)
      normalized = normalize(value)
      return true if normalized.blank?
      return true if PLACEHOLDER_EXACT.include?(normalized)

      distinctive_tokens(value).empty? && !vessel?(value)
    end

    # Names a specific vessel or build project. These are real entities and
    # belong in the Vessels module — often named after the builder ("MY 78m
    # Feadship"), which is exactly why they must not become an Account of that
    # name.
    def vessel?(value)
      text = value.to_s.strip
      return false if text.blank?
      return false if PLACEHOLDER_EXACT.include?(normalize(value))
      # A legal form settles it: hulls are not incorporated, companies are.
      # This is what separates "Motor Yacht Build ltd" from "Motor Yacht Serenity".
      return false if legal_form?(value)

      VESSEL_PATTERNS.any? { |pattern| pattern.match?(text) }
    end

    # Does the raw name carry a legal form (Ltd, B.V., GmbH) before it is stripped?
    def legal_form?(value)
      text = transliterate(value.to_s.downcase).delete(".")
      (text.gsub(/[^a-z0-9]+/, " ").split(" ") & LEGAL_SUFFIXES).any?
    end

    # The vessel's own name, with the type prefix removed, for a registry lookup.
    #
    #   vessel_name("M/Y Emir") # => "Emir"
    def vessel_name(value)
      value.to_s.strip.sub(VESSEL_PREFIX, "").strip
    end

    # Tokens worth searching Accounts on. Every distinctive token is tried, not
    # just the longest: in "MB92 Barcelona" the long word is a city and the short
    # one is the company, and picking by length finds the wrong thing.
    def search_tokens(value, limit: 4)
      candidates = distinctive_tokens(value)
      candidates = tokens(value) if candidates.empty?
      # A token opening with a digit is a size or hull number ("87m"), not a name.
      # Longest first: rarer tokens make the better search, and a common one like
      # "van" matches dozens of unrelated accounts.
      candidates.select { |token| token.length >= 3 && !token.start_with?(/\d/) }
        .uniq
        .sort_by { |token| -token.length }
        .first(limit)
    end

    private
      def transliterate(text)
        if defined?(ActiveSupport::Inflector)
          ActiveSupport::Inflector.transliterate(text)
        else
          text
        end
      end
  end
end
