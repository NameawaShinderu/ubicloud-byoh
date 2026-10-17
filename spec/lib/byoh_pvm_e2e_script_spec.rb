# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"

# The PVM tier's real-run script, scripts/byoh/test/real/pvm-e2e.sh
# (L4-T2, the PVM plan's WP10), runs only against a throwaway host on
# AWS, so these checks guard what can drift without running it. Its flow
# is run against a fake world by scripts/byoh/test/pvm-e2e-stubs.sh.
RSpec.describe "scripts/byoh/test/real/pvm-e2e.sh" do # rubocop:disable RSpec/DescribeClass
  let(:root) { File.expand_path("../..", __dir__) }
  let(:path) { File.join(root, "scripts/byoh/test/real/pvm-e2e.sh") }
  let(:script) { File.read(path) }
  let(:go_no_go) { File.read(File.join(root, "scripts/byoh/test/real/pvm-go-no-go.sh")) }
  let(:phases) { script[/^PHASES=\(([^)]*)\)$/m, 1].split }

  it "runs its phases in the order the plan gives" do
    expect(phases).to eq %w[location neg-sha host-add patch-kernel host-check vm prod-path bench lifecycle host-reboot oob-reboot
      power-cycle tenancy guest-pin-rollout refusals stock-return delete billing teardown]
  end

  it "has a function for every phase, and lists each in its header" do
    phases.each do |phase|
      expect(script).to include("\nphase_#{phase.tr("-", "_")}() {\n")
      expect(script).to match(/^#   #{Regexp.escape(phase)} /)
    end
  end

  it "lists the same phases in the AWS run's README" do
    readme = File.read(File.join(root, "scripts/byoh/test/aws-e2e/README.md"))
    listed = readme[/Phases of `pvm-e2e\.sh`, in order:(.*?)\. The report/m, 1]
    expect(listed.scan(/`([a-z-]+)`/).flatten).to eq phases
  end

  it "measures what the go/no-go measures" do
    body = ->(text) { text[/^write_bench\(\) \{\n  cat >"\$1" <<'EOF'\n(.*?)^EOF\n/m, 1] }
    expect(body.call(script)).not_to be_nil
    expect(body.call(script)).to eq body.call(go_no_go)
  end

  it "defaults to the release and sha256s the go/no-go booted, with their label" do
    release = go_no_go[/^DEFAULT_RELEASE_URL=(\S+)$/, 1]
    expect(script[/^EXAMPLE_RELEASE=(\S+)$/, 1]).to eq release
    {"HOST_DEB" => "PVM_HOST_DEB", "GUEST_KERNEL" => "PVM_GUEST_KERNEL", "GUEST_CONFIG" => "PVM_GUEST_CONFIG"}.each do |file, var|
      expect(script[/^#{var}_URL=\$\{#{var}_URL:-\$EXAMPLE_RELEASE\/(\S+)\}$/, 1]).to eq go_no_go[/^DEFAULT_#{file}=(\S+)$/, 1]
      expect(script[/^#{var}_SHA256=\$\{#{var}_SHA256:-(\h{64})\}$/, 1]).to eq go_no_go[/^DEFAULT_#{file}_SHA256=(\h{64})$/, 1]
    end
    expect(script).to include "third party; Januscape fix inclusion UNVERIFIED; for testing only, not a recommended production pin"
  end

  it "waits only for page types that m2-checks pvm-host names" do
    types = script.scan(/host_(?:no_)?page "\$host" (\w+)/).flatten.uniq
    expect(types).to include("ByohPvmInstall", "ByohPvmBoot", "ByohPvmUninstalled", "ByohPvmGuestKernelStale", "LastBootIDDiscrepancy")
    expect(types - ByohGateChecks::PVM_PAGE_TYPES).to eq []
  end

  it "reads only keys that m2-checks prints" do
    gate = File.read(File.join(root, "lib/byoh_gate_checks.rb"))
    keys = script.scan(/\bkv (\w+)/).flatten.uniq - %w[KEY]
    expect(keys).to include("label", "pvm_state", "guest_sha256", "inhost", "private_ip4", "exists")
    keys.each { expect(gate).to match(/^ +#{it}: |"#{it}=/) }
  end

  it "names the m2-checks commands it runs" do
    commands = script.scan(/\bchecks ([a-z-]+) --/).flatten.uniq
    expect(commands).to contain_exactly("pvm-host", "pvm-vm", "info")
    expect(commands - ByohGateChecks::COMMANDS).to eq []
  end

  # These run the script, which needs bash. The alpine test image has
  # none unless the run adds it, so they skip there instead of failing.
  context "when run by bash" do
    let(:bash) { ENV.fetch("PATH", "").split(":").map { File.join(it, "bash") }.find { File.executable?(it) } }

    before { skip "bash is not installed" unless bash }

    def run(env, *args)
      Open3.capture2e({"BYOH_REAL_E2E" => nil, "PVM_E2E_HOST_SSH" => nil, "PVM_E2E_YES" => nil}.merge(env), bash, path, *args, chdir: root)
    end

    it "refuses to do anything without BYOH_REAL_E2E=1" do
      out, status = run({}, "all")
      expect(status.exitstatus).to eq 2
      expect(out).to include("refusing: this installs a custom kernel")
    end

    it "refuses unknown phases and missing settings" do
      out, status = run({"BYOH_REAL_E2E" => "1"}, "frob")
      expect([status.exitstatus, out]).to match [2, /unknown phase frob/]
      out, status = run({"BYOH_REAL_E2E" => "1"}, "location")
      expect([status.exitstatus, out]).to match [2, /PVM_E2E_HOST_SSH is not set/]
    end

    it "prints its header as help" do
      out, status = run({}, "--help")
      expect(status.exitstatus).to eq 0
      expect(out).to start_with("L4-T2: the PVM tier end to end")
      expect(out).to include("UNVERIFIED: this script has never run against a real host")
    end
  end
end
