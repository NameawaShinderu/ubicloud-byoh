# frozen_string_literal: true

require_relative "../../model/spec_helper"
require_relative "../../../rhizome/host/lib/virt_probe"

# HostNexus on a pvm host whose PVM host kernel the control plane
# installs (docs/byoh/NO_KVM.md section 6.7): the install after patch,
# the one-shot PVM boot that verify_pvm_boot checks, and the operator's
# retry and uninstall. host_nexus_tier_spec.rb and the goldens below pin
# that other tiers walk as before.
RSpec.describe Prog::Vm::HostNexus do
  subject(:nx) { described_class.new(st) }

  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:vm_host) { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm", net6: "fd00:1:2:3::/64", total_cores: 4, total_cpus: 8, used_cores: 1, os_version: "ubuntu-24.04") }
  let(:st) { Strand.create_with_id(vm_host, prog: "Vm::HostNexus", label: "wait", stack: [{}]) }
  let(:sshable) { nx.sshable }
  let(:stock) { "7.0.0-1014-aws" }
  let(:pvm) { "6.12.33-pvm" }
  let(:stock_entry) { "Advanced options for Ubuntu>Ubuntu, with Linux #{stock}" }
  let(:row) { ByohPvmHost.create(vm_host_id: vm_host.id, state: "install_pending", install: true, host_deb_sha256: "a" * 64, lockdown: "none", meltdown: "Not affected") }
  let(:tool) { "sudo host/bin/install-pvm-host-kernel" }

  before do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
    row
    st
  end

  def facts(**over)
    {
      "arch" => "x86_64", "kernel" => stock, "cpu_vendor" => "GenuineIntel", "cpu_model" => "Intel Xeon Platinum 8375C",
      "cpu_flags" => %w[hypervisor pdpe1gb], "dev_kvm" => false, "modules" => [], "virt_vm" => "kvm", "virt_container" => "none",
      "bios_log" => nil, "dmi" => {"sys_vendor" => "Amazon EC2"}, "cgroup2" => true, "apparmor" => true,
      "pvm_module_available" => false, "vulnerabilities" => {"meltdown" => "Not affected"}, "secure_boot" => false,
    }.merge(over.transform_keys(&:to_s))
  end

  def stock_probe(**) = JSON.generate(VirtProbe.report(facts(**)))

  def pvm_probe(**over) = JSON.generate(VirtProbe.report(facts(kernel: pvm, dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_pvm], pvm_module_available: true, **over)))

  def record(json) = ByohVirtLadder.parse(json).record

  def status(**over)
    {
      "result" => "ok", "kernel" => pvm, "pti_off" => true, "kvm_pvm_loaded" => true, "running_pvm" => true,
      "grubenv" => {"saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm"}, "stock_entry_resolves" => true,
      "dev_kvm" => {"chardev" => true, "mode" => "660", "group" => "kvm"},
      "boot_unit" => {"ActiveState" => "active", "Result" => "success", "UnitFileState" => "enabled"},
      "state" => {"state" => "armed", "kver" => pvm, "stock_kver" => stock, "stock_entry" => stock_entry, "steps" => %w[fetch verify grub_pin hold_stock install_deb check_drivers grub_entry boot_unit arm]},
    }.merge(over.transform_keys(&:to_s))
  end

  def stock_status(**over)
    status(kernel: stock, pti_off: false, kvm_pvm_loaded: false, running_pvm: false, dev_kvm: {"chardev" => false},
      boot_unit: {"ActiveState" => "inactive", "Result" => "success", "UnitFileState" => "enabled"}, **over)
  end

  def expect_tool(command, result, params: {}, exit_code: 0)
    expectation = expect(sshable).to receive(:_cmd).with("#{tool} #{command}", stdin: JSON.generate(params))
    if exit_code.zero?
      expectation.and_return(JSON.generate(result))
    else
      expectation.and_raise(Sshable::SshError.new("#{tool} #{command}", JSON.generate(result), "", exit_code, nil))
    end
  end

  def page(type) = Page.from_tag_parts(type, vm_host.ubid)

  describe "#verify_virt_tier" do
    before { st.update(label: "verify_virt_tier") }

    it "takes the stock kernel of a host it installs on, once rhizome's preflight passes" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      Prog::PageNexus.assemble("old", ["ByohPvmInstall", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
      expect_tool("preflight", {"result" => "ok", "refusals" => [], "facts" => {}})
      expect { nx.verify_virt_tier }.to hop("setup_storage_backend")
      expect(page("ByohPvmInstall").resolve_set?).to be true
    end

    it "pages the preflight's refusals and checks again in 5 minutes, changing nothing" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      expect_tool("preflight", {"result" => "refused", "refusals" => ["GRUB_SAVEDEFAULT=true is set"], "facts" => {"kernel" => stock}}, exit_code: 2)
      expect { nx.verify_virt_tier }.to nap(5 * 60)
      expect(page("ByohPvmInstall").summary).to eq "#{vm_host.ubid} cannot take the PVM host kernel: GRUB_SAVEDEFAULT=true is set"
      expect(page("ByohPvmInstall").details.to_h).to include("refusals" => ["GRUB_SAVEDEFAULT=true is set"], "fix" => start_with("Nothing was changed on the host."))
      expect(row.reload.state).to eq "install_pending"
    end

    it "pages a refusal without a list" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      expect_tool("preflight", {"result" => "refused", "error" => "another install-pvm-host-kernel run holds the lock"}, exit_code: 2)
      expect { nx.verify_virt_tier }.to nap(5 * 60)
      expect(page("ByohPvmInstall").details["refusals"]).to eq ["another install-pvm-host-kernel run holds the lock"]
    end

    it "fails on an unexpected error of the tool, for the strand's retry" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      expect_tool("preflight", {"result" => "error", "error" => "boom"}, exit_code: 1)
      expect { nx.verify_virt_tier }.to raise_error(Sshable::SshError)
    end

    it "goes to the uninstall the operator asked for" do
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      vm_host.incr_pvm_uninstall
      expect { nx.verify_virt_tier }.to hop("pvm_uninstall")
    end

    it "refuses the stock kernel of a host it does not install on" do
      row.update(state: "committed", install: false)
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(stock_probe)))
      expect { nx.verify_virt_tier }.to raise_error(RuntimeError, /\Apvm host does not have the tier's prerequisites/)
    end

    it "goes on without the preflight on a host that runs its PVM kernel already" do
      row.update(state: "committed", install: false)
      vm_host.update(virt_probe: Sequel.pg_jsonb(record(pvm_probe)))
      expect { nx.verify_virt_tier }.to hop("setup_storage_backend")
    end
  end

  describe "#patch" do
    let(:dpkg) { "dpkg-query -W -f \\$\\{Package\\}\\ \\$\\{db:Status-Status\\}\\\\n linux-image-\\[0-9\\]\\*" }
    let(:packages) { "linux-image-#{stock} installed\nlinux-image-6.8.0-1-aws not-installed\n" }

    before do
      st.update(label: "patch")
      allow(nx.vm_host).to receive(:sshable).and_return(sshable)
    end

    it "records the kernel packages before the upgrade" do
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check apply_patches").and_return("NotStarted")
      expect(sshable).to receive(:_cmd).with(dpkg).and_return(packages)
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 run apply_patches sudo bash -c apt\\ update\\ \\&\\&\\ apt\\ full-upgrade\\ -y", stdin: nil, log: true)
      expect { nx.patch }.to nap(60)
      expect(st.stack.first["pvm_patch_kernels"]).to eq("before" => ["linux-image-#{stock}"])
    end

    it "starts a new record on the next patch run" do
      refresh_frame(nx, new_values: {"pvm_patch_kernels" => {"before" => ["x"], "after" => ["y"]}})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check apply_patches").and_return("Failed")
      expect(sshable).to receive(:_cmd).with(dpkg).and_return("")
      expect(sshable).to receive(:_cmd).with(/\Acommon\/bin\/daemonizer2 run apply_patches /, stdin: nil, log: true)
      expect { nx.patch }.to nap(60)
      expect(st.stack.first["pvm_patch_kernels"]).to eq("before" => [])
    end

    it "installs the PVM host kernel after the upgrade" do
      refresh_frame(nx, new_values: {"pvm_patch_kernels" => {"before" => ["linux-image-#{stock}"]}})
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check apply_patches").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean apply_patches")
      expect(sshable).to receive(:_cmd).with(dpkg).and_return("linux-image-#{stock} installed\nlinux-image-7.0.0-1015-aws installed\n")
      expect { nx.patch }.to hop("install_pvm_host_kernel")
      expect(st.stack.first["pvm_patch_kernels"]).to eq("before" => ["linux-image-#{stock}"], "after" => ["linux-image-#{stock}", "linux-image-7.0.0-1015-aws"])
    end

    it "reboots a host whose PVM kernel is installed" do
      row.update(state: "committed")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check apply_patches").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean apply_patches")
      expect(sshable).to receive(:_cmd).with(dpkg).and_return(packages)
      expect { nx.patch }.to hop("prep_reboot")
      expect(st.stack.first["pvm_patch_kernels"]).to eq("after" => ["linux-image-#{stock}"])
    end
  end

  describe "#install_pvm_host_kernel" do
    let(:unit) { "install_pvm_host_kernel" }

    before { st.update(label: "install_pvm_host_kernel") }

    it "starts the daemonized install with the location's host-deb pin" do
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(unit, "sudo", "host/bin/install-pvm-host-kernel", "install", stdin: JSON.generate("host_deb" => pvm_test_pins["host_deb"]))
      expect { nx.install_pvm_host_kernel }.to nap(30)
      expect(row.reload.state).to eq "installing"
      expect(st.stack.first).to include("deadline_target" => "prep_reboot")
      expect(Time.parse(st.stack.first["deadline_at"]) - Time.now).to be_within(60).of(45 * 60)
    end

    it "waits while it runs" do
      expect(sshable).to receive(:d_check).with(unit).and_return("InProgress")
      expect { nx.install_pvm_host_kernel }.to nap(30)
    end

    it "refuses, before any change, a pin the operator did not acknowledge for the host" do
      location.update(byoh_virt: Sequel.pg_jsonb(location.byoh_virt.to_h.merge("pvm_kernel" => pvm_test_pins.merge("host_deb" => {"url" => "https://example.com/new.deb", "sha256" => "c" * 64}))))
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.values.slice(:state, :last_error)).to eq(state: "failed", last_error: "location byoh-test pins host-deb sha256 #{"c" * 64}, but the operator acknowledged sha256 #{"a" * 64} for this host")
      expect(page("ByohPvmInstall").details["fix"]).to include("bin/byoh-virt pvm retry --host #{vm_host.ubid} --accept-host-deb #{"c" * 64}")
    end

    it "refuses in a location that pins no host kernel any more" do
      location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm], "acks" => {}}))
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to start_with "location byoh-test pins no PVM host kernel"
      expect(page("ByohPvmInstall").details["fix"]).to include("--accept-host-deb SHA256")
    end

    it "records the armed install and reboots the host" do
      Prog::PageNexus.assemble("old", ["ByohPvmInstall", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
      expect(sshable).to receive(:d_check).with(unit).and_return("Succeeded")
      expect_tool("status", stock_status)
      expect(sshable).to receive(:d_clean).with(unit)
      expect { nx.install_pvm_host_kernel }.to hop("prep_reboot")
      expect(row.reload.values.slice(:state, :host_kver, :stock_kver, :stock_entry, :last_error)).to eq(state: "armed", host_kver: pvm, stock_kver: stock, stock_entry:, last_error: nil)
      expect(st.stack.first["pvm_status"]).to include("kernel" => stock, "grubenv" => {"saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm"})
      expect(page("ByohPvmInstall").resolve_set?).to be true
    end

    it "pages an install refused before any change" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect_tool("status", stock_status(state: {"state" => "refused", "steps" => [], "last_result" => {"result" => "refused", "error" => "the host kernel package has sha256 0, not the pinned a"}}))
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("Oct 17 h install[1]: {\"result\":\"refused\",\"step\":\"verify\",\"error\":\"the host kernel package has sha256 0, not the pinned a\"}\n")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.values.slice(:state, :last_error)).to eq(state: "failed", last_error: "the host kernel package has sha256 0, not the pinned a")
      expect(page("ByohPvmInstall").summary).to eq "#{vm_host.ubid} refused to install the PVM host kernel: the host kernel package has sha256 0, not the pinned a"
      expect(page("ByohPvmInstall").details.to_h).to include("step" => "verify", "fix" => start_with("The install was refused before any change on the host."))
    end

    it "pages the preflight refusals of an install on a fresh host" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect_tool("status", stock_status(state: nil))
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("started\n{\"result\":\"refused\",\"refusals\":[\"Secure Boot is on\",\"no space\"]}\n")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to eq "Secure Boot is on; no space"
    end

    it "pages an install that failed after a change, which rhizome un-armed" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect_tool("status", stock_status(state: {"state" => "failed", "steps" => %w[fetch verify grub_pin], "last_result" => {"result" => "failed", "error" => "apt-get failed"}}))
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("{not json}\nno result here\n")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to eq "apt-get failed"
      details = page("ByohPvmInstall").details.to_h
      expect(details["fix"]).to start_with "The install failed after step grub_pin; rhizome already un-armed the host"
      expect(details["last_log_lines"]).to eq "{not json}\nno result here"
    end

    it "pages a failure without a result as the log lines" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect_tool("status", stock_status(state: {"state" => "installing"}))
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("[1, 2]\nKilled\n")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { nx.install_pvm_host_kernel }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to eq "see the log lines"
      expect(page("ByohPvmInstall").details["fix"]).to start_with "The install failed after step none;"
    end
  end

  describe "#pvm_install_failed" do
    before { st.update(label: "pvm_install_failed") }

    it "waits for the operator without the install's deadline" do
      refresh_frame(nx, new_values: {"deadline_target" => "prep_reboot", "deadline_at" => (Time.now + 60).to_s})
      expect { nx.pvm_install_failed }.to nap(6 * 60 * 60)
      expect(st.stack.first.keys).not_to include("deadline_at", "deadline_target")
      expect { described_class.new(st).pvm_install_failed }.to nap(6 * 60 * 60)
    end

    it "retries when asked" do
      vm_host.incr_pvm_retry
      expect { nx.pvm_install_failed }.to hop("pvm_retry")
      expect(Semaphore.where(strand_id: vm_host.id, name: "pvm_retry").count).to eq 0
    end

    it "uninstalls when asked" do
      vm_host.incr_pvm_uninstall
      expect { nx.pvm_install_failed }.to hop("pvm_uninstall")
    end
  end

  describe "#pvm_retry" do
    before { row.update(state: "failed", last_error: "x") }

    it "installs again at once when the failed install changed nothing" do
      expect_tool("status", stock_status(state: {"state" => "refused"}))
      expect { nx.pvm_retry }.to hop("install_pvm_host_kernel")
      expect(row.reload.values.slice(:state, :last_error)).to eq(state: "install_pending", last_error: nil)
    end

    it "uninstalls first what a failed install left" do
      expect_tool("status", stock_status(state: {"state" => "failed"}))
      expect { nx.pvm_retry }.to hop("pvm_uninstall")
      expect(st.stack.first["pvm_reinstall"]).to be true
    end
  end

  describe "#prep_reboot" do
    before do
      st.update(label: "prep_reboot")
      row.update(state: "armed", host_kver: pvm, stock_kver: stock, stock_entry:)
    end

    it "arms one PVM kernel boot before the reboot" do
      expect_tool("arm", {"result" => "ok", "grubenv" => {"saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm"}})
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("b1\n")
      expect { nx.prep_reboot }.to hop("reboot")
      expect(st.stack.first["pvm_status"]["grubenv"]).to eq("saved_entry" => stock_entry, "next_entry" => "ubicloud-pvm")
    end

    it "does not reboot a host it cannot arm, which takes no new VMs" do
      vm_host.update(allocation_state: "accepting")
      vm_host.incr_reboot
      expect_tool("arm", {"result" => "refused", "error" => "the stock entry no longer matches"}, exit_code: 2)
      expect { nx.prep_reboot }.to hop("pvm_boot_failed")
      expect(vm_host.reload.allocation_state).to eq "draining"
      expect(st.stack.first["pvm_drained"]).to be true
      expect(row.reload.last_error).to eq "arm: the stock entry no longer matches"
      expect(page("ByohPvmBoot").summary).to eq "#{vm_host.ubid} was not rebooted: its PVM kernel boot could not be armed: the stock entry no longer matches"
      expect(vm_host.reboot_set?(cached: false)).to be true
    end

    it "does not arm a host rebooted for an uninstall, nor one it did not install" do
      vm_host.incr_pvm_uninstall
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("b1\n").twice
      expect { nx.prep_reboot }.to hop("reboot")
      Semaphore.where(strand_id: vm_host.id).destroy
      row.update(install: false)
      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.prep_reboot }.to hop("reboot")
    end
  end

  describe "#reboot" do
    it "checks the PVM boot" do
      st.update(label: "reboot")
      vm_host.update(last_boot_id: "old")
      expect(sshable).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/reboot-host old").and_return("new\n")
      expect { nx.reboot }.to hop("verify_pvm_boot")
    end
  end

  describe "#verify_pvm_boot" do
    before do
      st.update(label: "verify_pvm_boot")
      row.update(state: "armed", host_kver: pvm, stock_kver: stock, stock_entry:)
    end

    it "commits a boot of the PVM kernel with a usable /dev/kvm and starts the host's VMs" do
      %w[ByohPvmBoot ByohVirtTier].each { Prog::PageNexus.assemble("old", [it, vm_host.ubid], vm_host.ubid, resource_id: vm_host.id) }
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe)
      expect_tool("status", status)
      expect { nx.verify_pvm_boot }.to hop("verify_tier_capacity")
      expect(row.reload.values.slice(:state, :host_kver, :last_error)).to eq(state: "committed", host_kver: pvm, last_error: nil)
      expect(vm_host.reload.virt_probe.to_h).to include("tier" => "pvm", "probed_at" => String)
      expect(page("ByohPvmBoot").resolve_set?).to be true
      expect(page("ByohVirtTier").resolve_set?).to be true
    end

    it "waits for the boot unit of a PVM kernel boot that SSH reached first, then judges the boot" do
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe).exactly(3).times
      expect(sshable).to receive(:_cmd).with("#{tool} status", stdin: "{}").and_return(
        JSON.generate(status(boot_unit: {"ActiveState" => "activating", "Result" => "success"})),
        JSON.generate(status(boot_unit: {"ActiveState" => "inactive", "Result" => "success"})),
        JSON.generate(status),
      )
      expect { nx.verify_pvm_boot }.to nap(10)
      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.verify_pvm_boot }.to nap(10)
      expect(st.stack.first["pvm_boot_waits"]).to eq 2
      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.verify_pvm_boot }.to hop("verify_tier_capacity")
      expect(st.stack.first.key?("pvm_boot_waits")).to be false
    end

    it "gives up waiting for the boot unit after 5 minutes" do
      refresh_frame(nx, new_values: {"pvm_boot_waits" => 30})
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe)
      expect_tool("status", status(boot_unit: {"ActiveState" => "activating", "Result" => "success"}))
      expect_tool("disarm", {"result" => "ok"})
      expect { nx.verify_pvm_boot }.to hop("pvm_boot_failed")
      expect(row.reload.last_error).to eq "ubicloud-pvm-boot.service is activating (success), not active"
    end

    it "does not wait for a boot unit whose condition fails, on a kernel without pti=off" do
      vm_host.update(allocation_state: "unprepared")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe)
      expect_tool("status", status(pti_off: false, boot_unit: {"ActiveState" => "inactive", "Result" => "success"}))
      expect_tool("disarm", {"result" => "ok"})
      expect { nx.verify_pvm_boot }.to hop("pvm_boot_failed")
      expect(vm_host.reload.allocation_state).to eq "unprepared"
      expect(st.stack.first.key?("pvm_drained")).to be false
    end

    it "returns a host it drained to accepting" do
      vm_host.update(allocation_state: "draining")
      refresh_frame(nx, new_values: {"pvm_drained" => true})
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe)
      expect_tool("status", status)
      expect { nx.verify_pvm_boot }.to hop("verify_tier_capacity")
      expect(vm_host.reload.allocation_state).to eq "accepting"
      expect(st.stack.first.key?("pvm_drained")).to be false
    end

    it "takes a host back on its stock kernel out of the PVM boot path and pages the recovery" do
      vm_host.update(allocation_state: "accepting")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(stock_probe)
      expect_tool("status", stock_status)
      expect_tool("disarm", {"result" => "ok", "grubenv" => {"saved_entry" => stock_entry}})
      expect { nx.verify_pvm_boot }.to hop("pvm_boot_failed")
      expect(row.reload.state).to eq "armed"
      expect(row.last_error).to start_with "the probe says none (L3-L5)"
      expect(vm_host.reload.allocation_state).to eq "draining"
      p = page("ByohPvmBoot")
      expect(p.summary).to eq "#{vm_host.ubid} booted its stock kernel #{stock}, not the PVM kernel #{pvm}"
      expect(p.details["fix"]).to start_with("The host booted the stock kernel #{stock}: its PVM kernel boot failed or hung, and GRUB fell back. Keep the serial console log")
        .and include("bin/byoh-virt pvm retry --host #{vm_host.ubid} arms one more PVM boot", "power-cycle it from the provider console")
      expect(st.stack.first["pvm_status"]).to include("kernel" => stock, "grubenv" => {"saved_entry" => stock_entry})
    end

    {
      "a failed boot unit" => [{boot_unit: {"ActiveState" => "failed", "Result" => "exit-code"}}, {}, "ubicloud-pvm-boot.service is failed (exit-code), not active"],
      "no boot unit state" => [{boot_unit: nil}, {}, "ubicloud-pvm-boot.service is  (), not active"],
      "a /dev/kvm of the wrong group" => [{dev_kvm: {"chardev" => true, "mode" => "660", "group" => "root"}}, {}, "/dev/kvm is 660 root, not 660 kvm"],
      "no /dev/kvm" => [{dev_kvm: nil}, {}, "/dev/kvm is missing, not 660 kvm"],
      "another PVM kernel" => [{kernel: "6.12.34-pvm"}, {}, "the running kernel is 6.12.34-pvm, not the PVM kernel 6.12.33-pvm"],
      "a Meltdown-affected CPU" => [{}, {vulnerabilities: {"meltdown" => "Mitigation: PTI"}}, "This CPU's Meltdown status is \"Mitigation: PTI\""],
      "an old KVM API" => [{}, {kvm_api: 11}, "the KVM API is 11, not 12"],
    }.each do |name, (over, probe_over, problem)|
      it "refuses #{name}, disarming first" do
        expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe(**probe_over))
        expect_tool("status", status(**over))
        expect_tool("disarm", {"result" => "ok", "grubenv" => {"saved_entry" => stock_entry}})
        expect { nx.verify_pvm_boot }.to hop("pvm_boot_failed")
        expect(row.reload.last_error).to include(problem)
        expect(page("ByohPvmBoot").summary).to start_with "#{vm_host.ubid} cannot run pvm VMs after its boot: "
        expect(page("ByohPvmBoot").details["fix"]).to start_with "The host was taken out of the PVM boot path (disarm)"
      end
    end

    it "checks only the probe of a host it did not install, and never disarms it" do
      row.update(state: "committed", install: false, host_kver: nil)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(pvm_probe, stock_probe)
      expect { nx.verify_pvm_boot }.to hop("verify_tier_capacity")
      expect(row.reload.state).to eq "committed"

      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.verify_pvm_boot }.to hop("pvm_boot_failed")
      expect(page("ByohPvmBoot").details["fix"]).to start_with "The host's PVM kernel was installed outside the control plane."
    end

    it "checks only the probe of a pvm host without a PVM kernel record" do
      row.destroy
      expect(sshable).to receive(:_cmd).with("sudo host/bin/virt-probe --json").and_return(stock_probe, pvm_probe)
      expect { nx.verify_pvm_boot }.to hop("pvm_boot_failed")
      expect(page("ByohPvmBoot").details["fix"]).to start_with "The host's PVM kernel was installed outside the control plane."
      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.verify_pvm_boot }.to hop("verify_tier_capacity")
    end

    it "goes back to an uninstall the host was rebooted for" do
      vm_host.incr_pvm_uninstall
      expect { nx.verify_pvm_boot }.to hop("pvm_uninstall")
    end
  end

  describe "a pvm host without a PVM kernel record" do
    before { row.destroy }

    it "patches and reboots it as a host that runs its PVM kernel already, never arming it" do
      allow(nx.vm_host).to receive(:sshable).and_return(sshable)
      st.update(label: "patch")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 check apply_patches").and_return("Succeeded")
      expect(sshable).to receive(:_cmd).with("common/bin/daemonizer2 clean apply_patches")
      expect(sshable).to receive(:_cmd).with(/\Adpkg-query /).and_return("")
      expect { nx.patch }.to hop("prep_reboot")
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("b1\n")
      expect { nx.prep_reboot }.to hop("reboot")
    end
  end

  describe "#pvm_boot_failed" do
    before { st.update(label: "pvm_boot_failed") }

    it "waits for the operator" do
      expect { nx.pvm_boot_failed }.to nap(6 * 60 * 60)
    end

    it "arms one more boot and reboots on a retry" do
      vm_host.incr_pvm_retry
      refresh_frame(nx, new_values: {"deadline_target" => "wait", "deadline_at" => (Time.now + 60).to_s})
      expect { nx.pvm_boot_failed }.to hop("prep_reboot")
      expect(st.stack.first.key?("deadline_at")).to be false
    end

    it "uninstalls when asked" do
      vm_host.incr_pvm_uninstall
      expect { nx.pvm_boot_failed }.to hop("pvm_uninstall")
    end
  end

  describe "#pvm_uninstall" do
    let(:unit) { "uninstall_pvm_host_kernel" }

    before do
      st.update(label: "pvm_uninstall")
      row.update(state: "committed", host_kver: pvm, stock_kver: stock, stock_entry:)
      vm_host.incr_pvm_uninstall
    end

    it "waits while the host has VMs" do
      create_vm(vm_host_id: vm_host.id, family: "pvm", location_id: location.id)
      expect { nx.pvm_uninstall }.to nap(60)
    end

    it "disarms a host on its PVM kernel and reboots it to the stock kernel first" do
      vm_host.update(allocation_state: "accepting")
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect_tool("status", status)
      expect_tool("disarm", {"result" => "ok", "grubenv" => {"saved_entry" => stock_entry}})
      expect { nx.pvm_uninstall }.to hop("prep_reboot")
      expect(vm_host.reload.allocation_state).to eq "draining"
      expect(vm_host.pvm_uninstall_set?(cached: false)).to be true
      expect(st.stack.first["deadline_target"]).to eq "pvm_uninstalled"
    end

    it "runs the daemonized uninstall on the stock kernel" do
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect_tool("status", stock_status)
      expect(sshable).to receive(:d_run).with(unit, "sudo", "host/bin/install-pvm-host-kernel", "uninstall", stdin: "{}")
      expect { nx.pvm_uninstall }.to nap(30)
    end

    it "pages instead of rebooting a host whose stock kernel has pti=off, which no reboot clears" do
      refresh_frame(nx, new_values: {"pvm_reinstall" => true})
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect_tool("status", stock_status(pti_off: true))
      expect_tool("disarm", {"result" => "ok", "grubenv" => {"saved_entry" => stock_entry}})
      expect(sshable).not_to receive(:d_run)
      expect { nx.pvm_uninstall }.to hop("pvm_install_failed")
      expect(vm_host.pvm_uninstall_set?(cached: false)).to be false
      expect(st.stack.first.key?("pvm_reinstall")).to be false
      expect(st.stack.first["pvm_status"]).to include("kernel" => stock, "grubenv" => {"saved_entry" => stock_entry})
      expect(row.reload.values.slice(:state, :last_error)).to eq(state: "failed", last_error: "uninstall: the stock kernel #{stock} has pti=off on its command line")
      expect(page("ByohPvmInstall").summary).to eq "#{vm_host.ubid} could not uninstall its PVM host kernel: the stock kernel #{stock} has pti=off on its command line"
      expect(page("ByohPvmInstall").details["fix"]).to eq "Nothing was uninstalled. Remove pti=off from GRUB_CMDLINE_LINUX* (/etc/default/grub and /etc/default/grub.d), run update-grub and reboot the host, " \
        "then bin/byoh-virt pvm uninstall --host #{vm_host.ubid} again."
    end

    it "waits while it runs" do
      expect(sshable).to receive(:d_check).with(unit).and_return("InProgress")
      expect { nx.pvm_uninstall }.to nap(30)
    end

    it "records the uninstall and pages to register the host again" do
      %w[ByohPvmBoot ByohPvmHostKernel].each { Prog::PageNexus.assemble("old", [it, vm_host.ubid], vm_host.ubid, resource_id: vm_host.id) }
      expect(sshable).to receive(:d_check).with(unit).and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with(unit)
      expect_tool("status", stock_status(state: {"state" => "uninstalled"}))
      expect { nx.pvm_uninstall }.to hop("pvm_uninstalled")
      expect(row.reload.state).to eq "uninstalled"
      expect(vm_host.pvm_uninstall_set?(cached: false)).to be false
      expect(page("ByohPvmBoot").resolve_set?).to be true
      expect(page("ByohPvmUninstalled").details["fix"]).to start_with "The host runs its stock kernel again. Destroy the host and register it again"
    end

    it "installs again after the uninstall of a retry" do
      Semaphore.where(strand_id: vm_host.id).destroy
      refresh_frame(nx, new_values: {"pvm_reinstall" => true})
      row.update(state: "failed")
      expect(sshable).to receive(:d_check).with(unit).and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with(unit)
      expect_tool("status", stock_status(state: {"state" => "uninstalled"}))
      expect { nx.pvm_uninstall }.to hop("install_pvm_host_kernel")
      expect(row.reload.state).to eq "install_pending"
      expect(st.stack.first.keys).not_to include("pvm_reinstall", "deadline_target")
    end

    it "pages an uninstall that failed" do
      refresh_frame(nx, new_values: {"pvm_reinstall" => true})
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("{\"result\":\"failed\",\"error\":\"apt-get purge failed\"}\n")
      expect(sshable).to receive(:d_clean).with(unit)
      expect_tool("status", stock_status(state: {"state" => "failed"}))
      expect { nx.pvm_uninstall }.to hop("pvm_install_failed")
      expect(row.reload.values.slice(:state, :last_error)).to eq(state: "failed", last_error: "uninstall: apt-get purge failed")
      expect(page("ByohPvmInstall").summary).to eq "#{vm_host.ubid} could not uninstall its PVM host kernel: apt-get purge failed"
      expect(st.stack.first.key?("pvm_reinstall")).to be false
    end

    it "pages an uninstall failure from the host's record or the log" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed").twice
      expect(sshable).to receive(:d_logs).with(unit, lines: 20).and_return("x\n").twice
      expect(sshable).to receive(:d_clean).with(unit).twice
      expect(sshable).to receive(:_cmd).with("#{tool} status", stdin: "{}")
        .and_return(JSON.generate(stock_status(state: {"state" => "failed", "last_result" => {"error" => "update-grub failed"}})), JSON.generate(stock_status(state: nil)))
      expect { nx.pvm_uninstall }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to eq "uninstall: update-grub failed"
      expect { described_class.new(st).tap { allow(it).to receive(:sshable).and_return(sshable) }.pvm_uninstall }.to hop("pvm_install_failed")
      expect(row.reload.last_error).to eq "uninstall: see the log lines"
    end
  end

  describe "#pvm_uninstalled" do
    it "waits for the host to be destroyed" do
      expect { nx.pvm_uninstalled }.to nap(6 * 60 * 60)
    end
  end

  describe "#wait" do
    before { vm_host.update(virt_probe: Sequel.pg_jsonb({"probed_at" => Time.now.utc.iso8601})) }

    def stale_page = Page.from_tag_parts("ByohPvmGuestKernelStale", vm_host.ubid)

    it "goes to the uninstall the operator asked for" do
      vm_host.incr_pvm_uninstall
      expect { nx.wait }.to hop("pvm_uninstall")
    end

    it "pages the VMs that boot another guest kernel than the host's current one, until they are stopped and started" do
      ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: "b" * 64, state: "ready", console: "hvc0")
      old = create_vm(vm_host_id: vm_host.id, family: "pvm", location_id: location.id, name: "old")
      current = create_vm(vm_host_id: vm_host.id, family: "pvm", location_id: location.id, name: "current")
      ByohVmGuestKernel.create(vm_id: old.id, sha256: "c" * 64, console: "hvc0")
      ByohVmGuestKernel.create(vm_id: current.id, sha256: "b" * 64, console: "hvc0")
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(stale_page.summary).to eq "#{vm_host.ubid} has 1 pvm VMs on an older guest kernel than #{"b" * 64}"
      expect(stale_page.details.to_h).to include("vms" => [old.ubid], "fix" => start_with("Stop and start each VM"))

      ByohVmGuestKernel[old.id].update(sha256: "b" * 64)
      expect { described_class.new(st).wait }.to nap(6 * 60 * 60)
      expect(stale_page.resolve_set?).to be true
    end

    it "pages nothing on a host without a ready guest kernel" do
      expect { nx.wait }.to nap(6 * 60 * 60)
      expect(stale_page).to be_nil
    end
  end

  describe "an out-of-band reboot" do
    before { vm_host.update(last_boot_id: "old") }

    it "checks the PVM boot from wait" do
      vm_host.incr_checkup
      expect(nx).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("new\n")
      expect { nx.wait }.to hop("verify_pvm_boot")
      expect(vm_host.reload.last_boot_id).to eq "new"
    end

    it "checks the PVM boot from unavailable" do
      st.update(label: "unavailable")
      expect(nx).to receive(:available?).and_return(true)
      expect(sshable).to receive(:_cmd).with("cat /proc/sys/kernel/random/boot_id").and_return("new\n")
      expect { nx.unavailable }.to hop("verify_pvm_boot")
    end
  end

  describe "#pvm_kernel" do
    it "gives the result of a refusal or a failure, and raises on anything else" do
      expect_tool("arm", {"result" => "failed", "error" => "grub-reboot failed"}, exit_code: 3)
      expect(nx.pvm_kernel("arm")).to eq("result" => "failed", "error" => "grub-reboot failed")
      expect(sshable).to receive(:_cmd).and_raise(Sshable::SshError.new("x", "", "", nil, nil))
      expect { nx.pvm_kernel("arm") }.to raise_error(Sshable::SshError)
    end
  end

  # The whole walk of an install host, from the tier check to its VMs,
  # with every command it runs on the host, in order.
  describe "the bring-up walk" do
    let(:commands) { [] }

    def respond(cmd, stdin: nil, **)
      (want_cmd, want_stdin), reply = commands.shift || raise("unexpected command #{cmd.inspect}")
      raise "expected #{want_cmd.inspect} (stdin #{want_stdin.inspect}), got #{cmd.inspect} (stdin #{stdin.inspect})" unless want_cmd === cmd && want_stdin == stdin
      reply.is_a?(Exception) ? raise(reply) : reply
    end

    def queue(cmd, reply = "", stdin: nil) = commands << [[cmd, stdin], reply]

    it "installs the PVM host kernel after patch and boots it once before the host accepts VMs" do
      vm_host.update(allocation_state: "unprepared", virt_probe: Sequel.pg_jsonb(record(stock_probe)), last_boot_id: "b0")
      refresh_frame(nx, new_values: {"default_boot_images" => ["ubuntu-noble"], "vhost_block_backend_version" => "v0.4.1", "install_os" => false})
      st.update(label: "verify_virt_tier")

      queue("#{tool} preflight", JSON.generate("result" => "ok"), stdin: "{}")
      queue("common/bin/daemonizer2 check apply_patches", "NotStarted")
      queue(/dpkg-query/, "linux-image-#{stock} installed\n")
      queue(/daemonizer2 run apply_patches/)
      queue("common/bin/daemonizer2 check apply_patches", "Succeeded")
      queue("common/bin/daemonizer2 clean apply_patches")
      queue(/dpkg-query/, "linux-image-#{stock} installed\n")
      queue("common/bin/daemonizer2 check install_pvm_host_kernel", "NotStarted")
      queue(/\Acommon\/bin\/daemonizer2 run install_pvm_host_kernel sudo host\/bin\/install-pvm-host-kernel install\z/, "", stdin: JSON.generate("host_deb" => pvm_test_pins["host_deb"]))
      queue("common/bin/daemonizer2 check install_pvm_host_kernel", "Succeeded")
      queue("#{tool} status", JSON.generate(stock_status), stdin: "{}")
      queue("common/bin/daemonizer2 clean install_pvm_host_kernel")
      queue("#{tool} arm", JSON.generate("result" => "ok", "grubenv" => {}), stdin: "{}")
      queue("cat /proc/sys/kernel/random/boot_id", "b0\n")
      queue("sudo host/bin/reboot-host b0", "b1\n")
      queue("sudo host/bin/virt-probe --json", pvm_probe)
      queue("#{tool} status", JSON.generate(status), stdin: "{}")
      queue("cat /proc/meminfo", "MemTotal:       33554432 kB\nMemAvailable:   30000000 kB\nHugePages_Total:    0\nHugePages_Free:     0\nHugepagesize:    1048576 kB\n")

      labels = []
      label = "verify_virt_tier"
      until label == "configure_metrics"
        st.update(label:)
        prog = described_class.new(st.reload)
        allow(prog.sshable).to receive(:_cmd) { |cmd, **kw| respond(cmd, **kw) }
        allow(prog.vm_host).to receive(:sshable).and_return(prog.sshable)
        allow(prog.sshable).to receive(:available?).and_return(true)
        st.update(retval: Sequel.pg_jsonb({"msg" => "VhostBlockBackend was setup"})) if label == "setup_storage_backend"
        if label == "wait_download_boot_images"
          Strand.where(parent_id: st.id).update(exitval: Sequel.pg_jsonb({"msg" => "done"}))
          ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: "b" * 64, state: "ready", console: "hvc0")
        end
        result = catch(:prog_return) { prog.public_send(label) }
        st.modified!(:stack)
        st.save_changes
        labels << label
        label = result.new_label if result.is_a?(Prog::Base::Hop)
      end

      expect(labels).to eq %w[verify_virt_tier setup_storage_backend download_boot_images wait_download_boot_images patch patch
        install_pvm_host_kernel install_pvm_host_kernel prep_reboot reboot verify_pvm_boot verify_tier_capacity start_slices start_vms]
      expect(commands).to be_empty
      expect(row.reload.state).to eq "committed"
      expect(vm_host.reload.values.slice(:allocation_state, :total_hugepages_1g)).to eq(allocation_state: "accepting", total_hugepages_1g: 27)
      expect(Page.active.all.map(&:tag)).to eq []
    end
  end
end
