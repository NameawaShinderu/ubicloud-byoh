# frozen_string_literal: true

require_relative "../lib/kvm_check"

# scripts/byoh/host/ubicloud-host judges PF3 before registration, and
# PrepHost judges it again with KvmCheck after. Both must reach the same
# verdict on the same host, so this feeds the fixture hosts the script
# ran on (scripts/byoh/test/preflight-fixtures.sh) to KvmCheck and
# compares with the PF3 status the script printed for each
# (spec/fixtures/byoh/preflight/<case>.txt).
RSpec.describe KvmCheck do
  repo = File.expand_path("../../..", __dir__)
  fixtures = File.join(repo, "scripts/byoh/test/fixtures/host")
  outputs = File.join(repo, "spec/fixtures/byoh/preflight")

  # The file a case sees: its own, else base's unless the case removes it.
  resolve = lambda do |kase, path|
    own = File.join(fixtures, kase, path)
    next own if File.exist?(own)

    removed = File.join(fixtures, kase, ".remove")
    next nil if File.exist?(removed) && File.readlines(removed, chomp: true).include?(path)

    base = File.join(fixtures, "base", path)
    base if File.exist?(base)
  end

  cases = Dir.children(outputs).map { |name| File.basename(name, ".txt") }.sort

  it "has fixture outputs for the KVM cases" do
    expect(cases).to include("base", "no-kvm", "kvm64-model", "arm-biglittle")
  end

  cases.each do |kase|
    it "agrees with the preflight PF3 verdict on #{kase}" do
      # The nonce is the one preflight-fixtures.sh passes; noisy-bashrc
      # also prints a PF3 line under another nonce.
      pf3 = File.read(File.join(outputs, "#{kase}.txt"))[/UBIPF:f1x7ure \{"kind":"check","id":"PF3","status":"(\w+)"/, 1]
      arch = ArchClass.new((File.read(resolve.call(kase, "cmd/uname-m")).strip == "aarch64") ? :arm64 : :x64)
      kvm_path = "/fixture/#{kase}/dev/kvm"
      expect(File).to receive(:chardev?).with(kvm_path).and_return(!resolve.call(kase, "dev/kvm.chardev").nil?)

      problem = described_class.problem(arch: arch, kvm_path: kvm_path, cpuinfo_path: resolve.call(kase, "proc/cpuinfo"))

      expect(problem.nil?).to eq(pf3 == "pass")
    end
  end
end
