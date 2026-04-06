# frozen_string_literal: true

require_relative "release_automation"

def assert(condition, message = "assertion failed")
  raise message unless condition
end

def assert_equal(expected, actual, message = nil)
  return if expected == actual

  raise(message || "Expected #{expected.inspect}, got #{actual.inspect}")
end

def assert_nil(actual, message = nil)
  return if actual.nil?

  raise(message || "Expected nil, got #{actual.inspect}")
end

def assert_match(pattern, actual, message = nil)
  return if pattern.match?(actual)

  raise(message || "Expected #{actual.inspect} to match #{pattern.inspect}")
end

def assert_raises(error_class)
  begin
    yield
  rescue error_class => e
    return e
  end

  raise "Expected #{error_class} to be raised"
end

assert_equal "stable", ReleaseAutomation.normalize_channel(" stable ")
assert_equal "beta", ReleaseAutomation.normalize_channel("BETA")
assert_nil ReleaseAutomation.normalize_channel("nightly")

assert_equal "v1.2.3", ReleaseAutomation.release_tag("1.2.3")
assert_equal "v1.2.3", ReleaseAutomation.release_tag("v1.2.3")

assert ReleaseAutomation.stable_version?("1.2.3")
refute_stable = ReleaseAutomation.stable_version?("1.2.3-beta.1")
assert_equal false, refute_stable
assert_equal "1.2.3", ReleaseAutomation.validate_version!(channel: "stable", version: "v1.2.3")

assert ReleaseAutomation.beta_version?("1.2.3-beta.4")
refute_beta = ReleaseAutomation.beta_version?("1.2.3")
assert_equal false, refute_beta
assert_equal "1.2.3-beta.4", ReleaseAutomation.validate_version!(channel: "beta", version: "v1.2.3-beta.4")

assert_equal "1.2.4", ReleaseAutomation.patch_bump("1.2.3")
assert_equal "1.2.4", ReleaseAutomation.suggested_version(channel: "stable", latest_version: "v1.2.3")
assert_equal "1.2.4-beta.1", ReleaseAutomation.suggested_version(channel: "beta", latest_version: "1.2.3")

assert_nil ReleaseAutomation.sparkle_channel("stable")
assert_equal "beta", ReleaseAutomation.sparkle_channel("beta")
assert_equal "Zentty-1.2.3-456", ReleaseAutomation.archive_basename(app_name: "Zentty", version: "v1.2.3", build: "456")
assert_equal "appcast.xml", ReleaseAutomation.appcast_key

error = assert_raises(ArgumentError) { ReleaseAutomation.validate_version!(channel: "stable", version: "1.2.3-beta.1") }
assert_match(/Stable releases/, error.message)

error = assert_raises(ArgumentError) { ReleaseAutomation.validate_version!(channel: "beta", version: "1.2.3") }
assert_match(/Beta releases/, error.message)

puts "release automation helper tests passed"
