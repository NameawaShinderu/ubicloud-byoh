# frozen_string_literal: true

RSpec.describe ByohVirtPlatforms do
  def facts(dmi, virt_vm: "kvm")
    {"dmi" => dmi, "virt_vm" => virt_vm}
  end

  {
    "aws" => {"sys_vendor" => "Amazon EC2", "product_name" => "m6i.large"},
    "gcp" => {"sys_vendor" => "Google", "product_name" => "Google Compute Engine"},
    "azure" => {"sys_vendor" => "Microsoft Corporation", "product_name" => "Virtual Machine", "chassis_asset_tag" => "7783-7084-3265-9085-8269-3286-77"},
    "hyperv" => {"sys_vendor" => "Microsoft Corporation", "product_name" => "Virtual Machine", "chassis_asset_tag" => "1234"},
    "vmware" => {"sys_vendor" => "VMware, Inc.", "product_name" => "VMware7,1"},
    "virtualbox" => {"sys_vendor" => "innotek GmbH", "product_name" => "VirtualBox"},
    "oci" => {"sys_vendor" => "QEMU", "chassis_asset_tag" => "OracleCloud.com"},
    "hetzner_cloud" => {"sys_vendor" => "Hetzner", "product_name" => "vServer"},
    "digitalocean" => {"sys_vendor" => "DigitalOcean", "product_name" => "Droplet"},
    "linode" => {"sys_vendor" => "Linode"},
    "vultr" => {"sys_vendor" => "Vultr"},
    "scaleway" => {"sys_vendor" => "Scaleway"},
    "openstack" => {"sys_vendor" => "OpenStack Foundation", "product_name" => "OpenStack Nova"},
    "qemu_kvm" => {"sys_vendor" => "QEMU", "product_name" => "Standard PC (Q35 + ICH9, 2009)"},
  }.each do |key, dmi|
    it "recognizes #{key}" do
      expect(described_class.match(facts(dmi))&.key).to eq key
    end
  end

  it "recognizes xen from systemd-detect-virt" do
    expect(described_class.match(facts({"sys_vendor" => "Xen"}, virt_vm: "xen")).key).to eq "xen"
  end

  it "matches nothing on bare metal or without DMI" do
    expect(described_class.match(facts({"sys_vendor" => "Dell Inc."}, virt_vm: "none"))).to be_nil
    expect(described_class.match({})).to be_nil
    expect(described_class.match(facts({"sys_vendor" => nil}, virt_vm: nil))).to be_nil
  end

  it "has unique keys, a known nested value and a fix in every row" do
    expect(described_class::ROWS.map(&:key).uniq.size).to eq described_class::ROWS.size
    described_class::ROWS.each do |row|
      expect(described_class::NESTED).to include(row.nested)
      expect(row.fix).not_to be_empty
      expect(row.match).not_to be_empty
    end
  end

  it "has every platform in the ladder doc's platform table" do
    doc = File.read(File.expand_path("../../docs/byoh/NO_KVM.md", __dir__))
    described_class::ROWS.each { expect(doc).to include("`#{it.key}`") }
  end
end
