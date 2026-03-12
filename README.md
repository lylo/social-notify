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

## Running from cron

The script is designed to be run unattended on a schedule. Here's how to set it up on a server.

### 1. Deploy the files

Copy the project to your server:

```sh
scp -r social-notify/ yourserver:~/social-notify/
```

On the server, make sure Ruby is installed (`ruby --version`) and create your `config.yml`.

### 2. Test it manually first

```sh
cd ~/social-notify
ruby social-notify.rb
```

Confirm it prints status lines and sends an email (or reports no notifications). Fix any credential issues before adding to cron.

### 3. Add a cron job

Open your crontab:

```sh
crontab -e
```

Add a line to run every 15 minutes (adjust to taste):

```cron
*/15 * * * * cd /home/you/social-notify && /usr/bin/ruby social-notify.rb >> /home/you/social-notify/cron.log 2>&1
```

A few things to note:

- **Use absolute paths.** Cron runs with a minimal environment — don't rely on `~` or `$HOME` in the command itself.
- **Find your Ruby path** with `which ruby`. If you use a version manager (rbenv, asdf, mise), use the full shim path or source the version manager in a wrapper script (see below).
- **Redirect output** to a log file so you can debug failures. The `2>&1` captures both stdout and stderr.
- **`cd` into the project directory** because the script resolves `config.yml` and `.last_checked.yml` relative to its own location via `__dir__`.

### 4. Version manager wrapper (if needed)

If your Ruby is managed by rbenv, asdf, or mise, cron won't load your shell profile. Create a small wrapper:

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

Then point cron at the wrapper:

```cron
*/15 * * * * /home/you/social-notify/run.sh >> /home/you/social-notify/cron.log 2>&1
```

### 5. Log rotation

The log file will grow over time. A simple approach — add a daily cron job to truncate it:

```cron
0 0 * * * truncate -s 0 /home/you/social-notify/cron.log
```

Or keep the last 1000 lines:

```cron
0 0 * * * tail -n 1000 /home/you/social-notify/cron.log > /home/you/social-notify/cron.log.tmp && mv /home/you/social-notify/cron.log.tmp /home/you/social-notify/cron.log
```

### Frequency recommendations

| Interval | Cron expression | Use case |
|---|---|---|
| Every 5 min | `*/5 * * * *` | Near-realtime awareness |
| Every 15 min | `*/15 * * * *` | Good default |
| Every hour | `0 * * * *` | Low-traffic accounts |
| Twice daily | `0 9,18 * * *` | Morning/evening digest |

## How it works

1. Authenticates with each Bluesky account via `com.atproto.server.createSession`
2. Fetches mentions and replies from `app.bsky.notification.listNotifications`
3. Fetches unread DM conversations from `chat.bsky.convo.listConvos`
4. Fetches Mastodon mention notifications, separating DMs (visibility `direct`) from public mentions
5. If anything new is found, composes a plain-text email and sends it via SMTP
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
