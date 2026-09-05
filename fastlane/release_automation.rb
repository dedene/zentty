# frozen_string_literal: true

require "json"

module ReleaseAutomation
  CHANNELS = %w[stable beta].freeze
  STABLE_VERSION_REGEX = /\A\d+\.\d+\.\d+\z/
  BETA_VERSION_REGEX = /\A\d+\.\d+\.\d+-beta\.\d+\z/
  APPCAST_FILENAME = "appcast.xml"
  SPARKLE_PACKAGE_IDENTITY = "sparkle"

  module_function

  def normalize_channel(value)
    channel = value.to_s.strip.downcase
    CHANNELS.include?(channel) ? channel : nil
  end

  def normalized_version(value)
    normalized = value.to_s.strip.sub(/\Av/, "")
    normalized.empty? ? nil : normalized
  end

  def release_tag(version)
    normalized = normalized_version(version)
    raise ArgumentError, "Release tag requires a version" if normalized.nil?

    "v#{normalized}"
  end

  def stable_version?(value)
    normalized = normalized_version(value)
    !normalized.nil? && STABLE_VERSION_REGEX.match?(normalized)
  end

  def beta_version?(value)
    normalized = normalized_version(value)
    !normalized.nil? && BETA_VERSION_REGEX.match?(normalized)
  end

  def validate_version!(channel:, version:)
    normalized = normalized_version(version)
    raise ArgumentError, "Release version is required" if normalized.nil?

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

  def suggested_version(channel:, latest_version:, fallback_version: nil)
    normalized_latest = normalized_version(latest_version)
    base =
      if normalized_latest.nil?
        normalized_fallback = normalized_version(fallback_version)
        raise ArgumentError, "Cannot suggest version without a stable fallback version" unless stable_version?(normalized_fallback)

        normalized_fallback
      else
        patch_bump(normalized_latest)
      end

    normalize_channel(channel) == "beta" ? "#{base}-beta.1" : base
  end

  def sparkle_channel(channel)
    normalize_channel(channel) == "beta" ? "beta" : nil
  end

  def archive_basename(app_name:, version:, build:)
    normalized = normalized_version(version)
    raise ArgumentError, "Archive basename requires a version" if normalized.nil?

    "#{app_name}-#{normalized}-#{build}"
  end

  def replace_yaml_scalar(content:, key:, value:)
    pattern = /^(\s*#{Regexp.escape(key)}:\s*).+$/
    content.sub(pattern) { "#{$1}#{value}" }
  end

  def yaml_scalar_present?(content:, key:)
    content.match?(/^\s*#{Regexp.escape(key)}:\s*.+$/)
  end

  def appcast_key
    APPCAST_FILENAME
  end

  def glitchtip_debug_files_upload_command(upload_root:, url: nil, auth_token: nil, org: nil, project: nil, wait: true)
    command = ["glitchtip-cli"]

    normalized_url = url.to_s.strip
    command += ["--url", normalized_url] unless normalized_url.empty?

    normalized_auth_token = auth_token.to_s.strip
    command += ["--auth-token", normalized_auth_token] unless normalized_auth_token.empty?

    command += ["debug-files", "upload", upload_root]
    command << "--wait" if wait

    normalized_org = org.to_s.strip
    command += ["--org", normalized_org] unless normalized_org.empty?

    normalized_project = project.to_s.strip
    command += ["--project", normalized_project] unless normalized_project.empty?

    command
  end

  def missing_glitchtip_upload_env_names(env)
    %w[SENTRY_URL SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT].select do |name|
      env.fetch(name, "").to_s.strip.empty?
    end
  end

  # Reads the pinned Sparkle revision from an Xcode workspace Package.resolved.
  # Returns { location:, revision:, version: } or nil when Sparkle is not pinned.
  def sparkle_pin(resolved_json)
    resolved = resolved_json.is_a?(String) ? JSON.parse(resolved_json) : resolved_json
    pin = Array(resolved["pins"]).find { |entry| entry["identity"].to_s.casecmp?(SPARKLE_PACKAGE_IDENTITY) }
    return nil unless pin

    state = pin["state"] || {}
    revision = state["revision"].to_s.strip
    return nil if revision.empty?

    {
      location: pin["location"].to_s.strip,
      revision: revision,
      version: state["version"].to_s.strip
    }
  end

  # candidates: [{ path:, head: }] where head is the checkout's git HEAD (nil if unknown).
  # Returns the first path whose HEAD matches the pinned revision, or nil.
  def select_pinned_checkout(candidates, revision:)
    match = candidates.find { |candidate| candidate[:head].to_s.strip == revision }
    match && match[:path]
  end

  def sparkle_tools_dir(project_root:, revision:)
    File.join(project_root, "build", "sparkle-tools", revision)
  end

  def sparkle_clone_dir(project_root:, revision:)
    File.join(project_root, "build", "sparkle-tools", "checkouts", "Sparkle-#{revision}")
  end

  def codex_release_notes_command(output_path:, prompt:)
    ["codex", "exec", "--ephemeral", "--output-last-message", output_path, prompt]
  end
end
