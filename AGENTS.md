# AGENTS.md

## Project overview

social-notify is a single-file Ruby script (~250 lines) that checks Bluesky and Mastodon for new DMs, mentions, and replies, then emails a summary via SMTP. It uses only Ruby stdlib — no gems.

## Architecture

Everything lives in `social-notify.rb` in a single `SocialNotify` class. There is no build step, no dependency installation, and no test suite.

Key design constraints:
- **Zero external dependencies.** Only Ruby stdlib (`net/http`, `net/smtp`, `json`, `yaml`, `uri`, `time`, `openssl`).
- **Single file.** All logic stays in `social-notify.rb`. Don't extract classes into separate files.
- **Error isolation.** Each account is checked in its own `begin/rescue` block so one failure doesn't prevent checking the others.
- **State via flat file.** `.last_checked.yml` stores ISO 8601 timestamps keyed by account identifier. No database.

## File layout

```
social-notify.rb        # All application code
config.yml.example      # Template (committed)
config.yml              # Real credentials (gitignored)
.last_checked.yml       # Runtime state (gitignored)
```

## Config

`config.yml` holds credentials for Bluesky accounts (handle + app password), one Mastodon account (instance + access token), and SMTP settings. See `config.yml.example` for the schema.

## Conventions

- Keep the script self-contained. If adding a new platform, add methods in the same file following the existing pattern (`platform_fetch_*` + `check_platform`).
- HTTP helpers (`get_json`, `post_json`) handle SSL, timeouts, and error raising. Use them for all API calls.
- All timestamps are ISO 8601. Use `Time.parse` / `Time#iso8601` consistently.
- Terminal output is minimal: one line per account with the count, plus a send/no-send summary.
- The email is plain text, no HTML.

## Common tasks

- **Add a new platform:** Add fetch methods, a `check_*` method, call it from `run`, and add a config section to `config.yml.example`.
- **Change notification types:** Edit the `select` filter in the relevant fetch method (e.g., add `"like"` to the Bluesky reasons array).
- **Change email format:** Edit `compose_email`. Keep it plain text.
