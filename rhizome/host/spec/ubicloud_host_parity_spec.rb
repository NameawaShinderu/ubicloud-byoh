# frozen_string_literal: true

require_relative "../lib/htcat_setup"
require_relative "../lib/virt_probe"

# scripts/byoh/host/ubicloud-host runs before registration and must test
# what bring-up will need: this keeps its constants in step with the code
# they stand for.
# rubocop:disable RSpec/DescribeClass
# The subject is a shell script, not a class.
RSpec.describe "ubicloud-host preflight constants" do
  # rubocop:enable RSpec/DescribeClass
  repo = File.expand_path("../../..", __dir__)
  script = File.read(File.join(repo, "scripts/byoh/host/ubicloud-host"))

  it "simulates every package bring-up installs" do
    sources = %w[prog/bootstrap_rhizome.rb rhizome/host/bin/prep_host.rb prog/install_dnsmasq.rb rhizome/host/bin/setup-sysstat]
    installed = sources.flat_map do |path|
      File.read(File.join(repo, path)).scan(/apt-get (?:-y install|install -y) ([a-z0-9][a-z0-9 .+-]*)/).flatten.flat_map(&:split)
    end
    expect(installed).to include("ruby-bundler", "make", "ethtool", "sysstat")

    prep_packages = script[/^PREP_PACKAGES=\(([^)]*)\)$/, 1].split
    expect(installed.uniq - prep_packages).to eq []
  end

  it "probes the release asset PrepHost downloads first" do
    expect(script[/^HTCAT_VERSION=(.*)$/, 1]).to eq HtcatSetup::VERSION
    setup = File.read(File.join(repo, "rhizome/host/lib/htcat_setup.rb"))
    expect(setup).to include(%("htcat_\#{VERSION}_linux_\#{Arch.render(x64: "amd64", arm64: "arm64")}.tar.gz"))
    expect(setup).to include(%("https://github.com/ubicloud/htcat/releases/download/v\#{VERSION}/\#{tarball}"))
    expect(script).to include('"https://github.com/ubicloud/htcat/releases/download/v${HTCAT_VERSION}/htcat_${HTCAT_VERSION}_linux_${deb_arch}.tar.gz"')
  end

  it "gathers the virtualization facts under the probe's keys and lists" do
    list = ->(name) { script[/^#{name}=\(([^)]*)\)$/, 1].split }
    expect(list.call("VIRT_FLAGS")).to eq VirtProbe::CPU_FLAGS
    expect(list.call("VIRT_MODULES")).to eq VirtProbe::MODULES
    expect(list.call("VIRT_DMI")).to eq VirtProbe::DMI_FIELDS
    expect(list.call("VIRT_COMMANDS")).to eq [*VirtProbe::CONTAINER_COMMANDS, "qemu-system-x86_64"]
    expect(list.call("VIRT_OVMF")).to eq VirtProbe::OVMF_PATHS.map { |path| "/#{path}" }
    keys = script[/^facts_virt\(\) \{.*?^\}$/m].scan(/\\?"([a-z_0-9]+)\\?":/).flatten.uniq - %w[source facts report bios_lines version]
    expect(keys).to include("dev_kvm", "cpu_flags", "dmi", "ovmf")
    expect(keys - VirtProbe.facts(root: "/nonexistent", uname: {machine: "x86_64", release: "6.8.0"}).keys).to eq []
  end
end
