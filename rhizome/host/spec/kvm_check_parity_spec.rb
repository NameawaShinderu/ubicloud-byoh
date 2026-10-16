# frozen_string_literal: true

require_relative "../lib/kvm_check"

# scripts/byoh/host/ubicloud-host judges PF3 before registration, and
# PrepHost judges it again with KvmCheck after. Both must reach the same
# verdict on the same host, so this feeds the fixture hosts the script
# ran on (scripts/byoh/test/preflight-fixtures.sh) to KvmCheck and
# compares with the PF3 status the script printed for each
# (spec/fixtures/byoh/preflight/<case>.txt).
#
# The one intended divergence: the script also refuses kvm64-class CPU
# models, which KvmCheck does not look at. On those hosts PF3 fails and
# KvmCheck's verdict is the one kvm_check_on_kvm64 records.
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

  # Whether KvmCheck passes each kvm64-class fixture host.
  kvm_check_on_kvm64 = {"kvm64-model" => false, "kvm64-vmx" => true}

  it "has fixture outputs for the KVM cases" do
    expect(cases).to include("base", "no-kvm", "kvm64-model", "kvm64-vmx", "arm-biglittle")
  end

  cases.each do |kase|
    it "agrees with the preflight PF3 verdict on #{kase}" do
      # The nonce is the one preflight-fixtures.sh passes; noisy-bashrc
      # also prints a PF3 line under another nonce.
      pf3, detail = File.read(File.join(outputs, "#{kase}.txt")).match(/UBIPF:f1x7ure \{"kind":"check","id":"PF3","status":"(\w+)","detail":"([^"]*)"/).captures
      arch = ArchClass.new((File.read(resolve.call(kase, "cmd/uname-m")).strip == "aarch64") ? :arm64 : :x64)
      kvm_path = "/fixture/#{kase}/dev/kvm"
      expect(File).to receive(:chardev?).with(kvm_path).and_return(!resolve.call(kase, "dev/kvm.chardev").nil?)

      problem = described_class.problem(arch: arch, kvm_path: kvm_path, cpuinfo_path: resolve.call(kase, "proc/cpuinfo"))

      if detail.start_with?("kvm64-class CPU model")
        expect(pf3).to eq "fail"
        expect(problem.nil?).to eq kvm_check_on_kvm64.fetch(kase)
      else
        expect(problem.nil?).to eq(pf3 == "pass")
      end
    end
  end
end
