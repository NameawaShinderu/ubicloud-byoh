# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe Config do
  it "can have float config" do
    described_class.class_eval do
      override :test_float, 0.5, float
    end

    expect(described_class.test_float).to eq(0.5)
  end

  it "can have nil array config" do
    described_class.class_eval do
      override :test_array, nil, array
    end

    expect(described_class.test_array).to be_nil
  end

  it "uuid accepts valid uuid" do
    id = SecureRandom.uuid
    described_class.class_eval do
      override :test_valid_uuid, id, uuid
    end
    expect(described_class.test_valid_uuid).to eq(id)
  end

  it "uuid accepts nil" do
    described_class.class_eval do
      optional :test_nil_uuid, uuid
    end
    expect(described_class.test_nil_uuid).to be_nil
  end

  it "uuid rejects invalid uuid" do
    expect {
      described_class.class_eval do
        override :test_valid_uuid, "invalid", uuid
      end
    }.to raise_error("invalid uuid invalid")
  end

  it "match? accepts nil and matching values" do
    described_class.class_eval do
      override :test_match, "g1", match?(/\A[0-9a-hj-km-np-tv-z]{2}\z/)
      optional :test_nil_match, match?(/\A[0-9a-hj-km-np-tv-z]{2}\z/)
    end
    expect(described_class.test_match).to eq("g1")
    expect(described_class.test_nil_match).to be_nil
  end

  it "match? rejects non-matching values" do
    ["g", "g1x", "gu", "G1", "o1", "1l"].each do |value|
      expect {
        described_class.class_eval do
          override :test_match, value, match?(/\A[0-9a-hj-km-np-tv-z]{2}\z/)
        end
      }.to raise_error(RuntimeError, /invalid value #{Regexp.escape(value.inspect)}, must match/)
    end
  end

  describe "boot_image_source" do
    let(:line) { File.read(File.expand_path("../config.rb", __dir__)).lines.find { it.include?("override :boot_image_source") }.sub(":boot_image_source", ":test_boot_image_source") }

    after { ENV.delete("TEST_BOOT_IMAGE_SOURCE") }

    it "defaults to auto and accepts public" do
      expect(described_class.boot_image_source).to eq "auto"
      ENV["TEST_BOOT_IMAGE_SOURCE"] = "public"
      described_class.class_eval(line)
      expect(described_class.test_boot_image_source).to eq "public"
    end

    it "rejects any other value" do
      ENV["TEST_BOOT_IMAGE_SOURCE"] = "r2"
      expect { described_class.class_eval(line) }.to raise_error(RuntimeError, /invalid value "r2", must match/)
    end
  end

  it "ignores LoadError when .env.rb is not present" do
    main = TOPLEVEL_BINDING.eval("self")
    expect(main).to receive(:require_relative).with("lib/casting_config_helpers")
    expect(main).to receive(:require_relative).with(".env").and_raise(LoadError)
    expect(ENV).to receive(:[]) do |k|
      throw :skip, k
    end
    value = catch(:skip) do
      expect { load(File.expand_path("../config.rb", __dir__)) }.not_to raise_error
    end
    expect(value).to eq "SYNC"
  end
end
