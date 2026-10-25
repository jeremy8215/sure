# Self-hosting this fork on Proxmox

This folder holds everything needed to run this fork of Sure on a Proxmox
server, with bank data pulled in through SimpleFIN Bridge. It lives in its own
folder so pulling in upstream updates never conflicts with it.

## 1. Create a VM on Proxmox

A small Debian VM is the simplest and most reliable home for Docker on Proxmox.
Docker inside an LXC works too, but it needs `nesting=1` and `keyctl=1`, and
it breaks more often across Proxmox upgrades.

Suggested size: 2 vCPU, 4 GB RAM, 32 GB disk, Debian 13 (or 12).

Inside the VM, install Docker and git:

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER   # log out and back in afterwards
sudo apt-get install -y git
```

## 2. Get the code and create your secrets

```bash
git clone https://github.com/jeremy8215/sure.git ~/sure
cd ~/sure/selfhost
./setup.sh
```

`setup.sh` creates `selfhost/.env` with a random `SECRET_KEY_BASE` and
database password. **Save a copy of `.env` in your password manager.** The
secret key encrypts your SimpleFIN credentials, and without it a restored
backup can't reconnect to your banks.

## 3. Start it

```bash
docker compose up -d --build   # first build takes several minutes
docker compose ps              # web, worker, db, redis and backup should be "running"
```

Open `http://<vm-ip>:3000` and create your account. Then lock sign-ups:
set `ONBOARDING_STATE=closed` in `.env` and run `docker compose up -d` again.

## 4. Connect your banks with SimpleFIN

1. Sign up at [bridge.simplefin.org](https://bridge.simplefin.org) (about $15/year).
2. In SimpleFIN Bridge, connect each of your banks.
3. Still in SimpleFIN Bridge, create a new **setup token** and copy it. It
   works only once, so use it right away.
4. In Sure, go to **Settings → Bank sync → SimpleFIN**, paste the token and
   click connect.
5. Go to **Accounts** and link each SimpleFIN account to a Sure account
   (new or existing), choosing its type (checking, credit card, loan, etc.).

The worker syncs automatically in the background, and you can press **Sync**
on an account at any time. SimpleFIN itself refreshes from banks about once a
day, so new transactions show up with a delay of up to a day.

Banks SimpleFIN can't reach can still be added by CSV import
(**Settings → Imports**).

## 5. Reaching it away from home

Don't forward port 3000 on your router. For a finance app, the safest option
is [Tailscale](https://tailscale.com): install it on the VM and your phone or
laptop, then open `http://<vm-tailscale-name>:3000`. For HTTPS, run
`tailscale serve --bg 3000` on the VM and then set these in `.env`:

```
APP_DOMAIN=<vm-name>.<tailnet>.ts.net
RAILS_ASSUME_SSL=true
RAILS_FORCE_SSL=true
```

If you already run a reverse proxy (Caddy, Nginx Proxy Manager, Traefik),
point it at `http://<vm-ip>:3000` and set the same three values.

## 6. Backups

### On the server

The `backup` service runs every 24 hours and writes two files to
`selfhost/backups/`:

- `sure-db-<date>.sql.gz`: the whole database.
- `sure-files-<date>.tar.gz`: uploaded files (statements, attachments).

It keeps 14 days of them (`BACKUP_KEEP_DAYS`). To make a backup right now, run
`docker compose restart backup`.

Also schedule a Proxmox backup of the whole VM (Datacenter → Backup),
ideally to a different disk or a Proxmox Backup Server.

### Copying backups to OneDrive

The optional `backup-offsite` service uses [rclone](https://rclone.org) to copy
the backups folder to OneDrive every 6 hours, and deletes copies older than 90
days there (`OFFSITE_KEEP_DAYS`).

**One-time sign-in.** OneDrive needs a browser sign-in, and the VM has no
browser, so the sign-in happens on your laptop:

1. On your laptop, install rclone ([rclone.org/install](https://rclone.org/install/),
   or `brew install rclone` / `winget install Rclone.Rclone`) and run:

   ```bash
   rclone authorize "onedrive"
   ```

   A browser opens. Sign in to Microsoft and approve access. The terminal then
   prints a token: a block of text starting with `{"access_token":`. Copy all of it.

2. On the VM, in `~/sure/selfhost`, run rclone's setup:

   ```bash
   mkdir -p rclone
   docker run --rm -it -v "$PWD/rclone:/config/rclone" rclone/rclone:1.71 config
   ```

   Answer the prompts like this:
   - `n` for a new remote, and name it `onedrive`
   - Storage type: `onedrive`
   - `client_id` and `client_secret`: leave blank
   - Region: `global`
   - Edit advanced config: `n`
   - Use web browser to automatically authenticate: `n`
   - `config_token`: paste the token from step 1
   - Config type: `onedrive` (OneDrive Personal or Business), then pick your
     drive and confirm with `y`
   - `y` to keep the remote, then `q` to quit

   Accept the default for any other question rclone asks.

3. In `.env`, uncomment `COMPOSE_PROFILES=offsite` (and change
   `OFFSITE_DESTINATION` if you want a folder other than `Backups/Sure`), then:

   ```bash
   docker compose up -d
   docker compose logs -f backup-offsite   # should print "synced to onedrive:Backups/Sure"
   ```

The token is saved in `selfhost/rclone/rclone.conf`, which git ignores. If
OneDrive sign-in ever expires, the log shows "copy failed". Repeat steps 1 and
2 and choose to edit the existing `onedrive` remote.

**Keep `.env` out of OneDrive.** The backups contain your financial data, and
`.env` holds the key that decrypts your saved bank connections. Keeping that key
in your password manager instead of next to the backups means someone who gets
into your OneDrive still can't reconnect to your banks.

### Restoring

On a fresh install (after `./setup.sh`, with your saved `.env` copied back in):

```bash
docker compose up -d db
gunzip -c backups/sure-db-YYYYMMDD-HHMMSS.sql.gz | \
  docker compose exec -T db psql -U sure_user -d sure_production
docker compose run --rm --no-deps -u 0 --entrypoint tar \
  -v "$PWD/backups:/backups" web -xzf /backups/sure-files-YYYYMMDD-HHMMSS.tar.gz -C /rails/storage
docker compose up -d
```

To restore from OneDrive, first download the two files into `selfhost/backups/`,
either from the OneDrive website or with
`docker run --rm -v "$PWD/rclone:/config/rclone" -v "$PWD/backups:/backups" rclone/rclone:1.71 copy onedrive:Backups/Sure /backups`.

## 7. Updating

The app is built from this repository's code, so your own features ship with
it. To update:

```bash
cd ~/sure
git pull
cd selfhost
docker compose up -d --build
```

The first build takes several minutes; later ones reuse cached layers.

## Keeping the fork close to upstream

```bash
git remote add upstream https://github.com/we-promise/sure.git   # once
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

GitHub's **Sync fork** button on the repo page does the same thing. Keep custom
features small and in their own files where possible, so these merges stay
clean.
