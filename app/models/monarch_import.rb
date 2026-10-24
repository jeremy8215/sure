# Imports the transactions CSV from Monarch Money (Settings > Data > Download
# transactions). Columns: Date, Merchant, Category, Account, Original Statement,
# Notes, Amount, Tags, and Owner on household plans. Amounts are signed with
# income positive, credit card purchases included.
class MonarchImport < Import
  include MonarchImportable

  after_create :set_mappings

  DEFAULT_COLUMN_MAPPINGS = {
    signage_convention: "inflows_positive",
    date_col_label: "Date",
    date_format: "%Y-%m-%d",
    name_col_label: "Merchant",
    amount_col_label: "Amount",
    account_col_label: "Account",
    category_col_label: "Category",
    tags_col_label: "Tags",
    notes_col_label: "Notes"
  }.freeze

  # Not remappable: they only feed Transaction#extra, not a row column.
  ORIGINAL_STATEMENT_COLUMN = "Original Statement".freeze
  OWNER_COLUMN = "Owner".freeze

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    mapped_rows = csv_rows.map.with_index(1) do |row, index|
      account_name = csv_value(row, account_col_label, "account").to_s

      {
        source_row_number: index,
        account: account_name,
        entity_type: account_name,
        date: csv_value(row, date_col_label, "date").to_s,
        amount: sanitize_number(csv_value(row, amount_col_label, "amount")).to_s,
        currency: default_currency.to_s,
        name: row_name(row),
        category: csv_value(row, category_col_label, "category").to_s,
        tags: csv_value(row, tags_col_label, "tags").to_s,
        notes: csv_value(row, notes_col_label, "notes").to_s
      }
    end

    rows.insert_all!(mapped_rows)
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      new_transactions = []
      claimed_entry_ids = Set.new
      merchants = {}

      rows.ordered.each do |row|
        account = mapped_account_for!(row)
        next if covered_by_provider?(account, row.date_iso)

        category = mappings.categories.mappable_for(row.category)
        tags = row.tags_list.map { |tag| mappings.tags.mappable_for(tag) }.compact
        currency = account.currency.presence || family.currency

        # Re-importing the same file, or overlapping date-range exports, must
        # not double up transactions.
        duplicate = Account::ProviderImportAdapter.new(account).find_duplicate_transaction(
          date: row.date_iso,
          amount: row.signed_amount,
          currency: currency,
          name: row.name,
          exclude_entry_ids: claimed_entry_ids
        )

        if duplicate
          claimed_entry_ids << duplicate.id
          next
        end

        merchant = merchants[row.name] ||= FamilyMerchant.find_or_create_with_name(family, row.name).first

        new_transactions << Transaction.new(
          category: category,
          tags: tags,
          merchant: merchant,
          extra: monarch_extra(row),
          entry: Entry.new(
            account: account,
            date: row.date_iso,
            amount: row.signed_amount,
            name: row.name,
            currency: currency,
            notes: row.notes,
            import: self,
            import_locked: true
          )
        )
      end

      Transaction.import!(new_transactions, recursive: true) if new_transactions.any?
    end
  end

  def mapping_steps
    [ Import::CategoryMapping, Import::TagMapping, Import::AccountMapping, Import::AccountTypeMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount name category tags account notes]
  end

  def csv_template
    template = <<~CSV
      Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags
      2024-01-05,Employer,Paychecks,Checking (...1234),ACME CORP PAYROLL,,2500.00,
      2024-01-06,Whole Foods,Groceries,Sapphire Preferred (...9876),WHOLEFDS MKT 10234,Weekly shop,-84.12,"Family, Food"
    CSV

    CSV.parse(template, headers: true)
  end

  private
    def row_name(row)
      csv_value(row, name_col_label, "merchant").to_s.presence ||
        csv_value(row, ORIGINAL_STATEMENT_COLUMN).to_s.presence ||
        default_row_name
    end

    # Keeps the bank's raw descriptor (and household owner) that Monarch
    # exports alongside its cleaned-up merchant name.
    def monarch_extra(row)
      csv_row = csv_rows[row.source_row_number - 1]
      return {} if csv_row.nil?

      details = {
        "original_statement" => csv_value(csv_row, ORIGINAL_STATEMENT_COLUMN).presence,
        "owner" => csv_value(csv_row, OWNER_COLUMN).presence
      }.compact

      details.any? ? { "monarch" => details } : {}
    end
end
