# frozen_string_literal: true

require "fileutils"
require "json"

# Machines for the virtualization probe, one per case of
# docs/byoh/NO_KVM.md section 2.2, as fixtures/virt_probe/<case>.json:
#
#   files   path under the root => content. .virt-probe/ holds what
#           commands and /dev/kvm said (VirtProbe.facts with --root).
#   dirs    directories to create (sys/module/<loaded module>)
#   execs   commands to install as empty executables (usr/bin/lxc-start)
#   expect  tier and cause the probe must find; platform, standard and
#           fix what the control plane must make of it
#
# The rhizome specs, the control-plane specs and
# scripts/byoh/test/nokvm/run.sh all read these files.
#
#   ruby virt_probe_fixtures.rb --list          the case names
#   ruby virt_probe_fixtures.rb CASE DIR        build CASE under DIR and
#                                               print its expectation
module VirtProbeFixtures
  DIR = File.expand_path("fixtures/virt_probe", __dir__)

  def self.all
    Dir.glob(File.join(DIR, "*.json")).sort.to_h { |path| [File.basename(path, ".json"), JSON.parse(File.read(path))] }
  end

  def self.materialize(fixture, root)
    fixture.fetch("files", {}).each do |path, content|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), content)
    end
    fixture.fetch("dirs", []).each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
    fixture.fetch("execs", []).each do |path|
      FileUtils.mkdir_p(File.dirname(File.join(root, path)))
      File.write(File.join(root, path), "#!/bin/sh\n")
      File.chmod(0o755, File.join(root, path))
    end
    root
  end
end

if $PROGRAM_NAME == __FILE__
  if ARGV == ["--list"]
    puts VirtProbeFixtures.all.keys
  else
    name, root = ARGV
    fixture = VirtProbeFixtures.all.fetch(name)
    VirtProbeFixtures.materialize(fixture, root)
    puts JSON.generate(fixture["expect"])
  end
end
