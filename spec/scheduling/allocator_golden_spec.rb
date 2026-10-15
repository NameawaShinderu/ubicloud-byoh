# frozen_string_literal: true

require_relative "../model/spec_helper"
require_relative "../golden_fixture"

# Freezes what the allocator does for VMs on KVM hosts: the candidate
# hosts and their scores, the query it logs, the host it picks and what it
# books there. Host ids are random, so they are replaced by labels; the
# VM's random IPv6 network and veth address are left out.
RSpec.describe Scheduling::Allocator do
  let(:project) {
    Project.create(name: "golden").tap { it.set_ff_allocator_diagnostics(true) }
  }
  let(:vol) { [{"size_gib" => 10, "use_bdev_ubi" => false, "encrypted" => false, "boot" => true, "vring_workers" => 1}] }

  def golden_host(label, accepts_slices: true, used_cores: 1, **args)
    vmh = create_vm_host(total_mem_gib: 64, total_sockets: 1, total_dies: 1, net6: "fd10:9b0b:6b4b:8f#{label.ord.to_s(16)}::/64",
      total_cpus: 16, total_cores: 8, used_cores:, total_hugepages_1g: 54, used_hugepages_1g: 2, accepts_slices:, **args)
    BootImage.create(name: "ubuntu-noble", version: "20250502.1", vm_host_id: vmh.id, activated_at: Time.now, size_gib: 3)
    StorageDevice.create(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 120)
    create_vhost_block_backend(vm_host_id: vmh.id, version: "v0.4.2")
    Address.create(cidr: "198.51.100.#{label.ord}/32", routed_to_host_id: vmh.id).populate_ipv4_addresses
    (0..15).each { VmHostCpu.create(vm_host_id: vmh.id, cpu_number: it, io: it < 2) }
    @labels[vmh.id] = "host-#{label}"
    @labels[vmh.ubid] = "host-#{label}"
    vmh.storage_devices.each { @labels[it.id] = "stor-#{label}" }
    vmh
  end

  before do
    @labels = {}
    golden_host("a")
    golden_host("b", accepts_slices: false, used_cores: 5)
    golden_host("c", allocation_state: "draining")
    golden_host("d", arch: "arm64")
    allow(Scheduling::Allocator::Allocation).to receive(:random_score).and_return(0)
  end

  def normalize(obj)
    json = JSON.pretty_generate(obj)
    @labels.each { |id, label| json = json.gsub(id, label) }
    json + "\n"
  end

  def golden_vm(suffix, **args)
    Vm.create_with_id("2464de61-7501-8374-9ab0-416caebe31#{suffix}",
      name: "golden-#{suffix}", unix_user: "ubi", public_key: "ssh key", boot_image: "ubuntu-noble",
      location_id: Location::HETZNER_FSN1_ID, project_id: project.id, arch: "x64", created_at: Time.now, **args)
  end

  def allocate(vm, **kwargs)
    logs = []
    allow(Clog).to receive(:emit) { |msg, data| logs << [msg, data] }
    vm.create_storage_volumes(vol.map { it.transform_keys(&:to_sym) })
    request_candidates = nil
    expect(Scheduling::Allocator::Allocation).to receive(:best_allocation).and_wrap_original { |m, request|
      request_candidates = Scheduling::Allocator::Allocation.candidate_hosts(request).sort_by { @labels.fetch(it[:vm_host_id]) }.map { |c|
        al = Scheduling::Allocator::Allocation.new(c, request)
        {"candidate" => c, "valid" => al.is_valid, "score" => al.score}
      }
      m.call(request)
    }
    described_class.allocate(vm, vol, **kwargs)
    vm.reload
    host = vm.vm_host
    slice = vm.vm_host_slice
    query = logs.find { it[0] == "Allocator query for vm" }[1][:allocator_query]
    {
      "candidates" => request_candidates,
      "query_counts" => query[:counts],
      "query_sql" => query[:sql],
      "allocated" => logs.find { it[0] == "vm allocated" }[1][:allocation],
      "vm" => vm.values.slice(:vm_host_id, :family, :cores, :vcpus, :memory_gib, :cpu_percent_limit, :cpu_burst_percent_limit, :ip4_enabled),
      "vm_ip4" => vm.assigned_vm_address&.ip&.to_s,
      "slice" => slice&.values&.slice(:name, :family, :is_shared, :cores, :total_cpu_percent, :used_cpu_percent, :total_memory_gib, :used_memory_gib),
      "slice_cpus" => slice&.allowed_cpus_cgroup,
      "host" => host.values.slice(:used_cores, :used_hugepages_1g),
      "host_cpus_taken" => host.cpus.select(&:vm_host_slice_id).map(&:cpu_number).sort,
      "storage" => vm.vm_storage_volumes.map { [it.storage_device_id, it.storage_device.available_storage_gib, it.boot_image&.name, it.vhost_block_backend&.version] },
    }
  end

  it "places a standard VM with IPv4 the same way" do
    vm = golden_vm("da", family: "standard", cores: 0, vcpus: 2, cpu_percent_limit: 200, cpu_burst_percent_limit: 0, memory_gib: 8, ip4_enabled: true)
    result = normalize(allocate(vm))
    expect(result).to eq GoldenFixture.read("allocator_standard_ip4.json", result)
  end

  it "places a standard VM without IPv4 on a host that does not accept slices the same way" do
    vm = golden_vm("db", family: "standard", cores: 0, vcpus: 4, cpu_percent_limit: 400, cpu_burst_percent_limit: 0, memory_gib: 16, ip4_enabled: false)
    result = normalize(allocate(vm, host_filter: [VmHost.all.find { @labels[it.id] == "host-b" }.id]))
    expect(result).to eq GoldenFixture.read("allocator_standard_forced.json", result)
  end

  it "places a burstable VM in a shared slice the same way" do
    vm = golden_vm("dc", family: "burstable", cores: 0, vcpus: 1, cpu_percent_limit: 50, cpu_burst_percent_limit: 50, memory_gib: 2, ip4_enabled: false)
    result = normalize(allocate(vm))
    expect(result).to eq GoldenFixture.read("allocator_burstable.json", result)
  end
end
