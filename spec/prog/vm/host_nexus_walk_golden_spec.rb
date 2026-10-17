# frozen_string_literal: true

require_relative "../../model/spec_helper"

# The labels and host commands of HostNexus from the boot image
# downloads to accepting VMs, and of an out-of-band reboot, for every
# tier but pvm: the PVM host kernel walk (host_nexus_pvm_spec.rb) adds
# nothing to them.
RSpec.describe Prog::Vm::HostNexus do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:commands) { [] }

  def respond(cmd, stdin: nil, **)
    (want_cmd, want_stdin), reply = commands.shift || raise("unexpected command #{cmd.inspect}")
    raise "expected #{want_cmd.inspect} (stdin #{want_stdin.inspect}), got #{cmd.inspect} (stdin #{stdin.inspect})" unless want_cmd == cmd && want_stdin == stdin

    reply
  end

  def queue(cmd, reply = "", stdin: nil) = commands << [[cmd, stdin], reply]

  # Runs the strand from label until it reaches stop, following its hops
  # and running a label again after a nap; returns the labels it ran.
  def walk(st, label, stop)
    labels = []
    until label == stop
      st.update(label:)
      prog = described_class.new(st.reload)
      allow(prog.sshable).to receive(:_cmd) { |cmd, **kw| respond(cmd, **kw) }
      allow(prog.vm_host).to receive(:sshable).and_return(prog.sshable)
      allow(prog.sshable).to receive(:available?).and_return(true)
      allow(prog).to receive(:available?).and_return(true)
      result = catch(:prog_return) { prog.public_send(label) }
      st.modified!(:stack)
      st.save_changes
      labels << label
      raise "the walk did not reach #{stop}: #{labels.join(" ")}" if labels.size > 20

      label = result.new_label if result.is_a?(Prog::Base::Hop)
    end
    labels
  end

  meminfo = "MemTotal:       33554432 kB\nMemAvailable:   20000000 kB\nHugePages_Total:    8\nHugePages_Free:     8\nHugepagesize:    1048576 kB\n"
  {
    "kvm" => ["verify_hugepages", "standard"],
    "container" => ["verify_tier_capacity", "container"],
    "emulated" => ["verify_tier_capacity", "emulated"],
  }.each do |tier, (verify, family)|
    context "with a #{tier} host" do
      let(:vm_host) { create_byoh_vm_host(location, virt_tier: tier, family:, net6: "fd00:1:2:3::/64", total_cores: 4, total_cpus: 8, used_cores: 1, accepts_slices: false, allocation_state: "unprepared", last_boot_id: "b0") }
      let(:st) { Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "patch", stack: [{"default_boot_images" => [], "vhost_block_backend_version" => "v0.4.1", "install_os" => false}]) }

      it "patches, reboots and accepts VMs with the same labels and commands" do
        queue("common/bin/daemonizer2 check apply_patches", "NotStarted")
        queue("common/bin/daemonizer2 run apply_patches sudo bash -c apt\\ update\\ \\&\\&\\ apt\\ full-upgrade\\ -y")
        queue("common/bin/daemonizer2 check apply_patches", "Succeeded")
        queue("common/bin/daemonizer2 clean apply_patches")
        queue("cat /proc/sys/kernel/random/boot_id", "b0\n")
        queue("sudo host/bin/reboot-host b0", "b1\n")
        queue("cat /proc/meminfo", meminfo)

        expect(walk(st, "patch", "configure_metrics")).to eq ["patch", "patch", "prep_reboot", "reboot", verify, "start_slices", "start_vms"]
        expect(commands).to be_empty
        expect(st.reload.stack.first.keys.grep(/pvm/)).to eq []
        expect(vm_host.reload.allocation_state).to eq "accepting"
      end

      it "restarts its VMs after an out-of-band reboot from wait and from unavailable" do
        vm_host.update(allocation_state: "accepting")
        st
        from = lambda do |label|
          vm_host.incr_checkup
          queue("cat /proc/sys/kernel/random/boot_id", "#{label}\n")
          expect(walk(st, label, "start_vms")).to eq [label, "start_slices"]
        end
        from.call("wait")
        from.call("unavailable")
        expect(commands).to be_empty
      end

      it "waits 6 hours at wait without a host command (the boot id check is pvm's)" do
        vm_host.update(allocation_state: "accepting", virt_probe: Sequel.pg_jsonb({"probed_at" => Time.now.utc.iso8601}))
        st.update(label: "wait")
        prog = described_class.new(st.reload)
        allow(prog.sshable).to receive(:_cmd) { |cmd, **kw| respond(cmd, **kw) }
        expect { prog.wait }.to nap(6 * 60 * 60)
      end
    end
  end
end
