# Imports account balance history exported from Monarch Money, either for all
# accounts (Settings > Data > Download account balances) or for one account
# (account > Edit > Download balance history). Each kept row becomes a
# reconciliation valuation, which the balance calculators treat as a waypoint,
# so net worth history matches Monarch's.
#
# Monarch exports a balance per day. Only each account's first balance and the
# last balance of every month are kept: the transactions in between carry the
# balance from one waypoint to the next, without filling accounts with
# thousands of valuation entries.
class MonarchBalanceImport < Import
  include MonarchImportable

  after_create :set_mappings

  DEFAULT_COLUMN_MAPPINGS = {
    date_col_label: "Date",
    date_format: "%Y-%m-%d",
    amount_col_label: "Balance",
    account_col_label: "Account"
  }.freeze

  def self.default_column_mappings
    DEFAULT_COLUMN_MAPPINGS
  end

  def generate_rows_from_csv
    rows.destroy_all

    parsed = csv_rows.map.with_index(1) do |row, index|
      {
        source_row_number: index,
        account: csv_value(row, account_col_label, "account", "account_name").to_s,
        date: csv_value(row, date_col_label, "date").to_s,
        amount: sanitize_number(csv_value(row, amount_col_label, "balance", "amount")).to_s
      }
    end

    mapped_rows = waypoint_rows(parsed).map do |row|
      row.merge(entity_type: row[:account], currency: default_currency.to_s, name: default_row_name)
    end

    rows.insert_all!(mapped_rows) if mapped_rows.any?
    update_column(:rows_count, rows.count)
  end

  def import!
    transaction do
      mappings.each(&:create_mappable!)

      rows.ordered.each do |row|
        account = mapped_account_for!(row)
        date = row.date_iso.to_date
        next if covered_by_provider?(account, date)
        # Never overwrite a balance someone already recorded for that day.
        next if account.entries.valuations.exists?(date: date)

        # Monarch shows debts as negative balances; Sure stores them as
        # positive amounts owed.
        balance = row.amount.to_d
        balance = -balance if account.liability?

        account.entries.create!(
          date: date,
          amount: balance,
          currency: account.currency.presence || family.currency,
          name: Valuation.build_reconciliation_name(account.accountable_type),
          entryable: Valuation.new(kind: "reconciliation"),
          import: self
        )
      end
    end
  end

  def dry_run
    { valuations: rows_count }.tap do |counts|
      counts[:accounts] = Import::AccountMapping.for_import(self).creational.count if account.nil?
    end
  end

  def mapping_steps
    [ Import::AccountMapping, Import::AccountTypeMapping ]
  end

  def required_column_keys
    %i[date amount]
  end

  def column_keys
    %i[date amount account]
  end

  def csv_template
    template = <<~CSV
      Date,Balance,Account
      2024-01-31,5230.18,Checking (...1234)
      2024-01-31,-1204.55,Sapphire Preferred (...9876)
    CSV

    CSV.parse(template, headers: true)
  end

  private
    # Rows whose date doesn't parse are kept as-is so the clean step can flag
    # them instead of silently dropping data.
    def waypoint_rows(parsed)
      dated, undated = parsed.partition { |row| parse_date(row[:date]) }

      kept = dated.group_by { |row| row[:account] }.flat_map do |_account, account_rows|
        ordered = account_rows.sort_by { |row| [ parse_date(row[:date]), row[:source_row_number] ] }
        month_ends = ordered.group_by { |row| parse_date(row[:date]).beginning_of_month }.values.map(&:last)

        ([ ordered.first ] + month_ends).uniq
      end

      (kept + undated).sort_by { |row| row[:source_row_number] }
    end

    def parse_date(value)
      Date.strptime(value.to_s, date_format)
    rescue ArgumentError, Date::Error
      nil
    end
end
