# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"

# The PVM go/no-go script, scripts/byoh/test/real/pvm-go-no-go.sh (L4-T1,
# docs/byoh/NO_KVM.md section 14), runs only on a throwaway host, so these
# checks guard what can drift without running it.
RSpec.describe ByohVirtTiers, "pvm" do
  let(:path) { File.expand_path("../../scripts/byoh/test/real/pvm-go-no-go.sh", __dir__) }
  let(:script) { File.read(path) }

  it "pins the cloud-hypervisor builds rhizome pins" do
    versions = script[/^CH_VERSIONS="([^"]*)"$/, 1].split
    expect(versions).to eq %w[46.0 53.0]
    versions.each do |v|
      pin = script[/^CH_SHA256_#{v.split(".").first}="(\h{64})"$/, 1]
      expect(pin).to eq Prog::DownloadCloudHypervisor::HASHES[["ch-bin", "x64", v]]
    end
  end

  it "keeps pvm unoffered until the test reports GO" do
    expect(described_class::SHIPPED).not_to include("pvm")
  end

  # These run the script, which needs bash. The alpine test image has
  # none unless the run adds it, so they skip there instead of failing.
  context "when run by bash" do
    let(:bash) { ENV.fetch("PATH", "").split(":").map { File.join(it, "bash") }.find { File.executable?(it) } }

    before { skip "bash is not installed" unless bash }

    it "refuses to do anything without BYOH_REAL_HOST=1" do
      out, status = Open3.capture2e({"BYOH_REAL_HOST" => nil}, bash, path, "install")
      expect(status.exitstatus).to eq 2
      expect(out).to include("refusing")
    end
  end
end
