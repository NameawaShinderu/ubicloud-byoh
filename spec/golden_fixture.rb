# frozen_string_literal: true

# Golden fixtures freeze output that hosts and customers depend on, so work
# on other host types cannot change it by accident. A fixture changes only
# through a hand-reviewed diff: run the spec locally with UPDATE_GOLDEN=1,
# then review `git diff spec/fixtures/golden`.
module GoldenFixture
  DIR = File.expand_path("fixtures/golden", __dir__)

  def self.read(name, actual)
    path = File.join(DIR, name)
    if ENV["UPDATE_GOLDEN"] == "1"
      fail "UPDATE_GOLDEN=1 is refused under CI; regenerate golden fixtures locally and review the diff" if ENV["CI"]
      File.write(path, actual)
    end
    File.read(path)
  end
end
