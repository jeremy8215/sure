# Shared behavior for imports of Monarch Money CSV exports.
#
# Monarch exports only carry account names, so each account in the file gets an
# account-type mapping (pre-filled with a guess from the name) that decides the
# accountable type of any account created by the import. Rows reuse the
# entity_type column to carry the account name for that mapping step.
#
# Monarch history is also allowed into provider-linked accounts (e.g. SimpleFIN),
# but rows dated on or after the first provider-synced transaction in that
# account are skipped, since the provider already covers that period.
module MonarchImportable
  extend ActiveSupport::Concern

  # Checked in order; the first match wins. Word boundaries keep e.g. "car"
  # from matching "card".
  ACCOUNT_TYPE_PATTERNS = [
    [ "CreditCard", /\b(credit|card|visa|mastercard|amex|american express|discover|sapphire|freedom|quicksilver)\b/i ],
    [ "Loan", /\b(mortgage|loan|heloc|lending)\b/i ],
    [ "Crypto", /\b(crypto|coinbase|bitcoin|btc|ethereum|eth)\b/i ],
    [ "Investment", /\b(401\s?\(?k\)?|403\s?\(?b\)?|457|ira|roth|brokerage|hsa|529|invest\w*|stocks?|retirement|pension|fidelity|vanguard|schwab|robinhood|e\*?trade|wealthfront|betterment)\b/i ],
    [ "Vehicle", /\b(car|vehicle|truck|auto|motorcycle)\b/i ],
    [ "Property", /\b(house|home value|property|real estate|condo|zillow|zestimate)\b/i ]
  ].freeze

  class_methods do
    def guess_accountable_type(account_name)
      ACCOUNT_TYPE_PATTERNS.find { |_type, pattern| account_name.to_s.match?(pattern) }&.first || "Depository"
    end
  end

  # Unlike generic CSV imports, Monarch history may be mapped into linked
  # accounts so it can sit in front of the provider's own history.
  def account_mapping_candidates
    family.accounts.visible.alphabetically
  end

  def build_accountable_for_new_account(account_name)
    type = mappings.account_types.find_by(key: account_name)&.value
    type = self.class.guess_accountable_type(account_name) unless Accountable::TYPES.include?(type)
    type.constantize.new
  end

  def sync_mappings
    rows.where("entity_type IS DISTINCT FROM account").update_all("entity_type = account")

    super

    transaction do
      mappings.account_types.where(key: [ nil, "" ]).destroy_all

      mappings.account_types.where(value: [ nil, "" ]).find_each do |type_mapping|
        existing_account = mappings.accounts.find_by(key: type_mapping.key)&.mappable
        type_mapping.update_column(
          :value,
          existing_account&.accountable_type || self.class.guess_accountable_type(type_mapping.key)
        )
      end
    end
  end

  private
    def covered_by_provider?(account, date)
      start = provider_coverage_start(account)
      start.present? && date.to_date >= start
    end

    def provider_coverage_start(account)
      @provider_coverage_starts ||= {}
      return @provider_coverage_starts[account.id] if @provider_coverage_starts.key?(account.id)

      @provider_coverage_starts[account.id] =
        if account.linked?
          account.entries.where(entryable_type: "Transaction").where.not(external_id: nil).minimum(:date)
        end
    end

    def mapped_account_for!(row)
      account = mappings.accounts.mappable_for(row.account)
      return account if account

      message = "Row #{row.source_row_number}: Account '#{row.account.presence || '(blank)'}' is not mapped to an account. " \
                "Please map it in the import configuration."
      errors.add(:base, message)
      raise Import::MappingError, message
    end

    def set_mappings
      assign_attributes(self.class.default_column_mappings)
      save!
    end
end
