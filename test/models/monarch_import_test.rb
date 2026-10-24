require "test_helper"

class MonarchImportTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "default column mappings are applied after create" do
    import = @family.imports.create!(type: "MonarchImport")

    MonarchImport.default_column_mappings.each do |attribute, value|
      assert_equal value, import.public_send(attribute)
    end
  end

  test "generates rows with Sure's sign convention and Monarch's columns" do
    import = monarch_import(file_fixture("imports/monarch.csv").read)
    import.generate_rows_from_csv

    rows = import.rows.ordered
    assert_equal BigDecimal("-2500"), rows.first.signed_amount   # income
    assert_equal BigDecimal("84.12"), rows.second.signed_amount  # card purchase
    assert_equal "Whole Foods", rows.second.name
    assert_equal [ "Family", "Food" ], rows.second.tags_list
    assert_equal "Weekly shop", rows.second.notes
    assert_equal "Sapphire Preferred (...9876)", rows.second.account
    assert rows.all?(&:valid?)
  end

  test "falls back to the original statement when the merchant is blank" do
    import = monarch_import(file_fixture("imports/monarch.csv").read)
    import.generate_rows_from_csv

    assert_equal "AMZN MKTP US*2K4", import.rows.ordered.third.name
  end

  test "pre-fills account types from account names" do
    import = monarch_import(file_fixture("imports/monarch.csv").read)
    import.generate_rows_from_csv
    import.sync_mappings

    types = import.mappings.account_types.pluck(:key, :value).to_h
    assert_equal({ "Everyday Checking (...1234)" => "Depository", "Sapphire Preferred (...9876)" => "CreditCard" }, types)
  end

  test "pre-fills the type of an account that already exists in Sure from that account" do
    import = monarch_import(<<~CSV)
      Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags
      2024-01-05,Store,Shopping,Mortgage Loan,STORE,,-10.00,
    CSV
    import.generate_rows_from_csv
    import.sync_mappings

    assert_equal accounts(:loan), import.mappings.accounts.find_by(key: "Mortgage Loan").mappable
    assert_equal "Loan", import.mappings.account_types.find_by(key: "Mortgage Loan").value
  end

  test "offers linked accounts as mapping targets" do
    import = monarch_import(file_fixture("imports/monarch.csv").read)
    import.generate_rows_from_csv
    import.sync_mappings

    mapping = import.mappings.accounts.find_by(key: "Everyday Checking (...1234)")
    assert_includes mapping.selectable_values.map(&:last), accounts(:connected).id
  end

  test "publishes transactions into new accounts with the chosen types, merchants and details" do
    import = mapped_import(file_fixture("imports/monarch.csv").read)

    assert_difference -> { Entry.count } => 4, -> { Transaction.count } => 4, -> { @family.accounts.count } => 2 do
      import.publish
    end

    assert_equal "complete", import.status, import.error

    card = @family.accounts.find_by!(name: "Sapphire Preferred (...9876)")
    assert_equal "CreditCard", card.accountable_type
    assert_equal "Depository", @family.accounts.find_by!(name: "Everyday Checking (...1234)").accountable_type

    groceries = import.entries.find_by!(name: "Whole Foods")
    assert_equal BigDecimal("84.12"), groceries.amount
    assert_equal card, groceries.account
    assert_equal "Groceries", groceries.transaction.category.name
    assert_equal [ "Family", "Food" ], groceries.transaction.tags.map(&:name).sort
    assert_equal "Whole Foods", groceries.transaction.merchant.name
    assert_equal({ "original_statement" => "WHOLEFDS MKT 10234" }, groceries.transaction.extra["monarch"])
    assert groceries.import_locked?
  end

  test "importing the same file twice does not duplicate transactions" do
    csv = file_fixture("imports/monarch.csv").read
    mapped_import(csv).publish

    second = mapped_import(csv)
    assert_no_difference -> { Entry.count } do
      second.publish
    end
    assert_equal "complete", second.status, second.error
  end

  test "skips rows a linked account's provider already covers" do
    linked = accounts(:connected)
    linked.entries.create!(
      date: Date.new(2024, 1, 7), amount: 5, currency: "USD", name: "Synced",
      external_id: "provider-1", source: "plaid", entryable: Transaction.new
    )

    import = monarch_import(file_fixture("imports/monarch.csv").read)
    import.generate_rows_from_csv
    import.sync_mappings
    import.mappings.accounts.find_by!(key: "Everyday Checking (...1234)").update!(mappable: linked, create_when_empty: false)
    import.mappings.accounts.find_by!(key: "Sapphire Preferred (...9876)").update!(mappable: accounts(:credit_card), create_when_empty: false)
    mark_all_categories_and_tags_creatable(import)

    import.publish

    assert_equal "complete", import.status, import.error
    linked_names = import.entries.where(account: linked).pluck(:name)
    assert_equal [ "Employer" ], linked_names # Jan 5 kept; Jan 8 is on/after the provider's first day
  end

  test "guesses account types from common account names" do
    {
      "Chase Sapphire Reserve" => "CreditCard",
      "Amex Gold Card" => "CreditCard",
      "Home Mortgage" => "Loan",
      "Fidelity 401(k)" => "Investment",
      "Roth IRA" => "Investment",
      "Coinbase" => "Crypto",
      "Toyota Car" => "Vehicle",
      "House (Zillow)" => "Property",
      "Ally Savings" => "Depository"
    }.each do |name, type|
      assert_equal type, MonarchImport.guess_accountable_type(name), name
    end
  end

  private
    def monarch_import(csv)
      @family.imports.create!(type: "MonarchImport", raw_file_str: csv, col_sep: ",")
    end

    def mapped_import(csv)
      import = monarch_import(csv)
      import.generate_rows_from_csv
      import.sync_mappings
      import.mappings.accounts.where(mappable: nil).each { |mapping| mapping.update!(create_when_empty: true) }
      mark_all_categories_and_tags_creatable(import)
      import.reload
    end

    def mark_all_categories_and_tags_creatable(import)
      import.mappings.where(type: %w[Import::CategoryMapping Import::TagMapping]).where.not(key: "").each do |mapping|
        existing = mapping.mappable
        mapping.update!(create_when_empty: existing.nil?)
      end
    end
end
