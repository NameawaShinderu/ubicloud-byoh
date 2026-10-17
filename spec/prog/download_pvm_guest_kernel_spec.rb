# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::DownloadPvmGuestKernel do
  subject(:dl) { described_class.new(st) }

  let(:location) { create_byoh_location }
  let(:vm_host) { create_byoh_vm_host(location, virt_tier: "pvm", family: "pvm") }
  let(:sha) { "b" * 64 }
  let(:pin) { {"guest_kernel" => {"url" => "https://example.com/pvm/vmlinux", "sha256" => sha}, "guest_unchecked" => false} }
  let(:st) { Strand.create(prog: "DownloadPvmGuestKernel", label: "start", stack: [{"subject_id" => vm_host.id, "pin" => pin}]) }
  let(:sshable) { dl.sshable }
  let(:unit) { "download_pvm_guest_#{sha}" }
  let(:meta) { {"sha256" => sha, "release" => "6.12.33-pvm", "console" => "hvc0", "config_checked" => true} }

  before do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}, "pvm_kernel" => pvm_test_pins}))
  end

  def row = ByohPvmGuestKernel[vm_host_id: vm_host.id, sha256: sha]

  def expect_show(state)
    expect(sshable).to receive(:_cmd).with("sudo host/bin/download-pvm-guest-kernel show", stdin: JSON.generate("sha256" => sha)).and_return(JSON.generate(state))
  end

  def page = Page.from_tag_parts("ByohPvmGuestKernel", vm_host.ubid)

  describe ".location_pin" do
    it "gives the guest side of the location's pin" do
      expect(described_class.location_pin(vm_host)).to eq("guest_kernel" => pvm_test_pins["guest_kernel"], "guest_unchecked" => false)
      location.update(byoh_virt: nil)
      expect(described_class.location_pin(vm_host.reload)).to be_nil
    end
  end

  describe "#start" do
    it "records the download and hops to it" do
      expect { dl.start }.to hop("download")
      expect(row.values.slice(:state, :console, :config_checked)).to eq(state: "downloading", console: nil, config_checked: false)
    end

    it "downloads a refused pin again, and leaves a ready one ready" do
      ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: sha, state: "refused")
      expect { dl.start }.to hop("download")
      expect(row.state).to eq "downloading"
      row.update(state: "ready", console: "hvc0")
      expect { dl.start }.to hop("download")
      expect(row.state).to eq "ready"
    end
  end

  describe "#download" do
    before { ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: sha, state: "downloading") }

    it "starts the daemonized download with the pin" do
      expect(sshable).to receive(:d_check).with(unit).and_return("NotStarted")
      expect(sshable).to receive(:d_run).with(unit, "sudo", "host/bin/download-pvm-guest-kernel", "download", stdin: JSON.generate(pin))
      expect { dl.download }.to nap(15)
    end

    it "waits while it runs" do
      expect(sshable).to receive(:d_check).with(unit).and_return("InProgress")
      expect { dl.download }.to nap(15)
    end

    it "records the kernel once the download succeeded" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Succeeded")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { dl.download }.to hop("record")
    end

    it "refuses a pin the host refused, with a page" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed")
      expect_show("result" => "ok", "state" => "refused", "error" => "the guest kernel config lacks (=y): VFAT_FS")
      expect(sshable).to receive(:d_clean).with(unit)
      expect { dl.download }.to exit({"msg" => "refused"})
      expect(row.state).to eq "refused"
      expect(page.summary).to eq "#{vm_host.ubid} refused the PVM guest kernel #{sha}: the guest kernel config lacks (=y): VFAT_FS"
      expect(page.details.to_h).to include("sha256" => sha, "url" => "https://example.com/pvm/vmlinux", "error" => "the guest kernel config lacks (=y): VFAT_FS",
        "fix" => start_with("Pin a guest kernel that downloads and has what PVM VMs need: bin/byoh-location set --location byoh-test --pvm-guest-kernel URL"))
    end

    it "tries a failed download again, and refuses it after MAX_RESTARTS more failures" do
      expect(sshable).to receive(:d_check).with(unit).and_return("Failed").twice
      expect_show("result" => "ok", "state" => "absent").twice
      expect(sshable).to receive(:d_clean).with(unit).twice
      expect { dl.download }.to nap(15)
      expect(dl.restarted).to eq 1

      refresh_frame(dl, new_values: {"restarted" => described_class::MAX_RESTARTS})
      expect(sshable).to receive(:d_logs).with(unit, lines: 5).and_return("curl: (6) Could not resolve host\n")
      expect { dl.download }.to exit({"msg" => "refused"})
      expect(row.state).to eq "refused"
      expect(page.details["error"]).to eq "the download failed 11 times; the last log lines: curl: (6) Could not resolve host"
    end
  end

  describe "#record" do
    before { ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: sha, state: "downloading") }

    def expect_gc(keep, result)
      expect(sshable).to receive(:_cmd).with("sudo host/bin/download-pvm-guest-kernel gc", stdin: JSON.generate("keep" => keep)).and_return(JSON.generate(result))
    end

    it "marks the kernel ready, resolves the host's page and drops the kernels nothing uses" do
      refused_page = Prog::PageNexus.assemble("refused", ["ByohPvmGuestKernel", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id).subject
      old = ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: "1" * 64, state: "ready", console: "hvc0")
      ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: "2" * 64, state: "downloading")
      vm = create_vm(vm_host_id: vm_host.id)
      ByohVmGuestKernel.create(vm_id: vm.id, sha256: "3" * 64, console: "hvc0")
      other_vm = create_vm
      ByohVmGuestKernel.create(vm_id: other_vm.id, sha256: "4" * 64, console: "hvc0")
      expect_show("result" => "ok", "state" => "ready", "meta" => meta)
      expect_gc(["2" * 64, "3" * 64, "b" * 64], "result" => "ok", "removed" => ["1" * 64], "kept" => [])
      expect { dl.record }.to exit({"msg" => "ready"})
      expect(row.values.slice(:state, :release, :console, :config_checked)).to eq(state: "ready", release: "6.12.33-pvm", console: "hvc0", config_checked: true)
      expect(old.exists?).to be false
      expect(refused_page.reload.resolve_set?).to be true
    end

    it "keeps the page open when the kernel is not the location's current pin" do
      Prog::PageNexus.assemble("refused", ["ByohPvmGuestKernel", vm_host.ubid], vm_host.ubid, resource_id: vm_host.id)
      refresh_frame(dl, new_values: {"pin" => pin.merge("guest_kernel" => {"url" => "https://example.com/old", "sha256" => "c" * 64})})
      ByohPvmGuestKernel.create(vm_host_id: vm_host.id, sha256: "c" * 64, state: "downloading")
      expect(sshable).to receive(:_cmd).with("sudo host/bin/download-pvm-guest-kernel show", stdin: JSON.generate("sha256" => "c" * 64)).and_return(JSON.generate("state" => "ready", "meta" => meta))
      expect_gc(["b" * 64, "c" * 64], "result" => "ok", "removed" => [], "skipped" => "a download holds opt/pvm-guest/.lock")
      expect(Clog).to receive(:emit).with("PVM guest kernel gc skipped", {pvm_guest_kernel_gc_skipped: {vm_host_ubid: vm_host.ubid, reason: "a download holds opt/pvm-guest/.lock"}})
      expect { dl.record }.to exit({"msg" => "ready"})
      expect(page.resolve_set?).to be false
      expect(row.state).to eq "downloading"
    end

    it "keeps only this kernel when its location no longer pins one" do
      location.update(byoh_virt: nil)
      expect_show("result" => "ok", "state" => "ready", "meta" => meta)
      expect_gc(["b" * 64], "result" => "ok", "removed" => [], "kept" => ["b" * 64])
      expect { dl.record }.to exit({"msg" => "ready"})
      expect(row.state).to eq "ready"
    end

    it "has no page to resolve for a pin that was never refused" do
      expect_show("result" => "ok", "state" => "ready", "meta" => meta)
      expect_gc(["b" * 64], "result" => "ok", "removed" => [], "kept" => ["b" * 64])
      expect { dl.record }.to exit({"msg" => "ready"})
      expect(page).to be_nil
    end

    it "fails when the host does not hold the kernel it said it downloaded" do
      expect_show("result" => "ok", "state" => "absent")
      expect { dl.record }.to raise_error(RuntimeError, "the PVM guest kernel #{sha} is absent on the host after its download succeeded")
    end
  end
end
