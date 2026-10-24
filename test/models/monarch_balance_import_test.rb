require "test_helper"

class MonarchBalanceImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "keeps each account's first balance and the last balance of every month" do
    import = balance_import(file_fixture("imports/monarch_balances.csv").read)
    import.generate_rows_from_csv

    kept = import.rows.ordered.map { |row| [ row.account, row.date, row.amount ] }
    assert_equal [
      [ "Everyday Checking (...1234)", "2024-01-01", "1000.00" ],
      [ "Everyday Checking (...1234)", "2024-01-31", "1700.00" ],
      [ "Everyday Checking (...1234)", "2024-02-10", "1650.00" ],
      [ "Sapphire Preferred (...9876)", "2024-01-01", "-200.00" ],
      [ "Sapphire Preferred (...9876)", "2024-01-31", "-450.25" ]
    ], kept
  end

  test "publishes reconciliation valuations, storing debts as positive balances" do
    import = balance_import(file_fixture("imports/monarch_balances.csv").read)
    import.generate_rows_from_csv
    import.sync_mappings
    import.mappings.accounts.each { |mapping| mapping.update!(mappable: nil, create_when_empty: true) }

    assert_difference -> { Valuation.count } => 5 do
      import.reload.publish
    end
    assert_equal "complete", import.status, import.error

    card = @family.accounts.find_by!(name: "Sapphire Preferred (...9876)")
    assert_equal "CreditCard", card.accountable_type
    valuation = card.entries.valuations.find_by!(date: Date.new(2024, 1, 31))
    assert_equal BigDecimal("450.25"), valuation.amount
    assert valuation.entryable.reconciliation?
  end

  test "maps a single-account file without an Account column to an existing account" do
    import = balance_import(<<~CSV)
      Date,Balance
      2024-03-01,800.00
      2024-03-31,900.00
    CSV
    import.generate_rows_from_csv
    import.sync_mappings
    assert_empty import.mappings.account_types

    import.mappings.accounts.find_by!(key: "").update!(mappable: accounts(:depository))
    import.reload.publish

    assert_equal "complete", import.status, import.error
    assert_equal [ BigDecimal("800"), BigDecimal("900") ],
      accounts(:depository).entries.valuations.where(import: import).order(:date).pluck(:amount)
  end

  test "does not overwrite a balance already recorded on the same day" do
    depository = accounts(:depository)
    depository.entries.create!(
      date: Date.new(2024, 3, 31), amount: 123, currency: "USD", name: "Manual",
      entryable: Valuation.new(kind: "reconciliation")
    )

    import = balance_import(<<~CSV)
      Date,Balance
      2024-03-31,900.00
    CSV
    import.generate_rows_from_csv
    import.sync_mappings
    import.mappings.accounts.find_by!(key: "").update!(mappable: depository)
    import.reload.publish

    assert_equal BigDecimal("123"), depository.entries.valuations.find_by!(date: Date.new(2024, 3, 31)).amount
  end

  test "skips balances a linked account's provider already covers" do
    linked = accounts(:connected)
    linked.entries.create!(
      date: Date.new(2024, 3, 15), amount: 5, currency: "USD", name: "Synced",
      external_id: "provider-1", source: "plaid", entryable: Transaction.new
    )

    import = balance_import(<<~CSV)
      Date,Balance
      2024-02-29,700.00
      2024-03-31,900.00
    CSV
    import.generate_rows_from_csv
    import.sync_mappings
    import.mappings.accounts.find_by!(key: "").update!(mappable: linked)
    import.reload.publish

    assert_equal [ Date.new(2024, 2, 29) ], linked.entries.valuations.where(import: import).pluck(:date)
  end

  private
    def balance_import(csv)
      @family.imports.create!(type: "MonarchBalanceImport", raw_file_str: csv, col_sep: ",")
    end
end
