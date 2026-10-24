# Moving from Monarch Money

Sure can import your full Monarch Money history: transactions with their
merchants, categories, tags and notes, plus each account's balance history so
your net worth chart starts where Monarch's did.

## Recommended order

1. **Connect your banks first** (for example SimpleFIN under
   **Settings → Bank sync**) and let the first sync finish. Bank connections
   only bring in recent history, usually about 90 days.
2. **Import Monarch transactions.** Each Monarch account can be assigned to the
   matching connected account. Rows dated on or after the first transaction
   the bank connection brought in are skipped, so nothing is duplicated.
3. **Import Monarch balance history** the same way.

Accounts you never connect (a house, a car, an old closed account) are created
by the import, with a type you choose.

## 1. Export from Monarch

On the Monarch website, go to **Settings → Data**:

- **Download transactions** gives one CSV for all accounts. Monarch recommends
  5,000 transactions or fewer per file, and Sure accepts up to 10,000 rows per
  import, so for a long history download one year at a time and import each
  file. Importing a file twice, or files with overlapping dates, doesn't
  create duplicates.
- **Download account balances** gives the daily balance history. You can also
  download one account's history from that account's page
  (**Edit → Download balance history**).

## 2. Import transactions

1. In Sure, open **Settings → Imports → New import → Import from Monarch Money
   (transactions)** and upload the transactions CSV.
2. The columns are pre-configured. Select **Apply configuration**, review the
   rows, then go through the mapping steps:
   - **Categories** and **tags**: map each to an existing one or let Sure create it.
   - **Accounts**: pick the matching Sure account (connected accounts are
     listed too) or **Add as new account**.
   - **Account types**: pre-filled from each account's name (for example
     "Sapphire" becomes a credit card, "401k" an investment account). Check
     them before publishing. The type is ignored for accounts you mapped to an
     existing one.
3. Publish the import.

Monarch's cleaned-up merchant name becomes the transaction name and merchant.
The bank's original description is stored with each transaction's data, though the app doesn't display it yet.

## 3. Import balance history

1. Open **New import → Import from Monarch Money (balance history)** and upload
   the balances CSV. For a single-account file without an Account column,
   leave the Account column empty and pick the account in the mapping step.
2. Map the accounts the same way as for transactions, then publish.

To keep accounts readable, Sure keeps each account's first balance and the last
balance of every month rather than every day. Transactions fill in the days in
between. Balances on days that already have a recorded balance in Sure, or that
a bank connection already covers, are skipped.

## What doesn't come over

Monarch's exports don't include budgets, rules, goals, recurring-bill settings,
investment holdings or split details, so set those up again in Sure. Transfers
between your accounts are matched automatically after the import.

Every import can be reverted from **Settings → Imports** if something looks
wrong.
