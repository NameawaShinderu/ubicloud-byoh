# frozen_string_literal: true

require_relative "../lib/kvm_check"

RSpec.describe KvmCheck do
  let(:x64) { ArchClass.new(:x64) }
  let(:arm64) { ArchClass.new(:arm64) }

  it "fails when /dev/kvm is not a character device" do
    expect(File).to receive(:chardev?).with("/dev/kvm").and_return(false)
    expect(described_class.problem(arch: x64)).to start_with("/dev/kvm is not a character device")
  end

  it "fails when an x64 CPU has neither vmx nor svm" do
    expect(File).to receive(:chardev?).with("/dev/kvm").and_return(true)
    expect(File).to receive(:read).with("/proc/cpuinfo").and_return("processor\t: 0\nflags\t\t: fpu vme pdpe1gb lm\n")
    expect(described_class.problem(arch: x64)).to start_with("The CPU has neither the vmx nor the svm flag")
  end

  it "passes on an x64 CPU with vmx" do
    expect(File).to receive(:chardev?).with("/dev/kvm").and_return(true)
    expect(File).to receive(:read).with("/proc/cpuinfo").and_return("flags\t\t: fpu vmx lm\n")
    expect(described_class.problem(arch: x64)).to be_nil
  end

  it "passes on an x64 CPU with svm" do
    expect(File).to receive(:chardev?).with("/dev/kvm").and_return(true)
    expect(File).to receive(:read).with("/proc/cpuinfo").and_return("flags\t\t: fpu svm lm\n")
    expect(described_class.problem(arch: x64)).to be_nil
  end

  it "does not look for vmx or svm on arm64" do
    expect(File).to receive(:chardev?).with("/dev/kvm").and_return(true)
    expect(File).not_to receive(:read)
    expect(described_class.problem(arch: arm64)).to be_nil
  end
end
