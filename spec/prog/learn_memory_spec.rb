# frozen_string_literal: true

require_relative "../model/spec_helper"

RSpec.describe Prog::LearnMemory do
  subject(:lm) { described_class.new(Strand.create_with_id(sshable, prog: "LearnMemory", label: "start")) }

  let(:sshable) { Sshable.create }

  let(:four_units) do
    <<EOS

	Size: 16 GB
	Size: 16 GB
	Size: 16 GB
	Size: 16 GB
EOS
  end

  let(:dmidecode) { "sudo /usr/sbin/dmidecode -t memory | fgrep Size: || true" }

  describe "#start" do
    it "exits, saving the number of memory" do
      expect(lm.sshable).to receive(:_cmd).with(dmidecode).and_return(four_units)
      expect { lm.start }.to exit({mem_gib: 64})
    end

    it "falls back to MemTotal when dmidecode lists no memory device" do
      expect(lm.sshable).to receive(:_cmd).with(dmidecode).and_return("")
      expect(lm.sshable).to receive(:_cmd).with("cat /proc/meminfo").and_return("MemTotal:       16365856 kB\nMemFree:        15000000 kB\n")
      expect { lm.start }.to exit({mem_gib: 16})
    end
  end

  describe "#parse_sum" do
    it "sums sizes in any unit dmidecode prints and rounds down to GiB" do
      expect(lm.parse_sum(<<EOS)).to eq 1032
	Size: 7680 MB
	Size: 1 TB
	Size: 524288 kB
	Size: No Module Installed
	Volatile Size: 8 GB
EOS
    end

    it "returns nil when no device is installed" do
      expect(lm.parse_sum("\tSize: No Module Installed\n")).to be_nil
    end

    it "crashes if an unfamiliar unit is provided" do
      expect {
        lm.parse_sum(<<EOS)
	Size: 16 PB
EOS
      }.to raise_error RuntimeError, "BUG: unexpected dmidecode unit PB"
    end
  end

  describe "#parse_meminfo" do
    it "crashes without MemTotal" do
      expect { lm.parse_meminfo("MemFree: 1 kB\n") }.to raise_error RuntimeError, "Couldn't extract total memory"
    end
  end
end
