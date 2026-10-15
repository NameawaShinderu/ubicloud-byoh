# frozen_string_literal: true

require_relative "spec_helper"

require "open3"
require "rbconfig"

Gem.ruby # force early loading to work in frozen specs

# rubocop:disable RSpec/DescribeClass
# The subject is the bin scripts, which have no class.
RSpec.describe "BYOH operator bin scripts" do
  # rubocop:enable RSpec/DescribeClass

  %w[byoh-host byoh-location byoh-pool register-byoh-host].each do |bin|
    it "#{bin} writes unbuffered output when stdout is a pipe" do
      script = <<~RUBY
        at_exit { $stderr.print "SYNC=\#{$stdout.sync},\#{$stderr.sync}\\n" }
        ARGV.replace(["--help"])
        load "bin/#{bin}"
      RUBY
      _, err, status = Open3.capture3({"RACK_ENV" => "test"}, RbConfig.ruby, "-e", script)
      expect(status.exitstatus).to eq 0
      expect(err).to end_with("SYNC=true,true\n")
    end
  end
end
