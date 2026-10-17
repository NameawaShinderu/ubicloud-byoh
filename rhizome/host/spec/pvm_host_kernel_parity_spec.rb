# frozen_string_literal: true

require_relative "../lib/pvm_host_kernel"

# PvmHostKernel installs the PVM host kernel the way
# scripts/byoh/test/real/pvm-go-no-go.sh did when it booted PVM guests on
# AWS (docs/byoh/NO_KVM.md section 14). These keep the parts that made
# that run work the same in both: the driver checks, the pti=off menu
# entry and the GRUB checks before arming. The deliberate differences are
# the entry's title and file name, and that GRUB's default never becomes
# the PVM kernel (ubicloud-pvm-boot.service re-arms each boot instead).
RSpec.describe PvmHostKernel do
  let(:script) { File.read(File.expand_path("../../../scripts/byoh/test/real/pvm-go-no-go.sh", __dir__)) }

  it "maps sysfs driver names to modules as the go/no-go does" do
    aliases = script[/^  case "\$drv" in\n(.*?)^  esac/m, 1].scan(/^\s+([\w |]+)\) drv=(\w+) ;;$/).flat_map do |names, mod|
      names.split("|").map { |name| [name.strip, mod] }
    end
    expect(aliases.to_h).to eq described_class::DRIVER_MODULES
  end

  it "allows the same drivers without a module name" do
    expect(script[/case " (\w+) \$\{PVM_UNCHECKED_DRIVERS/, 1].split).to eq described_class::UNCHECKED_DRIVERS
  end

  it "writes the go/no-go's menu entry, but for its title" do
    heredoc = script[/cat >"\$GRUB_SCRIPT" <<EOF\n(.*?)^EOF$/m, 1]
    theirs = heredoc.gsub("\\$", "$").gsub("$kver", "KVER").gsub("$PVM_ENTRY_ID", "ubicloud-pvm").sub("(PVM go/no-go)", "(Ubicloud PVM)")
    ours = described_class.grub_script("KVER").lines.grep_v(/^# /).join
    expect(ours).to eq theirs
  end

  it "uses the go/no-go's entry id and stock submenu" do
    expect(script).to include("PVM_ENTRY_ID=#{described_class::ENTRY_ID}\n")
    expect(script).to include("grep -q \"^submenu '#{described_class::STOCK_SUBMENU}'\" /boot/grub/grub.cfg")
  end

  it "checks grub.cfg for the same lines before arming" do
    expect(script).to include(%(grep -qF 'set default="${saved_entry}"' /boot/grub/grub.cfg))
    expect(script).to include("grep -q 'save_env next_entry' /boot/grub/grub.cfg")
    source = File.read(File.expand_path("../lib/pvm_host_kernel.rb", __dir__))
    expect(source).to include(%(cfg.include?('set default="${saved_entry}"')), %(cfg.include?("save_env next_entry")))
  end

  it "pins with GRUB_DEFAULT=saved, refuses GRUB_SAVEDEFAULT=true and holds both kernels" do
    expect(script).to include("echo 'GRUB_DEFAULT=saved' >\"$GRUB_DROPIN\"")
    expect(described_class::GRUB_DROPIN_TEXT.lines.grep_v(/^#/)).to eq ["GRUB_DEFAULT=saved\n"]
    expect(script).to include(%q(grep -qE '^GRUB_SAVEDEFAULT=["'\'']?true'))
    expect(script).to include('apt-mark hold "$stock_pkg"', 'apt-mark manual "$stock_pkg"', 'apt-mark hold "$pkg"')
  end
end
