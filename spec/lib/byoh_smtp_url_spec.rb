# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe ByohSmtpUrl do
  def parse(url)
    described_class.parse(url).to_h
  end

  it "parses a full URL and percent-decodes the credentials" do
    expect(parse("smtp://ap%40key:p%2Fw%3Ard@mail.example.com:2525?tls=off\n")).to eq(
      "SMTP_HOSTNAME" => "mail.example.com",
      "SMTP_PORT" => "2525",
      "SMTP_TLS" => "false",
      "SMTP_USER" => "ap@key",
      "SMTP_PASSWORD" => "p/w:rd",
    )
  end

  it "defaults the port to 587 and tls to on, without credentials" do
    expect(parse("smtp://relay.internal/")).to eq(
      "SMTP_HOSTNAME" => "relay.internal",
      "SMTP_PORT" => "587",
      "SMTP_TLS" => "true",
    )
  end

  it "accepts tls=on, an empty query and an IPv6 host" do
    expect(parse("smtp://[2001:db8::1]:25?tls=on")).to include("SMTP_HOSTNAME" => "2001:db8::1", "SMTP_PORT" => "25", "SMTP_TLS" => "true")
    expect(parse("smtp://relay?")["SMTP_TLS"]).to eq("true")
  end

  it "rejects invalid input without echoing it" do
    {
      "smtp://us er:secret@host" => "not a valid URL",
      "smtps://u:secret@host:465" => "smtps:// is not supported",
      "http://host" => "the URL must start with smtp://",
      "mail.example.com" => "the URL must start with smtp://",
      "smtp:///" => "the URL has no host",
      "smtp://u:secret@" => "the URL has no host",
      "smtp://host/path" => "the URL must not have a path or fragment",
      "smtp://host#frag" => "the URL must not have a path or fragment",
      "smtp://host:0" => "the port must be between 1 and 65535",
      "smtp://host:70000" => "the port must be between 1 and 65535",
      "smtp://host?tls=yes" => "the only query parameter allowed",
      "smtp://host?port=25" => "the only query parameter allowed",
      "smtp://host?tls=on&tls=off" => "the only query parameter allowed",
      "smtp://user@host" => "give both a user and a password",
      "smtp://:secret@host" => "give both a user and a password",
      "smtp://user:se%27cret@host" => "SMTP_PASSWORD contains a quote",
      "smtp://us%5Cer:secret@host" => "SMTP_USER contains a quote",
      "smtp://user:se%0Acret@host" => "SMTP_PASSWORD contains a quote",
      "smtp://user:se%00cret@host" => "SMTP_PASSWORD contains a quote",
    }.each do |url, message|
      expect { described_class.parse(url) }.to raise_error(ByohSmtpUrl::Error, /\A#{Regexp.escape(message)}/) do |e|
        expect(e.message).not_to include("secret")
      end
    end
  end

  it "formats env lines" do
    expect(described_class.env_lines("smtp://u:p@h")).to eq("SMTP_HOSTNAME='h'\nSMTP_PORT='587'\nSMTP_TLS='true'\nSMTP_USER='u'\nSMTP_PASSWORD='p'\n")
  end

  describe ".run" do
    it "prints the lines and returns 0" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run(StringIO.new("smtp://h:26\n"), out, err)).to eq 0
      expect(out.string).to eq("SMTP_HOSTNAME='h'\nSMTP_PORT='26'\nSMTP_TLS='true'\n")
      expect(err.string).to eq ""
    end

    it "prints the error and returns 2" do
      out = StringIO.new
      err = StringIO.new
      expect(described_class.run(StringIO.new("smtps://u:secret@h"), out, err)).to eq 2
      expect(out.string).to eq ""
      expect(err.string).to start_with("byoh-smtp-url: smtps:// is not supported")
    end
  end
end
