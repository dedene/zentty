# frozen_string_literal: true

module ReleaseAutomation
  CHANNELS = %w[stable beta].freeze
  STABLE_VERSION_REGEX = /\A\d+\.\d+\.\d+\z/
  BETA_VERSION_REGEX = /\A\d+\.\d+\.\d+-beta\.\d+\z/
  APPCAST_FILENAME = "appcast.xml"

  module_function

  def normalize_channel(value)
    channel = value.to_s.strip.downcase
    CHANNELS.include?(channel) ? channel : nil
  end

  def normalized_version(value)
    value.to_s.strip.sub(/\Av/, "")
  end

  def release_tag(version)
    "v#{normalized_version(version)}"
  end

  def stable_version?(value)
    STABLE_VERSION_REGEX.match?(normalized_version(value))
  end

  def beta_version?(value)
    BETA_VERSION_REGEX.match?(normalized_version(value))
  end

  def validate_version!(channel:, version:)
    normalized = normalized_version(version)

    case normalize_channel(channel)
    when "stable"
      raise ArgumentError, "Stable releases must use x.y.z" unless stable_version?(normalized)
    when "beta"
      raise ArgumentError, "Beta releases must use x.y.z-beta.N" unless beta_version?(normalized)
    else
      raise ArgumentError, "Unknown release channel: #{channel}"
    end

    normalized
  end

  def patch_bump(version)
    normalized = normalized_version(version)
    match = STABLE_VERSION_REGEX.match(normalized)
    raise ArgumentError, "Cannot patch bump non-semver version: #{version}" unless match

    major, minor, patch = normalized.split(".").map(&:to_i)
    "#{major}.#{minor}.#{patch + 1}"
  end

  def suggested_version(channel:, latest_version:)
    base = patch_bump(latest_version || "0.0.0")
    normalize_channel(channel) == "beta" ? "#{base}-beta.1" : base
  end

  def sparkle_channel(channel)
    normalize_channel(channel) == "beta" ? "beta" : nil
  end

  def archive_basename(app_name:, version:, build:)
    "#{app_name}-#{normalized_version(version)}-#{build}"
  end

  def appcast_key
    APPCAST_FILENAME
  end
end
