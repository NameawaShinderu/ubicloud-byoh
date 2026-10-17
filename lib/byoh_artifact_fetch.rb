# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "tmpdir"
require "uri"

# Downloads a pinned file on the control plane: https only, redirects
# included, at most max_bytes, and kept only when its sha256 is the pin.
# The download goes to a fresh 0700 directory beside dest and is renamed
# to dest only once it matches, so a refused file is never left where it
# would be used.
class ByohArtifactFetch
  class Refused < StandardError; end

  # The largest file a pin may name: a PVM host kernel package is about
  # 100 MiB, a guest vmlinux about 60 MiB.
  MAX_BYTES = 512 * 1024 * 1024

  SHA256_FORMAT = /\A[0-9a-f]{64}\z/

  # What some curl exit codes mean here.
  CURL_ERRORS = {
    1 => "an http:// URL or redirect is refused, only https is fetched",
    28 => "the server stalled: no connection within 10s, or under 1 KiB/s for 60s",
    63 => "the file is larger than the cap",
  }.freeze

  # A server that accepts and then stalls would hang the caller forever.
  TIMEOUT_ARGS = ["--connect-timeout", "10", "--speed-limit", "1024", "--speed-time", "60"].freeze

  # The scheme must be lower case: the location CHECK compares it with
  # LIKE 'https://_%', which is case sensitive.
  def self.https_url?(url)
    url = url.to_s
    uri = URI.parse(url)
    url.start_with?("https://") && uri.is_a?(URI::HTTPS) && !uri.host.to_s.empty?
  rescue URI::InvalidURIError
    false
  end

  # runner takes the curl command line and returns its output and status,
  # like Open3.capture2e.
  def initialize(runner: Open3.method(:capture2e), max_bytes: MAX_BYTES)
    @runner = runner
    @max_bytes = max_bytes
  end

  # Downloads url to dest, a path in an existing directory. Returns dest;
  # raises Refused, leaving nothing behind, when the download fails, is
  # too large or does not match sha256.
  def fetch(url, sha256, dest)
    raise Refused, "#{url} is not an https URL" unless self.class.https_url?(url)
    raise Refused, "the sha256 pin of #{url} must be 64 lowercase hex digits" unless SHA256_FORMAT.match?(sha256.to_s)

    dir = Dir.mktmpdir("byoh-fetch-", File.dirname(dest))
    begin
      tmp = File.join(dir, "download")
      out, status = @runner.call("curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL",
        *TIMEOUT_ARGS, "--max-filesize", @max_bytes.to_s, "-o", tmp, url)
      unless status.success?
        why = CURL_ERRORS[status.exitstatus]
        raise Refused, "downloading #{url} failed (curl exit #{status.exitstatus}#{"; #{why}" if why}): #{out.strip}"
      end
      raise Refused, "downloading #{url} gave no file" unless File.file?(tmp)
      raise Refused, "#{url} is larger than the #{@max_bytes}-byte cap" if File.size(tmp) > @max_bytes

      got = Digest::SHA256.file(tmp).hexdigest
      raise Refused, "#{url} has sha256 #{got}, not the pinned #{sha256}" unless got == sha256

      File.rename(tmp, dest)
    ensure
      FileUtils.rm_rf(dir)
    end
    dest
  end
end
