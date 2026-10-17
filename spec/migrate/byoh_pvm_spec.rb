# frozen_string_literal: true

Sequel.extension :migration

# rubocop:disable RSpec/DescribeClass
# There is no class in this case.
RSpec.describe "migrate/20261017_byoh_pvm.rb" do
  # rubocop:enable RSpec/DescribeClass
  let(:migration) {
    # Sequel.migration registers each migration it defines; take ours back out.
    load File.expand_path("../../migrate/20261017_byoh_pvm.rb", __dir__)
    Sequel::Migration.descendants.pop
  }

  let(:location) { create_byoh_location }
  let(:sha) { "a" * 64 }
  let(:pins) { {"host_deb" => {"url" => "https://example.com/h.deb", "sha256" => sha}, "guest_kernel" => {"url" => "https://example.com/vmlinux", "sha256" => sha}, "guest_unchecked" => false} }

  def pvm_host
    create_vm_host(virt_tier: "pvm", family: "pvm")
  end

  def set_policy(policy)
    DB.transaction(savepoint: true) { DB[:location].where(id: location.id).update(byoh_virt: Sequel.pg_jsonb(policy)) }
  end

  def tables
    DB.tables & [:byoh_pvm_host, :byoh_pvm_guest_kernel, :byoh_vm_guest_kernel]
  end

  it "migrates down and up again while nothing uses PVM" do
    location.update(byoh_virt: Sequel.pg_jsonb({"tiers" => ["kvm"], "acks" => {}}))
    migration.apply(DB, :down)
    expect(tables).to eq []
    # The old check is back: it does not know pvm pins.
    expect(set_policy({"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}})).to eq 1
    set_policy({"tiers" => ["kvm"], "acks" => {}})
    migration.apply(DB, :up)
    expect(tables).to contain_exactly(:byoh_pvm_host, :byoh_pvm_guest_kernel, :byoh_vm_guest_kernel)
  end

  {
    "PVM hosts" => ->(host, _) { ByohPvmHost.create(vm_host_id: host.id, state: "install_pending", install: true) },
    "PVM guest kernels on hosts" => ->(host, _) { ByohPvmGuestKernel.create(vm_host_id: host.id, sha256: "b" * 64, state: "downloading") },
    "PVM VMs" => ->(host, spec) { ByohVmGuestKernel.create(vm_id: spec.create_vm(vm_host_id: host.id).id, sha256: "b" * 64, console: "hvc0") },
    "locations with PVM kernel pins" => ->(_, spec) { spec.set_policy({"tiers" => ["kvm"], "acks" => {}, "pvm_kernel" => spec.pins}) },
  }.each do |what, make|
    it "refuses to migrate down while there are #{what}" do
      make.call(pvm_host, self)
      expect { migration.apply(DB, :down) }.to raise_error(RuntimeError, /\Arefusing to migrate down: there are #{what};/)
    end
  end

  it "keeps the state of a host's PVM kernel and goes with the host" do
    host = pvm_host
    row = ByohPvmHost.create(vm_host_id: host.id, state: "committed", install: false, host_deb_sha256: sha)
    expect(row.vm_host).to eq host
    expect(row.updated_at).not_to be_nil
    [{state: "booted"}, {host_deb_sha256: "A" * 64}].each do |bad|
      expect { DB.transaction(savepoint: true) { DB[:byoh_pvm_host].where(vm_host_id: host.id).update(bad) } }.to raise_error(Sequel::CheckConstraintViolation)
    end
    ByohPvmGuestKernel.create(vm_host_id: host.id, sha256: sha, state: "ready", console: "hvc0", release: "6.12.33-pvm")
    [{state: "gone"}, {console: "tty0"}, {sha256: "c" * 63}].each do |bad|
      expect { DB.transaction(savepoint: true) { DB[:byoh_pvm_guest_kernel].insert({vm_host_id: host.id, sha256: "c" * 64, state: "ready"}.merge(bad)) } }.to raise_error(Sequel::CheckConstraintViolation)
    end
    expect { DB.transaction(savepoint: true) { DB[:byoh_pvm_guest_kernel].insert(vm_host_id: host.id, sha256: sha, state: "ready") } }.to raise_error(Sequel::UniqueConstraintViolation)
    DB[:vm_host].where(id: host.id).delete
    expect([ByohPvmHost.count, ByohPvmGuestKernel.count]).to eq [0, 0]
  end

  it "keeps the guest kernel each PVM VM boots and goes with the VM" do
    vm = create_vm
    ByohVmGuestKernel.create(vm_id: vm.id, sha256: sha, console: "ttyS0", release: "6.12.33-pvm")
    other = create_vm(name: "other").id
    [{sha256: "x" * 64}, {console: "ttyAMA0"}].each do |bad|
      expect { DB.transaction(savepoint: true) { DB[:byoh_vm_guest_kernel].insert({vm_id: other, sha256: sha, console: "hvc0"}.merge(bad)) } }.to raise_error(Sequel::CheckConstraintViolation)
    end
    DB[:vm].where(id: vm.id).delete
    expect(ByohVmGuestKernel.count).to eq 0
  end

  it "offers pvm only with https pins and their sha256" do
    pvm = {"tiers" => %w[kvm pvm], "acks" => {"pvm" => []}}
    config = {"url" => "https://example.com/config", "sha256" => sha}
    ok = [
      {"tiers" => ["kvm"], "acks" => {}},
      pvm.merge("pvm_kernel" => pins),
      pvm.merge("pvm_kernel" => pins.merge("guest_unchecked" => true, "config_checked" => false)),
      pvm.merge("pvm_kernel" => pins.except("guest_unchecked").merge("guest_config" => config)),
      {"tiers" => ["kvm"], "acks" => {}, "pvm_kernel" => pins},
    ]
    ok.each { expect(set_policy(it)).to eq 1 }
    bad = [
      pvm,
      pvm.merge("pvm_kernel" => "pinned"),
      pvm.merge("pvm_kernel" => pins.except("host_deb")),
      pvm.merge("pvm_kernel" => pins.except("guest_kernel")),
      pvm.merge("pvm_kernel" => pins.merge("host_deb" => {"url" => "http://example.com/h.deb", "sha256" => sha})),
      pvm.merge("pvm_kernel" => pins.merge("host_deb" => {"url" => "https://", "sha256" => sha})),
      pvm.merge("pvm_kernel" => pins.merge("guest_kernel" => {"url" => "https://example.com/v", "sha256" => "A" * 64})),
      pvm.merge("pvm_kernel" => pins.merge("guest_kernel" => {"url" => "https://example.com/v"})),
      pvm.merge("pvm_kernel" => pins.except("guest_unchecked")),
      pvm.merge("pvm_kernel" => pins.merge("guest_unchecked" => "yes")),
      pvm.merge("pvm_kernel" => pins.merge("guest_config" => {"url" => "ftp://example.com/c", "sha256" => sha})),
      pvm.merge("pvm_kernel" => pins.merge("guest_config" => {"url" => "https://example.com/c", "sha256" => "short"})),
      {"tiers" => ["kvm"], "acks" => {}, "pvm_kernel" => {}},
      {"tiers" => %w[kvm pvm], "acks" => {}, "pvm_kernel" => pins},
    ]
    bad.each do |policy|
      expect { set_policy(policy) }.to raise_error(Sequel::CheckConstraintViolation, /location_byoh_virt_check/)
    end
  end
end
