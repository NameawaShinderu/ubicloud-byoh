# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe Prog::Vm::PrepHost do
  describe "#start" do
    it "prepare host" do
      vm_host = Prog::Vm::HostNexus.assemble("::1").subject
      st = Strand.create(prog: "Vm::PrepHost", label: "start", stack: [{"subject_id" => vm_host.id}])
      ph = described_class.new(st)
      expect(ph.sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test")

      expect { ph.start }.to exit({"msg" => "host prepared"})
    end

    # A kvm host's command has no tier argument, as before tiers existed;
    # each lower tier names its own (rhizome's HostTier.prep_steps).
    %w[emulated container pvm].each do |tier|
      it "names the #{tier} tier" do
        vm_host = Prog::Vm::HostNexus.assemble("::1").subject
        st = Strand.create(prog: "Vm::PrepHost", label: "start", stack: [{"subject_id" => vm_host.id}])
        ph = described_class.new(st)
        allow(ph.vm_host).to receive(:virt_tier).and_return(tier)
        expect(ph.sshable).to receive(:_cmd).with("sudo host/bin/prep_host.rb #{vm_host.ubid} test #{tier}")

        expect { ph.start }.to exit({"msg" => "host prepared"})
      end
    end
  end
end
