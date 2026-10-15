# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnStorage do
  describe "#start" do
    it "exits, saving StorageDevice model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /                            205520896     99571712
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /var/storage/devices/stor1   205520896     99571712
/dev/sdb       /var/storage/devices/stor2  3331416064   3331276800
EOS
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sda\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sdb\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id2")
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sdc\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id3")

      expect { ls.start }.to exit({"msg" => "created StorageDevice records"}).and change {
        StorageDevice.all.map { |d| [d.name, d.unix_device_list.sort] }.sort
      }.from([]).to([
        ["DEFAULT", ["wwn-some-random-id1"]],
        ["stor1", ["wwn-some-random-id2"]],
        ["stor2", ["wwn-some-random-id3"]],
      ])
    end

    it "refuses to run when VM storage volumes use the host's storage devices" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      # format_storage proves the refusal comes before the disks are formatted.
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id, "format_storage" => true}]))
      sd = StorageDevice.create(vm_host_id: vmh.id, name: "DEFAULT", available_storage_gib: 80, total_storage_gib: 100)
      vm = create_vm(vm_host_id: vmh.id)
      VmStorageVolume.create(vm_id: vm.id, disk_index: 0, size_gib: 20, boot: true, use_bdev_ubi: false, storage_device_id: sd.id)

      expect(ls.sshable).not_to receive(:_cmd)
      expect { ls.start }.to raise_error RuntimeError, "Refusing to relearn storage of #{vmh.ubid}: VM storage volumes already use its storage devices, and relearning would reset their available_storage_gib"
      expect(sd.reload.available_storage_gib).to eq 80
    end

    it "ignores VM storage volumes on other hosts' storage devices" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      other_sd = StorageDevice.create(vm_host_id: create_vm_host.id, name: "DEFAULT", available_storage_gib: 80, total_storage_gib: 100)
      VmStorageVolume.create(vm_id: create_vm.id, disk_index: 0, size_gib: 20, boot: true, use_bdev_ubi: false, storage_device_id: other_sd.id)
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls).to receive(:make_model_instances).and_return([])

      expect { ls.start }.to exit({"msg" => "created StorageDevice records"})
    end

    it "exits, updating existing StorageDevice model instances" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}]))
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/nvme0n1   /                           6205520896     99571712
/dev/nvme0n2   /var/storage/devices/stor1  6205520896   3099571712
/dev/nvme0n3   /var/storage/devices/stor2  3331416064   1531276800
EOS
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/nvme0n2   /var/storage/devices/stor1  6205520896   3099571712
/dev/nvme0n3   /var/storage/devices/stor2  3331416064   1531276800
EOS

      allow(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme0n2\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.some-random-id1")
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme0n3\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.some-random-id2")

      StorageDevice.create(vm_host_id: vmh.id, name: "stor1", available_storage_gib: 100, total_storage_gib: 100, unix_device_list: ["nvme0n1"])
      expect { ls.start }.to exit({"msg" => "created StorageDevice records"}).and change {
        StorageDevice.map { |sd|
          sd.values.slice(
            :name, :available_storage_gib, :total_storage_gib,
          )
        }.sort_by { it[:name] }
      }.from(
        [{name: "stor1", total_storage_gib: 100, available_storage_gib: 100}],
      ).to(
        [
          {name: "DEFAULT", total_storage_gib: 5, available_storage_gib: 0},
          {name: "stor1", total_storage_gib: 5, available_storage_gib: 2},
          {name: "stor2", total_storage_gib: 3, available_storage_gib: 1},
        ],
      )

      expect(vmh.reload.available_storage_gib).to eq(3)
      expect(vmh.reload.total_storage_gib).to eq(13)
    end

    it "formats the storage disks before reading them when format_storage is set" do
      vmh = Prog::Vm::HostNexus.assemble("::1").subject
      ls = described_class.new(Strand.new(stack: [{"subject_id" => vmh.id, "format_storage" => true}]))
      expect(ls.sshable).to receive(:_cmd).with("sudo host/bin/format-storage-disks").ordered
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").ordered.and_return(<<~EOS)
        Filesystem     Mounted on                   1B-blocks        Avail
        /dev/sda       /                            205520896     99571712
      EOS
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<~EOS)
        Filesystem     Mounted on   1B-blocks        Avail
        /dev/sda       /            205520896     99571712
      EOS
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sda\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")

      expect { ls.start }.to exit({"msg" => "created StorageDevice records"})
    end
  end

  describe Prog::LearnStorage, "#make_model_instances" do
    subject(:ls) { described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}])) }

    let(:vmh) { Prog::Vm::HostNexus.assemble("::1").subject }

    it "can parse multiple file systems in /var/storage/NAME" do
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS

      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sdb       /var/storage/devices/stor1   205520896     99571712
