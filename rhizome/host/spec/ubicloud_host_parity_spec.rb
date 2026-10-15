# frozen_string_literal: true

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
end
