# frozen_string_literal: true

require "uri"

# Turns one smtp:// URL into the SMTP_* settings that config.rb reads, as
# KEY='value' lines for /etc/ubicloud/env. The URL carries a password, so
# it is read from stdin by bin/byoh-smtp-url and never echoed in errors.
#
#   smtp://user:pass@host[:port][?tls=on|off]
#
# The user and password are percent-decoded. The port defaults to 587 and
# tls (STARTTLS) to on, matching config.rb.
module ByohSmtpUrl
  class Error < StandardError; end

  # Characters that a single-quoted line in the env file cannot carry.
  FORBIDDEN_VALUE = /['\\\n\r\0]/

  TLS_VALUES = {"on" => "true", "off" => "false"}.freeze

  def self.parse(url)
    uri = begin
      URI.parse(url.to_s.strip)
    rescue URI::InvalidURIError
      raise Error, "not a valid URL (percent-encode special characters in the user and password)"
    end

    raise Error, "smtps:// is not supported; use smtp:// (STARTTLS, tls=on)" if uri.scheme == "smtps"
    raise Error, "the URL must start with smtp://" unless uri.scheme == "smtp"
    host = uri.hostname
    raise Error, "the URL has no host" if host.nil? || host.empty?
    if !["", "/"].include?(uri.path) || uri.fragment
      raise Error, "the URL must not have a path or fragment"
    end

    port = uri.port || 587
    raise Error, "the port must be between 1 and 65535" unless (1..65535).cover?(port)

    pairs = [["SMTP_HOSTNAME", host], ["SMTP_PORT", port.to_s], ["SMTP_TLS", tls(uri.query)]]

    user = uri.user && URI.decode_uri_component(uri.user)
    password = uri.password && URI.decode_uri_component(uri.password)
    if user.to_s.empty? != password.to_s.empty?
      raise Error, "give both a user and a password, or neither"
    end
    unless user.to_s.empty?
      pairs << ["SMTP_USER", user]
      pairs << ["SMTP_PASSWORD", password]
    end

    pairs.each do |key, value|
      raise Error, "#{key} contains a quote, backslash, newline or NUL" if FORBIDDEN_VALUE.match?(value)
    end
    pairs
  end

  def self.tls(query)
    return "true" if query.nil? || query.empty?

    params = URI.decode_www_form(query)
    unless params.length == 1 && params[0][0] == "tls" && TLS_VALUES.key?(params[0][1])
      raise Error, "the only query parameter allowed is tls=on or tls=off"
    end
    TLS_VALUES.fetch(params[0][1])
  end

  def self.env_lines(url)
    parse(url).map { |key, value| "#{key}='#{value}'\n" }.join
  end

  # Entry point for bin/byoh-smtp-url: the URL on stdin, the lines on
  # stdout. Returns the exit status.
  def self.run(stdin, stdout, stderr)
    stdout.write(env_lines(stdin.read))
    0
  rescue Error => e
    stderr.puts "byoh-smtp-url: #{e.message}"
    2
  end
end
