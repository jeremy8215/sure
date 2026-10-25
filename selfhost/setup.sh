#!/usr/bin/env bash
# Creates selfhost/.env with freshly generated secrets. Safe to re-run: it
# never overwrites an existing .env.
set -euo pipefail
cd "$(dirname "$0")"

if [ -f .env ]; then
  echo ".env already exists, leaving it alone."
  exit 0
fi

secret_key=$(openssl rand -hex 64)
db_password=$(openssl rand -hex 24)

sed -e "s/^SECRET_KEY_BASE=.*/SECRET_KEY_BASE=${secret_key}/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${db_password}/" \
    .env.example > .env
chmod 600 .env
mkdir -p backups

echo "Created selfhost/.env. Back it up somewhere safe (password manager):"
echo "without SECRET_KEY_BASE, saved bank connections can't be decrypted."
echo "Next: docker compose up -d"
