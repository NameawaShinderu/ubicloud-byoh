# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/container_idmap"

RSpec.describe ContainerIdmap do
  around do |example|
    Dir.mktmpdir("idmap") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:dir) { File.join(@dir, "idmap") }

  it "puts the slots above SUB_UID_MAX and inside 32-bit ids" do
    expect(described_class::BASE).to be > 600_100_000
    expect(described_class.base(0)).to eq 1_000_000_000
    expect(described_class.base(1)).to eq 1_000_065_536
    expect(described_class.base(described_class::SLOTS - 1) + described_class::SIZE).to be <= 2**32 - 1
    expect(described_class::ROOT_ENTRY).to eq "root:1000000000:3276800000"
  end

  it "allocates the lowest free slot, keeps a VM's slot and reuses a released one" do
    expect(described_class.allocate("vmaaaaa1", dir: dir)).to eq 0
    expect(described_class.allocate("vmaaaaa2", dir: dir)).to eq 1
    expect(described_class.allocate("vmaaaaa1", dir: dir)).to eq 0
    expect(described_class.slot("vmaaaaa2", dir: dir)).to eq 1
    expect(File.stat(File.join(dir, "vmaaaaa1")).mode & 0o777).to eq 0o600
    expect(File.stat(dir).mode & 0o777).to eq 0o700
    described_class.release("vmaaaaa1", dir: dir)
    expect(described_class.slot("vmaaaaa1", dir: dir)).to be_nil
    expect(described_class.allocate("vmaaaaa3", dir: dir)).to eq 0
    described_class.release("vmaaaaa1", dir: dir)
  end

  it "refuses when every slot is taken" do
    stub_const("ContainerIdmap::SLOTS", 1)
    described_class.allocate("vmaaaaa1", dir: dir)
    expect { described_class.allocate("vmaaaaa2", dir: dir) }.to raise_error(ContainerIdmap::Exhausted, "all 1 container id slots are in use")
  end

  it "refuses names that are not VM names" do
    expect { described_class.allocate("../etc", dir: dir) }.to raise_error(RuntimeError, 'unexpected VM name "../etc"')
    expect { described_class.slot("vm", dir: dir) }.to raise_error(RuntimeError, /unexpected VM name/)
    expect { described_class.release("vmAAAAAA", dir: dir) }.to raise_error(RuntimeError, /unexpected VM name/)
  end

  describe ".overlaps" do
    it "lists every range but root's own entry that reaches the slots, and unreadable lines" do
      subuid = File.join(@dir, "subuid")
      File.write(subuid, <<~SUBID)
        # comment

        ubuntu:100000:65536
        #{described_class::ROOT_ENTRY}
        big:999999999:2
        high:4276799999:5
        after:4276800000:5
        broken:x:1
      SUBID
      expect(described_class.overlaps(files: [subuid, File.join(@dir, "missing")])).to eq([
        "#{subuid}: big:999999999:2",
        "#{subuid}: high:4276799999:5",
        "#{subuid}: broken:x:1",
      ])
    end
  end

  describe ".ensure_root_entries" do
    it "appends root's entry once, keeping the file's lines and mode" do
      present = File.join(@dir, "subuid")
      File.write(present, "ubuntu:100000:65536")
      missing = File.join(@dir, "subgid")
      described_class.ensure_root_entries(files: [present, missing])
      described_class.ensure_root_entries(files: [present, missing])
      expect(File.read(present)).to eq "ubuntu:100000:65536\n#{described_class::ROOT_ENTRY}\n"
      expect(File.read(missing)).to eq "#{described_class::ROOT_ENTRY}\n"
      expect(File.stat(missing).mode & 0o777).to eq 0o644
    end
  end
end
