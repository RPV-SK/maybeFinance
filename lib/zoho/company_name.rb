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

    # Values that name a vessel, a placeholder or a job description rather than a
    # company. Creating an Account from one of these is always wrong.
    PLACEHOLDER_EXACT = [
      "private", "private yacht", "private company", "private client", "private owner",
      "yacht", "yachts", "motoryacht", "motor yacht", "sailing yacht", "superyacht",
      "super yacht", "super yachts", "none", "n a", "na", "nil", "unknown", "self",
      "self employed", "freelance", "retired", "student", "home", "confidential"
    ].freeze

    PLACEHOLDER_PATTERNS = [
      %r{\Am/?[yv]\b}i,                       # "M/Y Amadeus", "MY Amadeus"
      %r{\As/?[yv]\b}i,                       # "S/Y ..."
      /\A\d+\s*(m|ft|feet|metre|meter)s?\b/i, # "87m Feadship", "96m Feadship"
      /\b\d+\s*(m|ft|feet|metre|meter)s?\+?\b/i, # "M/Y Feadship 75m+", "Sunseeker predator 82 feet"
      /\A(private|new build|newbuild)\b.*\b(yacht|vessel|boat|superyacht)\b/i
    ].freeze

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

    # Names a vessel, a placeholder, or nothing at all.
    def placeholder?(value)
      normalized = normalize(value)
      return true if normalized.blank?
      return true if PLACEHOLDER_EXACT.include?(normalized)
      return true if distinctive_tokens(value).empty?

      PLACEHOLDER_PATTERNS.any? { |pattern| pattern.match?(value.to_s.strip) }
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
