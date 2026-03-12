#!/usr/bin/env ruby
# frozen_string_literal: true

require "net/http"
require "net/smtp"
require "json"
require "yaml"
require "uri"
require "time"
require "openssl"

class SocialNotify
  CONFIG_PATH = File.join(__dir__, "config.yml")
  STATE_PATH = File.join(__dir__, ".last_checked.yml")

  def initialize
    @config = YAML.load_file(CONFIG_PATH)
    @state = File.exist?(STATE_PATH) ? YAML.load_file(STATE_PATH) || {} : {}
    @results = []
  end

  def send_test_email
    test_results = [
      { label: "Test Account (Bluesky)", url: "https://bsky.app/notifications", items: [
        { type: "MENTION", from: "alice.bsky.social", text: "hey @you check this out! I just published a new post about federation protocols and I think you'd have some really interesting thoughts on the architectural tradeoffs we discussed last week", time: Time.now.iso8601 },
        { type: "REPLY", from: "bob.bsky.social", text: "great post, totally agree", time: Time.now.iso8601 },
        { type: "DM", from: "carol.bsky.social", text: "are you coming to the meetup on Thursday? We've moved it to the new venue downtown. Let me know if you need the address, a few of us are planning to grab dinner afterwards too", time: Time.now.iso8601 },
      ] },
      { label: "Test Account (Mastodon)", url: "https://mastodon.social/notifications", items: [
        { type: "MENTION", from: "dave@fosstodon.org", text: "@you loved your latest article", time: Time.now.iso8601 },
        { type: "DM", from: "eve@mastodon.social", text: "quick question about your project", time: Time.now.iso8601 },
      ] },
    ]
    puts "Sending test email..."
    send_email(test_results)
    puts "Test email sent to #{@config['smtp']['to']}"
  end

  def run
    check_bluesky_accounts
    check_mastodon_account

    total = @results.sum { |r| r[:items].size }

    if total > 0
      puts "#{total} new notification(s) found. Sending email..."
      send_email(@results)
      puts "Email sent."
    else
      puts "No new notifications."
    end

    save_state
  end

  private

  # --- HTTP helpers ---

  def create_http(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 15
    http
  end

  def get_json(uri, headers = {})
    uri = URI(uri) unless uri.is_a?(URI)
    http = create_http(uri)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    res = http.request(req)
    raise "HTTP #{res.code} from GET #{uri}: #{res.body}" unless res.code == "200"
    JSON.parse(res.body)
  end

  def post_json(uri, body, headers = {})
    uri = URI(uri) unless uri.is_a?(URI)
    http = create_http(uri)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = JSON.generate(body)
    res = http.request(req)
    raise "HTTP #{res.code} from POST #{uri}: #{res.body}" unless res.code == "200"
    JSON.parse(res.body)
  end

  # --- Bluesky methods ---

  def bluesky_authenticate(handle, app_password)
    data = post_json(
      "https://bsky.social/xrpc/com.atproto.server.createSession",
      { identifier: handle, password: app_password }
    )
    pds_url = data.dig("didDoc", "service")
      &.find { |s| s["id"] == "#atproto_pds" }
      &.dig("serviceEndpoint") || "https://bsky.social"
    { token: data["accessJwt"], pds_url: pds_url }
  end

  def bluesky_fetch_notifications(token, since)
    data = get_json(
      "https://bsky.social/xrpc/app.bsky.notification.listNotifications?limit=50",
      "Authorization" => "Bearer #{token}"
    )

    notifications = data["notifications"] || []
    notifications.select do |n|
      %w[mention reply].include?(n["reason"]) &&
        (since.nil? || Time.parse(n["indexedAt"]) > since)
    end.map do |n|
      type = n["reason"] == "mention" ? "MENTION" : "REPLY"
      text = n.dig("record", "text") || ""
      author = n.dig("author", "handle") || "unknown"
      {
        type: type,
        from: author,
        text: text.slice(0, 200),
        time: n["indexedAt"]
      }
    end
  end

  def bluesky_fetch_unread_convos(token, pds_url, since)
    data = get_json(
      "#{pds_url}/xrpc/chat.bsky.convo.listConvos",
      "Authorization" => "Bearer #{token}",
      "Atproto-Proxy" => "did:web:api.bsky.chat#bsky_chat"
    )

    convos = data["convos"] || []
    convos.select { |c| (c["unreadCount"] || 0) > 0 }.map do |c|
      last_msg = c["lastMessage"] || {}
      sender = last_msg.dig("sender", "handle") || c.dig("members", 0, "handle") || "unknown"
      text = last_msg["text"] || ""
      {
        type: "DM",
        from: sender,
        text: text.slice(0, 200),
        time: last_msg["sentAt"] || Time.now.iso8601
      }
    end
  end

  def check_bluesky_accounts
    accounts = @config["bluesky_accounts"] || []
    accounts.each do |acct|
      handle = acct["handle"]
      label = acct["label"] || handle
      since = @state[handle] ? Time.parse(@state[handle]) : nil

      begin
        session = bluesky_authenticate(handle, acct["app_password"])
        token = session[:token]
        pds_url = session[:pds_url]

        if since.nil?
          puts "#{label}: first run, establishing baseline"
          @state[handle] = Time.now.iso8601
          next
        end

        notifications = bluesky_fetch_notifications(token, since)
        convos = bluesky_fetch_unread_convos(token, pds_url, since)
        items = notifications + convos

        puts "#{label}: #{items.size} new notification(s)"

        if items.any?
          @results << { label: label, url: "https://bsky.app/notifications", items: items }
        end

        latest_raw = items.max_by { |i| Time.parse(i[:time]) }&.dig(:time)
        @state[handle] = latest_raw || Time.now.iso8601
      rescue => e
        puts "ERROR checking #{label}: #{e.message}"
      end
    end
  end

  # --- Mastodon methods ---

  def mastodon_fetch_mentions(instance, token, since)
    url = "https://#{instance}/api/v1/notifications?types[]=mention&limit=80"
    data = get_json(url, "Authorization" => "Bearer #{token}")

    data.select do |n|
      since.nil? || Time.parse(n["created_at"]) > since
    end.map do |n|
      status = n["status"] || {}
      visibility = status["visibility"]
      type = visibility == "direct" ? "DM" : "MENTION"
      # Strip HTML tags for plain-text preview
      text = (status["content"] || "").gsub(/<[^>]+>/, "").slice(0, 200)
      from = n.dig("account", "acct") || "unknown"
      {
        type: type,
        from: from,
        text: text,
        time: n["created_at"]
      }
    end
  end

  def check_mastodon_account
    acct = @config["mastodon_account"]
    return unless acct

    instance = acct["instance"]
    label = acct["label"] || instance
    key = "mastodon:#{instance}"
    since = @state[key] ? Time.parse(@state[key]) : nil

    begin
      if since.nil?
        puts "#{label}: first run, establishing baseline"
        @state[key] = Time.now.iso8601
        return
      end

      items = mastodon_fetch_mentions(instance, acct["access_token"], since)

      puts "#{label}: #{items.size} new notification(s)"

      if items.any?
        @results << { label: label, url: "https://#{instance}/notifications", items: items }
      end

      latest_raw = items.max_by { |i| Time.parse(i[:time]) }&.dig(:time)
      @state[key] = latest_raw || Time.now.iso8601
    rescue => e
      puts "ERROR checking #{label}: #{e.message}"
    end
  end

  # --- Email ---

  def h(text)
    text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
  end

  TYPE_HEADINGS = { "DM" => "Direct Messages", "MENTION" => "Mentions", "REPLY" => "Replies" }

  def compose_email(results)
    html = +<<~HTML
      <div style="font-family:-apple-system,system-ui,sans-serif;max-width:560px;color:#222;padding-bottom:24px">
    HTML

    results.each do |r|
      html << <<~HTML
        <h2 style="font-size:16px;margin:24px 0 8px;padding-bottom:4px;border-bottom:1px solid #ddd"><a href="#{h(r[:url])}" style="color:#222;text-decoration:none">#{h(r[:label])}</a></h2>
      HTML

      r[:items].group_by { |i| i[:type] }.each do |type, items|
        heading = TYPE_HEADINGS[type] || type
        html << %(<h3 style="font-size:14px;margin:18px 0 8px;color:#888">#{h(heading)}</h3>\n)

        items.each do |item|
          preview = item[:text].empty? ? "" : %( <span style="color:#555">: #{h(item[:text])}</span>)
          html << %(<p style="margin:2px 0;font-size:14px"><strong>#{h(item[:from])}</strong>#{preview}</p>\n)
        end
      end
    end

    html << "</div>"
    html
  end

  def send_email(results)
    smtp_config = @config["smtp"]
    total = results.sum { |r| r[:items].size }
    noun = total == 1 ? "notification" : "notifications"
    subject = "#{total} new #{noun} - #{Time.now.strftime('%Y-%m-%d %H:%M')}"
    body = compose_email(results)

    message = <<~MSG
      From: #{smtp_config["from"]}
      To: #{smtp_config["to"]}
      Subject: #{subject}
      Date: #{Time.now.rfc2822}
      MIME-Version: 1.0
      Content-Type: text/html; charset=UTF-8

      #{body}
    MSG

    smtp = Net::SMTP.new(smtp_config["server"], smtp_config["port"])
    smtp.enable_starttls_auto
    smtp.start("localhost", smtp_config["username"], smtp_config["password"], :login) do |s|
      s.send_message(message, smtp_config["from"], smtp_config["to"])
    end
  end

  # --- State ---

  def save_state
    File.write(STATE_PATH, YAML.dump(@state))
  end
end

if ARGV.include?("--test")
  SocialNotify.new.send_test_email
else
  SocialNotify.new.run
end
