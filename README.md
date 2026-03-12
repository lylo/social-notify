# social-notify

A single-file Ruby script that checks Bluesky (multiple accounts) and Mastodon (one account) for new DMs, mentions, and replies, then emails you a summary.

No gems, no framework — just Ruby stdlib.

## Setup

Requires Ruby 2.7+.

```sh
cp config.yml.example config.yml
```

Edit `config.yml` with your credentials:

- **Bluesky** — use [app passwords](https://bsky.app/settings/app-passwords), not your main password. Add as many accounts as you like.
- **Mastodon** — create an access token at `https://<your-instance>/settings/applications`. Grant read access to notifications.
- **SMTP** — for Gmail, create an [App Password](https://myaccount.google.com/apppasswords) (requires 2FA enabled on your Google account).

## Usage

```sh
ruby social-notify.rb
```

Output looks like:

```
Alice (Bluesky): 3 new notification(s)
Bob (Bluesky): 0 new notification(s)
Alice (Mastodon): 1 new notification(s)
4 new notification(s) found. Sending email...
Email sent.
```

The script writes `.last_checked.yml` to track what it has already seen. Running it again immediately will report "No new notifications" unless new activity has arrived.

## Running on a schedule

The script is designed to be run unattended. Here's how to set it up on a server.

### Deploy and test

Copy the project to your server:

```sh
scp -r social-notify/ yourserver:~/social-notify/
```

On the server, make sure Ruby is installed (`ruby --version`) and create your `config.yml`. Then test manually:

```sh
cd ~/social-notify
ruby social-notify.rb
```

Confirm it prints status lines and sends an email (or reports no notifications). Fix any credential issues before scheduling.

### Option A: `/etc/cron.d/` (simplest)

If your user crontab is managed by another tool (e.g. the `whenever` gem), use a system cron file instead — these are independent of user crontabs.

```sh
sudo tee /etc/cron.d/social-notify << 'EOF'
*/15 * * * * deploy cd /home/deploy/social-notify && /usr/bin/ruby social-notify.rb >> /home/deploy/social-notify/cron.log 2>&1
EOF
```

Note the extra field after the schedule — that's the username to run as. Adjust `deploy` and paths to match your setup. Find your Ruby path with `which ruby`.

### Option B: systemd timer

If you'd prefer proper logging via `journalctl` and no log file to manage:

```ini
# /etc/systemd/system/social-notify.service
[Unit]
Description=Check social notifications

[Service]
Type=oneshot
User=deploy
WorkingDirectory=/home/deploy/social-notify
ExecStart=/usr/bin/ruby social-notify.rb
```

```ini
# /etc/systemd/system/social-notify.timer
[Unit]
Description=Run social-notify every 15 minutes

[Timer]
OnCalendar=*:0/15
Persistent=true

[Install]
WantedBy=timers.target
```

Then:

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now social-notify.timer
```

Check logs with `journalctl -u social-notify`. Check timer status with `systemctl list-timers social-notify*`.

### Option C: user crontab

If nothing else manages your crontab, `crontab -e` and add:

```cron
*/15 * * * * cd /home/you/social-notify && /usr/bin/ruby social-notify.rb >> /home/you/social-notify/cron.log 2>&1
```

### Version manager wrapper

If your Ruby is managed by rbenv, asdf, or mise, cron and systemd won't load your shell profile. Create a wrapper:

```sh
#!/bin/sh
# ~/social-notify/run.sh
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"  # adjust for your manager
cd "$(dirname "$0")"
ruby social-notify.rb
```

```sh
chmod +x ~/social-notify/run.sh
```

Then point your cron or systemd `ExecStart` at `/home/deploy/social-notify/run.sh` instead.

### Log rotation (cron only)

If using cron with a log file, add a daily truncation:

```cron
0 0 * * * truncate -s 0 /home/you/social-notify/cron.log
```

### Frequency recommendations

| Interval | Cron expression | Use case |
|---|---|---|
| Every 5 min | `*/5 * * * *` | Near-realtime awareness |
| Every 15 min | `*/15 * * * *` | Good default |
| Every hour | `0 * * * *` | Low-traffic accounts |
| Twice daily | `0 9,16 * * *` | Morning/afternoon digest |

## How it works

1. Authenticates with each Bluesky account via `com.atproto.server.createSession`
2. Fetches mentions and replies from `app.bsky.notification.listNotifications`
3. Fetches unread DM conversations from `chat.bsky.convo.listConvos`
4. Fetches Mastodon mention notifications, separating DMs (visibility `direct`) from public mentions
5. If anything new is found, composes an HTML email and sends it via SMTP
6. Saves timestamps to `.last_checked.yml` so the next run only reports new activity

Each account is checked independently — if one fails (bad credentials, API down), the others still run.

## Email format

```
=== Alice (Bluesky) ===
  [MENTION] from carol.bsky.social
    hey @alice check this out
  [DM] from dave.bsky.social
    are you coming to the meetup?

=== Alice (Mastodon) ===
  [MENTION] from bob@fosstodon.org
    @alice great post!
```

## Files

| File | Tracked | Purpose |
|---|---|---|
| `social-notify.rb` | yes | Main script |
| `config.yml.example` | yes | Config template |
| `config.yml` | no | Your credentials |
| `.last_checked.yml` | no | Persistent state |