/dev/sdc       /var/storage/devices/stor2  3331416064   3331276800
EOS
      allow(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sdb\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sdc\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id2")

      expect(ls.make_model_instances.map(&:name)).to eq(%w[DEFAULT stor1 stor2].freeze)
    end

    it "can use any file system that is present at '/var/storage'" do
      # First, the sshable is scanned for any file systems in
      # /var/storage/devices. Iff there are none, a second command is
      # sent to fill in the "DEFAULT" storage device.
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
EOS

      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/sda       /                         452564664320 381456842752
EOS
      allow(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep sda\\$ | grep 'wwn-' | sed -E 's/.*(wwn[^ ]*).*/\\1/'").and_return("wwn-some-random-id1")

      expect(ls.make_model_instances.map(&:name)).to eq(%w[DEFAULT].freeze)
    end

    it "can find underlying unix devices for raided disks" do
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
tmpfs          /run                        3331420160   3328692224
/dev/sda       /                         452564664320 381456842752
tmpfs          /dev/shm                   16657084416  16605118464
tmpfs          /run/lock                      5242880      5234688
tmpfs          /sys/firmware/efi/efivars       448412        74256
/dev/aaa       /boot                       2024529920   1641877504
EOS

      expect(ls.sshable).to receive(:_cmd).with("cat /proc/mdstat").and_return(<<EOS)
Personalities : [raid1] [linear] [multipath] [raid0] [raid6] [raid5] [raid4] [raid10]
md2 : active raid1 nvme1n1p3[1] nvme0n1p3[0]
      465370432 blocks super 1.2 [2/2] [UU]
      bitmap: 3/4 pages [12KB], 65536KB chunk

md0 : active raid1 nvme1n1p1[1] nvme0n1p1[0]
      33520640 blocks super 1.2 [2/2] [UU]

md1 : active raid1 nvme1n1p2[1] nvme0n1p2[0]
      1046528 blocks super 1.2 [2/2] [UU]

unused devices: <none>
EOS

      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<EOS)
Filesystem     Mounted on                   1B-blocks        Avail
/dev/md2       /                         452564664320 381456842752
EOS

      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme1n1\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id1")
      expect(ls.sshable).to receive(:_cmd).with("ls -l /dev/disk/by-id/ | grep nvme0n1\\$ | grep 'nvme-eui' | sed -E 's/.*(nvme-eui[^ ]*).*/\\1/'").and_return("nvme-eui.random-id2")
      expect(ls.make_model_instances.map(&:unix_device_list)).to eq([["nvme-eui.random-id1", "nvme-eui.random-id2"]])
    end
  end

  describe "on a BYOH host" do
    subject(:ls) { described_class.new(Strand.new(stack: [{"subject_id" => vmh.id}])) }

    let(:location) { Location.create(name: "byoh-ls", display_name: "byoh-ls", ui_name: "byoh-ls", visible: false, provider: HostProvider::GENERIC_PROVIDER_NAME, byoh_network: {}) }
    let(:vmh) {
      Prog::Vm::HostNexus.assemble("203.0.113.42", location_id: location.id, provider_name: HostProvider::GENERIC_PROVIDER_NAME,
        provider_config: {"main_ip4" => "203.0.113.42", "location_label" => location.name, "routed_networks" => [{"cidr" => "fd00:feed::/64"}]}).subject
    }

    def fixture(kind, name)
      File.read(File.expand_path("../fixtures/byoh/#{kind}/#{name}.txt", __dir__)).lines.reject { it.start_with?("# fixture:") }.join
    end

    # An EBS root carrying /var/storage, and a whole virtio disk without
    # by-id links mounted as an extra storage device. df names the root by
    # its partition, which upstream would resolve to "".
    def expect_byoh_disks
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail").and_return(<<~EOS)
        Filesystem     Mounted on                   1B-blocks        Avail
        /dev/root      /                         452564664320 381456842752
        /dev/vdb       /var/storage/devices/extra   205520896     99571712
      EOS
      expect(ls.sshable).to receive(:_cmd).with("df -B1 --output=source,target,size,avail /var/storage").and_return(<<~EOS)
        Filesystem     Mounted on                   1B-blocks        Avail
        /dev/root      /                         452564664320 381456842752
      EOS
      expect(ls.sshable).to receive(:_cmd).with(ByohDeviceIdentity::BYID_LISTING).and_return(fixture("byid", "ebs"))
      expect(ls.sshable).to receive(:_cmd).with("findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target /var/storage").and_return(fixture("findmnt", "ebs-root"))
      expect(ls.sshable).to receive(:_cmd).with("lsblk -nP -s -o NAME,TYPE /dev/block/259:1").and_return(fixture("lsblk", "ebs-root"))
      expect(ls.sshable).to receive(:_cmd).with("findmnt -nP -o SOURCE,MAJ:MIN,FSTYPE --target /var/storage/devices/extra").and_return(fixture("findmnt", "vdb-whole"))
      expect(ls.sshable).to receive(:_cmd).with("lsblk -nP -s -o NAME,TYPE /dev/block/253:16").and_return(fixture("lsblk", "vdb-whole"))
    end

    it "names the disks with ByohDeviceIdentity" do
      expect_byoh_disks
      expect(ls.make_model_instances.map { [it.name, it.unix_device_list] }).to eq([
        ["DEFAULT", ["nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f60718"]],
        ["extra", ["vdb"]],
      ])
    end

    it "replaces stale ids when it relearns a host without volumes" do
      StorageDevice.create(vm_host_id: vmh.id, name: "DEFAULT", available_storage_gib: 1, total_storage_gib: 1, unix_device_list: [""])
      expect_byoh_disks
      expect { ls.start }.to exit({"msg" => "created StorageDevice records"})
      expect(vmh.storage_devices_dataset.order(:name).select_map(:unix_device_list).map(&:to_a)).to eq([["nvme-Amazon_Elastic_Block_Store_vol0a1b2c3d4e5f60718"], ["vdb"]])
    end
  end
end
