# frozen_string_literal: true

require "stringio"

RSpec.describe ByohHostWatch do
  let(:location) {
    Location.create(name: "byoh-watch", display_name: "byoh-watch", ui_name: "byoh-watch", visible: false,
      provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {})
  }
  let(:host) {
    Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
      provider_config: {"main_ip4" => "203.0.113.42", "location_label" => location.name, "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
  }
  let(:out) { StringIO.new }
  let(:now) { [0] }
  let(:steps) { [] }

  # A watch on a fake clock: each sleep advances it and runs the next
  # step, the last one again once the steps run out.
  def watch(**)
    clock = -> { now[0] }
    sleeper = lambda do |seconds|
      now[0] += seconds
      step = (steps.size > 1) ? steps.shift : steps.first
      step&.call
    end
    described_class.new(host, out:, clock:, sleeper:, **)
  end

  def strand = Strand[host.id]

  it "returns once the host accepts VMs, printing the labels it passed" do
    steps << -> { strand.update(label: "bootstrap_rhizome") }
    steps << -> { host.update(allocation_state: "accepting") }
    expect(watch.run).to eq :accepting
    expect(out.string).to eq <<~OUT
      [    0s] host Vm::HostNexus.start
      [    5s] host Vm::HostNexus.bootstrap_rhizome
      [   10s] host #{host.ubid} is accepting VMs
    OUT
  end

  it "prints retries, children, their exits and each page once" do
    strand.update(label: "prep", try: 2)
    child = Strand.create(parent_id: host.id, prog: "LearnCpu", label: "start", stack: [{"subject_id" => host.id}])
    steps << lambda do
      strand.update(try: 3)
      child.update(exitval: Sequel.pg_jsonb({"msg" => "done"}))
      Prog::PageNexus.assemble("host has an expired deadline!", ["Deadline", host.id], strand.ubid, resource_id: host.id)
      Prog::PageNexus.assemble("related page", ["Other", host.id], [strand.ubid], resource_id: nil)
    end
    steps << -> { host.update(allocation_state: "accepting") }
    expect(watch.run).to eq :accepting
    expect(out.string.lines).to eq [
      "[    0s] host Vm::HostNexus.prep (try 2)\n",
      "[    0s]   #{child.ubid} LearnCpu.start\n",
      "[    5s] host Vm::HostNexus.prep retry 3\n",
      "[    5s]   #{child.ubid} LearnCpu exited\n",
      "[    5s] page: host has an expired deadline!\n",
      "[    5s] page: related page\n",
      "[   10s] host #{host.ubid} is accepting VMs\n",
    ]
  end

  it "says respirate is not running when the strand never leaves start" do
    expect(watch.run).to eq :respirate
    expect(now[0]).to eq 120
    expect(out.string).to include "! host strand #{host.ubid} has not started in 120 s: respirate is not running"
    expect(out.string).to include "will reboot the host"
    expect(out.string).to end_with "Resume the watch with: bin/byoh-host watch #{host.ubid} (packaged: ubicloud-admin host watch #{host.ubid})\n"
  end

  it "counts a strand at start that holds a lease as running" do
    strand.update(lease: Time.now + 60)
    steps << -> { now[0] >= 200 && host.update(allocation_state: "accepting") }
    expect(watch.run).to eq :accepting
  end

  it "gives up on a phase that outlives its limit, following a pushed prog to its HostNexus label" do
    strand.update(prog: "BootstrapRhizome", label: "setup", stack: [{"link" => ["Vm::HostNexus", "bootstrap_rhizome"]}, "not a frame", {}])
    expect(described_class.host_label(strand)).to eq "bootstrap_rhizome"
    expect(watch.run).to eq :timeout
    expect(now[0]).to eq 605
    expect(out.string).to include "! host #{host.ubid} has been in its bootstrap phase (at BootstrapRhizome.setup) for 605 s, over its 600 s limit"
  end

  it "restarts the phase clock when the phase changes" do
    strand.update(label: "bootstrap_rhizome")
    steps << -> { (now[0] == 500) && strand.update(label: "download_boot_images") }
    expect(watch(timeout: 1000).run).to eq :timeout
    expect(out.string).to include "! host #{host.ubid} is not accepting VMs after 1000 s (--timeout)"
  end

  it "follows the bring-up through patch, which comes after the boot image download" do
    strand.update(label: "wait_download_boot_images")
    steps << -> { strand.update(label: "patch") }
    steps << -> { strand.update(label: "prep_reboot") }
    steps << -> { host.update(allocation_state: "accepting") }
    expect(watch.run).to eq :accepting
    expect(out.string).to include "host Vm::HostNexus.patch\n"
  end

  # Every HostNexus label is part of a bring-up phase, or a label a host
  # reaches only once it accepts VMs or leaves the bring-up; a new label
  # must be put in one or the other.
  it "has a phase for every HostNexus label of a bring-up" do
    outside = %w[configure_metrics wait unavailable prep_graceful_reboot destroy pvm_uninstall pvm_uninstalled]
    labels = Prog::Vm::HostNexus.labels.map(&:to_s)
    expect(labels - outside - described_class::PHASE_OF.keys).to eq []
    expect(described_class::PHASE_OF.keys - labels).to eq []
    expect(described_class::PHASE_OF.keys & outside).to eq []
    expect(described_class::PHASE_OF.values_at("install_pvm_host_kernel", "pvm_install_failed", "pvm_retry", "pvm_upgrade")).to eq ["pvm install"] * 4
    expect(described_class::PHASE_OF.values_at("verify_pvm_boot", "pvm_boot_failed", "verify_tier_capacity", "verify_virt_tier", "pvm_guest_kernel_refused")).to eq ["reboot", "reboot", "reboot", "bootstrap", "boot image download"]
  end

  it "gives a PVM host kernel install its own limit" do
    strand.update(label: "pvm_install_failed")
    expect(watch.run).to eq :timeout
    expect(now[0]).to eq 2705
    expect(out.string).to include "has been in its pvm install phase (at Vm::HostNexus.pvm_install_failed) for 2705 s, over its 2700 s limit"
  end

  it "follows a PVM host kernel upgrade of a draining host under the install's limit" do
    strand.update(label: "pvm_upgrade")
    host.update(allocation_state: "draining")
    expect(watch.run).to eq :timeout
    expect(out.string).to include "has been in its pvm install phase (at Vm::HostNexus.pvm_upgrade)"
  end

  it "stops at once on a host whose PVM kernel is being uninstalled" do
    strand.update(label: "pvm_uninstall")
    expect(watch.run).to eq :not_bringup
  end

  it "stops at once on a host outside the bring-up that is not accepting" do
    strand.update(label: "wait")
    host.update(allocation_state: "draining")
    expect(watch.run).to eq :not_bringup
    expect(now[0]).to eq 0
    expect(out.string).to include "! host #{host.ubid} is draining at Vm::HostNexus.wait, which is not part of a bring-up"
    expect(described_class::EXIT[:not_bringup]).to eq 3
  end

  it "has no phase for a prog pushed from elsewhere, and stops on it" do
    strand.update(prog: "Other", label: "x", stack: [{}])
    expect(described_class.host_label(strand)).to be_nil
    expect(watch.run).to eq :not_bringup
    expect(out.string).to include "is unprepared at Other.x, which is not part of a bring-up"
  end

  it "gives a hardware reset its own limit, so a reset wedged without a BMC ends the watch" do
    strand.update(label: "hardware_reset")
    expect(watch.run).to eq :timeout
    expect(now[0]).to eq 1205
    expect(out.string).to include "has been in its hardware reset phase (at Vm::HostNexus.hardware_reset) for 1205 s, over its 1200 s limit"
  end

  it "reports a destroyed host" do
    DB[:strand].where(id: host.id).delete
    expect(watch.run).to eq :gone
    expect(out.string).to eq "! host #{host.ubid} no longer exists; it was destroyed\n"
  end

  it "stops on Ctrl-C and says how to resume" do
    strand.update(label: "prep")
    steps << -> { raise Interrupt }
    expect(watch.run).to eq :interrupted
    expect(out.string).to include "! watch interrupted\n  The bring-up keeps running"
  end
end
