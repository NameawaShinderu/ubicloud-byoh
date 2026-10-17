# frozen_string_literal: true

require "digest"
require "tmpdir"

RSpec.describe ByohArtifactFetch do
  let(:dir) { Dir.mktmpdir }
  let(:dest) { File.join(dir, "file") }
  let(:content) { "the pinned file\n" }
  let(:sha) { Digest::SHA256.hexdigest(content) }
  let(:calls) { [] }

  after { FileUtils.rm_rf(dir) }

  # A curl that writes body to its -o path and exits with code.
  def runner(body: content, code: 0, out: "")
    lambda do |*argv|
      calls << argv
      tmp = argv[argv.index("-o") + 1]
      File.binwrite(tmp, body) if body
      [out, instance_double(Process::Status, success?: code.zero?, exitstatus: code)]
    end
  end

  def fetch(url = "https://example.com/f", pin = sha, **)
    described_class.new(runner: runner(**)).fetch(url, pin, dest)
  end

  it "keeps a file whose sha256 is the pin, fetched over https only and capped" do
    expect(fetch).to eq dest
    expect(File.read(dest)).to eq content
    argv = calls.first
    tmp = argv[argv.index("-o") + 1]
    expect(argv.values_at(0..7)).to eq ["curl", "--proto", "=https", "--proto-redir", "=https", "-fsSL", "--max-filesize", described_class::MAX_BYTES.to_s]
    expect(argv.last).to eq "https://example.com/f"
    expect(File.dirname(tmp)).to start_with File.join(dir, "byoh-fetch-")
    expect(Dir.children(dir)).to eq ["file"]
  end

  it "downloads into a fresh directory only the owner can read" do
    modes = []
    fetcher = described_class.new(runner: lambda { |*argv|
      modes << File.stat(File.dirname(argv[argv.index("-o") + 1])).mode
      runner.call(*argv)
    })
    fetcher.fetch("https://example.com/f", sha, dest)
    expect(modes.map { it & 0o777 }).to eq [0o700]
  end

  it "refuses a file whose sha256 is not the pin, leaving nothing behind" do
    expect { fetch(body: "something else") }.to raise_error(described_class::Refused, "https://example.com/f has sha256 #{Digest::SHA256.hexdigest("something else")}, not the pinned #{sha}")
    expect(Dir.children(dir)).to eq []
  end

  it "refuses what is not https, or a pin that is not a sha256, before fetching" do
    ["http://example.com/f", "https:///f", "ftp://example.com/f", "not a url", nil].each do |url|
      expect { fetch(url) }.to raise_error(described_class::Refused, "#{url} is not an https URL")
    end
    ["A" * 64, "a" * 63, nil].each do |pin|
      expect { fetch("https://example.com/f", pin) }.to raise_error(described_class::Refused, "the sha256 pin of https://example.com/f must be 64 lowercase hex digits")
    end
    expect(calls).to eq []
  end

  it "says what a refused redirect or an oversized download is" do
    expect { fetch(body: nil, code: 1, out: "curl: (1) Protocol \"http\" not supported\n") }
      .to raise_error(described_class::Refused, "downloading https://example.com/f failed (curl exit 1; an http:// URL or redirect is refused, only https is fetched): curl: (1) Protocol \"http\" not supported")
    expect { fetch(body: nil, code: 63, out: "curl: (63) Maximum file size exceeded") }
      .to raise_error(described_class::Refused, /\(curl exit 63; the file is larger than the cap\)/)
    expect { fetch(body: nil, code: 6, out: "curl: (6) Could not resolve host") }
      .to raise_error(described_class::Refused, "downloading https://example.com/f failed (curl exit 6): curl: (6) Could not resolve host")
    expect(Dir.children(dir)).to eq []
  end

  it "refuses a download larger than the cap even when curl let it through, or none at all" do
    expect { described_class.new(runner:, max_bytes: 4).fetch("https://example.com/f", sha, dest) }
      .to raise_error(described_class::Refused, "https://example.com/f is larger than the 4-byte cap")
    expect { fetch(body: nil) }.to raise_error(described_class::Refused, "downloading https://example.com/f gave no file")
    expect(Dir.children(dir)).to eq []
  end

  it "runs curl by default" do
    expect(described_class.new.instance_variable_get(:@runner)).to eq Open3.method(:capture2e)
  end
end
