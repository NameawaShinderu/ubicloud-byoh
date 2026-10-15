# frozen_string_literal: true

require "json"
require_relative "../lib/vm_path"
require_relative "../lib/cloud_hypervisor"
require_relative "../lib/emulated_stop"

# The bin/stop-vm command line contract: argument checks, the emulated
# (TCG) branch, and the unchanged cloud-hypervisor path.
# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "bin/stop-vm" do
  # rubocop:enable RSpec/DescribeClass
  let(:bin) { File.expand_path("../bin/stop-vm", __dir__) }
  let(:vm_name) { "vmq00001" }

  def stop_vm(*argv)
    stub_const("ARGV", argv)
    load bin
    nil
  rescue SystemExit => e
    e.status
  end

  def prep(params)
    allow(File).to receive(:read).and_call_original
    allow(File).to receive(:read).with("/vm/#{vm_name}/prep.json").and_return(JSON.generate(params))
  end

  it "refuses a wrong number of arguments" do
    expect { expect(stop_vm).to eq(1) }.to output("usage: stop-vm vm-name\n").to_stderr
    expect { expect(stop_vm("a", "b")).to eq(1) }.to output("usage: stop-vm vm-name\n").to_stderr
  end

  it "refuses a malformed VM name" do
    expect { expect(stop_vm("vmq0001")).to eq(1) }.to output(/unexpected vm name format/).to_stderr
    expect { expect(stop_vm("xmq00001")).to eq(1) }.to output(/unexpected vm name format/).to_stderr
  end

  it "takes the emulated branch for a QEMU VM under TCG and exits with its status" do
    prep({"hypervisor" => "qemu", "accel" => "tcg"})
    expect(EmulatedStop).to receive(:run).with(vm_name).and_return(0)
    expect(Process).not_to receive(:exec)
    expect(stop_vm(vm_name)).to eq(0)
  end

  it "exits 0 for a TCG VM whose soft stop fails, so hard_stop stays reachable" do
    prep({"hypervisor" => "qemu", "accel" => "tcg"})
    expect(EmulatedStop).to receive(:powerdown).with(vm_name).and_raise(RuntimeError, "QMP child did not finish within 15s")
    expect {
      expect(stop_vm(vm_name)).to eq(0)
    }.to output("stop-vm: QMP child did not finish within 15s; leaving the stop to the hard-stop fallback\n").to_stderr
  end

  it "keeps the old message and exit 1 for a QEMU VM under KVM" do
    prep({"hypervisor" => "qemu", "accel" => "kvm"})
    expect(EmulatedStop).not_to receive(:run)
    expect {
      expect(stop_vm(vm_name)).to eq(1)
    }.to output("stop-vm is only supported for VMs using cloud-hypervisor\n").to_stderr
  end

  it "keeps the old message and exit 1 for a cloud-hypervisor VM with an unknown version" do
    prep({"ch_version" => "1.0"})
    expect(CloudHypervisor::Version).to receive(:[]).with("1.0").and_return(nil)
    expect {
      expect(stop_vm(vm_name)).to eq(1)
    }.to output("supported cloud hypervisor version not found\n").to_stderr
  end

  it "execs ch-remote power-button for a cloud-hypervisor VM, as before" do
    prep({"hypervisor" => "ch", "ch_version" => "46.0"})
    ch = CloudHypervisor::Version.new("46.0")
    expect(CloudHypervisor::Version).to receive(:[]).with("46.0").and_return(ch)
    expect(EmulatedStop).not_to receive(:run)
    expect(Process).to receive(:exec).with("/opt/cloud-hypervisor/v46.0/ch-remote", "--api-socket", "/vm/#{vm_name}/ch-api.sock", "power-button")
    expect(stop_vm(vm_name)).to be_nil
  end

  it "defaults a VM without a hypervisor key to cloud-hypervisor" do
    prep({"ch_version" => "46.0"})
    expect(CloudHypervisor::Version).to receive(:[]).with("46.0").and_return(CloudHypervisor::Version.new("46.0"))
    expect(Process).to receive(:exec).with("/opt/cloud-hypervisor/v46.0/ch-remote", "--api-socket", "/vm/#{vm_name}/ch-api.sock", "power-button")
    expect(stop_vm(vm_name)).to be_nil
  end

  it "asks LXC for a clean shutdown of a container, in the VM's network namespace" do
    prep({"hypervisor" => "lxc"})
    expect(EmulatedStop).not_to receive(:run)
    expect(Process).to receive(:exec).with("/usr/bin/nsenter", "--net=/var/run/netns/#{vm_name}", "/usr/bin/lxc-stop", "-n", vm_name, "-P", "/var/lib/ubicloud/lxc", "--nowait") { exit 0 }
    expect(stop_vm(vm_name)).to eq(0)
  end
end
