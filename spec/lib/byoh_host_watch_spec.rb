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

  it "has no phase for a prog pushed from elsewhere" do
    strand.update(prog: "Other", label: "x", stack: [{}])
    expect(described_class.host_label(strand)).to be_nil
    expect(watch(timeout: 10).run).to eq :timeout
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
