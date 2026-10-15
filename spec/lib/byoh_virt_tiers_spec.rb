# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../../rhizome/host/lib/virt_probe"

RSpec.describe ByohVirtTiers do
  let(:location) { create_byoh_location(ula48: "fd00:1:2::/48") }
  let(:project) { Project.create(name: "tier-project") }

  def offer(location, policy)
    location.update(byoh_virt: Sequel.pg_jsonb(policy))
  end

  def verdict(**over)
    facts = {
      "arch" => "x86_64", "kernel" => "6.8.0-1-generic", "cpu_vendor" => "GenuineIntel", "cpu_model" => "Intel Xeon",
      "cpu_flags" => %w[hypervisor pdpe1gb], "dev_kvm" => false, "modules" => [], "virt_vm" => "kvm", "virt_container" => "none",
      "bios_log" => nil, "dmi" => {"sys_vendor" => "QEMU"}, "cgroup2" => true, "apparmor" => true,
      "commands" => {**VirtProbe::CONTAINER_COMMANDS.to_h { [it, true] }, "qemu-system-x86_64" => false}, "ovmf" => false,
    }.merge(over.transform_keys(&:to_s))
    ByohVirtLadder.from_facts(facts)
  end

  def check(tier = "container", **over)
    args = {location:, project:, allowed_tiers: ["kvm", tier], gpu_count: 0, boot_image: described_class.fetch(tier).boot_images.first,
            storage_volumes: [{track_written: false}], hypervisor: nil, ch_version: nil, remote_storage_server_id: nil}
    described_class.check_vm!(tier, **args.merge(over))
  end

  def refusal
    yield
    fail "expected a refusal"
  rescue Validation::ValidationFailed => e
    e.details[:size]
  end

  it "names each tier, its family and label" do
    expect(described_class::IDS).to eq %w[kvm container pvm emulated]
    expect(described_class.fetch("container").family).to eq "container"
    expect(described_class.fetch("emulated").label).to eq "emulated (L5, experimental)"
    expect { described_class.fetch("tcg") }.to raise_error(described_class::Refused, "unknown tier \"tcg\"; expected one of kvm, container, pvm, emulated")
  end

  it "maps every family outside the tier table to kvm" do
    expect(described_class.tier_for_family("container")).to eq "container"
    (Option::VmSizes.map(&:family).uniq + ["unknown"]).each { expect(described_class.tier_for_family(it)).to eq "kvm" }
    expect(described_class.family_for("kvm")).to eq "standard"
    expect(described_class.family_for("pvm")).to eq "pvm"
  end

  it "ships the container tier, and pvm and emulated not yet" do
    expect(described_class.shipped?("kvm")).to be true
    expect(described_class.shipped?("container")).to be true
    %w[pvm emulated].each { expect(described_class.shipped?(it)).to be false }
  end

  describe ".policy" do
    it "is kvm only for non-BYOH locations and BYOH locations without a policy" do
      expect(described_class.policy(Location[Location::HETZNER_FSN1_ID])).to eq described_class::DEFAULT_POLICY
      expect(described_class.policy(location)).to eq described_class::DEFAULT_POLICY
      expect(described_class.allows?(location, "kvm")).to be true
      expect(described_class.allows?(location, "container")).to be false
      expect(described_class.acked?(location, "container")).to be false
    end

    it "reads the location's tiers and acknowledgements" do
      offer(location, {"tiers" => %w[kvm container], "acks" => {"container" => ["multitenant"]}})
      expect(described_class.tiers(location)).to eq %w[kvm container]
      expect(described_class.acked?(location, "container")).to be true
      expect(described_class.acked?(location, "container", "multitenant")).to be true
      expect(described_class.acked?(location, "container", "guest-firewall")).to be false
    end

    it "offers only shipped tiers of BYOH locations to customers" do
      offer(location, {"tiers" => %w[kvm container emulated], "acks" => {"container" => [], "emulated" => []}})
      ship_virt_tiers
      expect(described_class.offered_families(location)).to eq []
      ship_virt_tiers("emulated")
      expect(described_class.offered_families(location)).to eq %w[emulated]
      expect(described_class.size_families(location, %w[kvm])).to eq []
      expect(described_class.size_families(location, %w[kvm container emulated])).to eq %w[emulated]
      expect(described_class.size_families(location, %w[kvm container])).to eq []
    end
  end

  describe ".accepts_probe?" do
    it "wants today's VMs on a kvm host" do
      expect(described_class.accepts_probe?("kvm", verdict(cpu_flags: %w[vmx pdpe1gb], dev_kvm: true, kvm_api: 12, modules: %w[kvm kvm_intel], virt_vm: "none", dmi: {}))).to be true
      expect(described_class.accepts_probe?("kvm", verdict)).to be false
    end

    it "wants the tier's prerequisites in place on a lower-tier host" do
      expect(described_class.accepts_probe?("container", verdict)).to be true
      expect(described_class.accepts_probe?("emulated", verdict)).to be false
      expect(described_class.accepts_probe?("emulated", verdict(commands: {"qemu-system-x86_64" => true}, ovmf: true))).to be true
    end

    it "refuses a PVM host on a Meltdown-affected CPU or with Secure Boot on" do
      pvm = {cpu_flags: %w[hypervisor], dev_kvm: true, kvm_api: 12, kvm_create_vm: true, kvm_caps_missing: [], modules: %w[kvm kvm_pvm]}
      expect(described_class.accepts_probe?("pvm", verdict(**pvm, vulnerabilities: {"meltdown" => "Not affected"}))).to be true
      expect(described_class.accepts_probe?("pvm", verdict(**pvm, vulnerabilities: {"meltdown" => "Mitigation: PTI"}))).to be false
      expect(described_class.accepts_probe?("pvm", verdict(**pvm))).to be false
      expect(described_class.accepts_probe?("pvm", verdict(**pvm, vulnerabilities: {"meltdown" => "Not affected"}, secure_boot: true))).to be false
    end
  end

  describe ".check_vm!" do
    before do
      ship_virt_tiers("container", "emulated")
      offer(location, {"tiers" => %w[kvm container emulated], "acks" => {"container" => [], "emulated" => []}})
      project.set_ff_visible_locations([location.name])
      allow(BillingRate).to receive(:from_resource_properties).and_return({"id" => "rate"})
    end

    it "passes a VM that follows every rule" do
      expect(check).to be_nil
      expect(check("emulated", storage_volumes: [{track_written: true}])).to be_nil
    end

    it "refuses each broken rule" do
      expect(refusal { check(allowed_tiers: ["kvm"]) }).to eq "container VMs are not available to this caller"
      expect(refusal { check("pvm") }).to eq "pvm VMs are not available yet"
      expect(refusal { check(location: Location[Location::HETZNER_FSN1_ID]) }).to eq "container VMs are only available in BYOH locations"
      expect(refusal { check(project: Project.create(name: "other")) }).to eq "location byoh-test is not available to this project"
      expect(refusal { check(gpu_count: 1) }).to eq "container VMs cannot have GPUs"
      expect(refusal { check(hypervisor: "qemu") }).to eq "container VMs choose their hypervisor from the host"
      expect(refusal { check(ch_version: "46.0") }).to eq "container VMs choose their hypervisor from the host"
      expect(refusal { check(boot_image: "ubuntu-noble") }).to eq "container VMs can only boot ubuntu-noble-container"
      expect(refusal { check(remote_storage_server_id: "x") }).to eq "container VMs cannot use machine images or remote storage"
      expect(refusal { check(storage_volumes: [{machine_image_version_id: "x"}]) }).to eq "container VMs cannot use machine images or remote storage"
      expect(refusal { check(storage_volumes: [{remote_storage_server_id: "x"}]) }).to eq "container VMs cannot use machine images or remote storage"
      expect(refusal { check(storage_volumes: [{track_written: true}]) }).to eq "container VMs cannot track written blocks"
      offer(location, {"tiers" => %w[kvm emulated], "acks" => {"emulated" => []}})
      expect(refusal { check }).to eq "location byoh-test does not offer container VMs"
    end

    it "refuses a tier without its billing rates" do
      expect(BillingRate).to receive(:from_resource_properties).with("VmVCpu", "container", "byoh-test").and_return({"id" => "rate"})
      expect(BillingRate).to receive(:from_resource_properties).with("VmStorage", "container", "byoh-test").and_return(nil)
      expect { check }.to raise_error(Validation::ValidationFailed) { expect(it.details[:location]).to eq "Resource family container is not available in location byoh-test" }
    end
  end

  describe ".check_tenancy!" do
    let(:other) { Project.create(name: "other") }

    before { offer(location, {"tiers" => %w[kvm container], "acks" => {"container" => []}}) }

    it "allows the first project and refuses a second one in the location" do
      expect(described_class.check_tenancy!("container", location, project.id)).to be_nil
      create_vm(project_id: project.id, location_id: location.id, family: "container")
      create_vm(project_id: other.id, location_id: location.id, family: "standard", name: "kvm-vm")
      expect(described_class.check_tenancy!("container", location, project.id)).to be_nil
      expect(refusal { described_class.check_tenancy!("container", location, other.id) })
        .to eq "location byoh-test already runs lower-tier VMs of another project, and its container tier is single-project"
    end

    it "allows several projects once multitenant is acknowledged and its host checks exist" do
      offer(location, {"tiers" => %w[kvm container], "acks" => {"container" => ["multitenant"]}})
      create_vm(project_id: project.id, location_id: location.id, family: "container")
      expect(refusal { described_class.check_tenancy!("container", location, other.id) }).to include "single-project"
      check_virt_multitenant("container")
      expect(described_class.check_tenancy!("container", location, other.id)).to be_nil
    end

    it "keeps every tier single-project while no tier's host checks exist" do
      expect(described_class::MULTITENANT_CHECKED).to eq []
      expect(described_class::TIERS.values.select { it.options.include?("multitenant") }.map(&:id)).to eq %w[container pvm]
      expect(described_class.shared?({"acks" => {"pvm" => ["multitenant"]}}, "pvm")).to be false
    end

    it "locks the location row until the create transaction ends" do
      # A committed row, so a second connection can try to lock it.
      fsn1 = Location[Location::HETZNER_FSN1_ID]
      try_lock = lambda do
        Thread.new {
          Thread.current.report_on_exception = false
          DB.transaction { DB[:location].where(id: fsn1.id).for_update.nowait.get(:id) }
        }.value
      end
      expect(try_lock.call).to eq fsn1.id
      described_class.check_tenancy!("container", fsn1, project.id)
      expect { try_lock.call }.to raise_error(Sequel::DatabaseError, /could not obtain lock/)
    end
  end

  it "lets the data-plane bootstrap prepare only the shipped tiers" do
    script = File.read(File.expand_path("../../scripts/byoh/bootstrap-data-plane.sh", __dir__))
    expect(script[/^SHIPPED_TIERS="([^"]*)"$/, 1].split).to eq described_class::SHIPPED
  end

  describe ".memory_budget_gib" do
    it "keeps the host reserve and the per-VM overhead out of the budget" do
      # (32768 - 0) * 42 / 43 = 32006; - 2048 - 512 * (8 / 2) = 27910 MiB
      expect(described_class.memory_budget_gib("emulated", mem_total_mib: 32768, hugepages_mib: 0, total_cpus: 8)).to eq 27
      expect(described_class.memory_budget_gib("container", mem_total_mib: 32768, hugepages_mib: 4096, total_cpus: 8)).to eq 24
    end

    it "is never negative" do
      expect(described_class.memory_budget_gib("emulated", mem_total_mib: 2048, hugepages_mib: 0, total_cpus: 64)).to eq 0
    end
  end
end
