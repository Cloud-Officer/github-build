# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'active_support/core_ext/object/deep_dup'
require 'psych'

require_relative '../ghb'
require_relative 'file_scanner'

module GHB
  # Detects programming languages based on file extensions and adds unit test jobs to the workflow.
  class LanguageJobBuilder
    include FileScanner

    # Deploy flags that extend the Swift unit-test `if:` so the job also runs on deploy triggers.
    SWIFT_DEPLOY_CHECK_FLAGS = %w[DEPLOY_ON_BETA DEPLOY_ON_RC DEPLOY_ON_PROD DEPLOY_MACOS DEPLOY_TVOS].freeze
    # Languages whose dependency steps must also be staged as CodeDeploy pre-steps.
    CODEDEPLOY_SETUP_LANGUAGES = %w[go php].freeze
    # How many directory levels below the repo root a sub-project dependency file
    # may sit and still be detected (e.g. js/<module>/package-lock.json is 2 deep).
    SUBDIR_DEPENDENCY_SCAN_DEPTH = 2
    # Token exposed to dependency-install steps. Deliberately the ephemeral, repo-scoped
    # run token and NOT secrets.GH_PAT (SEC-001): install steps execute arbitrary
    # third-party code (postinstall hooks, plugins), so an org-scoped long-lived PAT in their
    # environment is one malicious transitive dependency away from exfiltration.
    #
    # Kept rather than dropped because Tuist's SwiftPM resolution reads GITHUB_TOKEN/GH_TOKEN.
    # The other package managers authenticate by other means and are unaffected: Composer via
    # the github-oauth config setup-php writes from the run token, Bundler via
    # BUNDLE_GITHUB__COM, npm/yarn/pnpm via NODE_AUTH_TOKEN, Carthage via GITHUB_ACCESS_TOKEN,
    # and private sibling repos over SSH through webfactory/ssh-agent with secrets.SSH_KEY.
    # It also raises the API rate limit from 60/hour per runner IP to 1,000/hour per
    # repository -- and unlike the PAT's 5,000/hour shared across every repo and workflow,
    # that budget is isolated per repo, so concurrent builds no longer contend.
    #
    # Unit-test steps get no token at all: none of the supported test frameworks read one.
    # Spelled ${{github.token}} rather than ${{secrets.GITHUB_TOKEN}}: same value, but the
    # github context exists everywhere the secrets context does and in several places it does
    # not - inside a composite action most of all, which is what every cloud-officer/ci-actions
    # step is. One spelling across the generator also keeps `secrets.` a grep for the secrets a
    # repo genuinely has to configure; the run token is minted per job and is not one of them.
    DEPENDENCY_STEP_TOKEN = '${{github.token}}'
    # The PAT reference this tool used to inject, kept so regeneration can recognise and strip
    # it from workflows generated before SEC-001 was fixed.
    INJECTED_PAT = '${{secrets.GH_PAT}}'
    # Rails system tests (Capybara) save a screenshot of every failing test here.
    SYSTEM_TESTS_DIRECTORY = 'test/system'
    SYSTEM_TESTS_SCREENSHOTS_DIRECTORY = 'tmp/screenshots'
    SYSTEM_TESTS_SCREENSHOTS_STEP_NAME = 'Upload Failure Screenshots'
    private_constant :SWIFT_DEPLOY_CHECK_FLAGS, :CODEDEPLOY_SETUP_LANGUAGES, :SUBDIR_DEPENDENCY_SCAN_DEPTH, :DEPENDENCY_STEP_TOKEN, :INJECTED_PAT, :SYSTEM_TESTS_DIRECTORY, :SYSTEM_TESTS_SCREENSHOTS_DIRECTORY, :SYSTEM_TESTS_SCREENSHOTS_STEP_NAME

    attr_reader :code_deploy_pre_steps

    # Steps inherit their env from the previously generated workflow via copy_properties, so
    # simply no longer injecting the PAT would leave it in place forever in every repo that
    # already has one written. Strip it on regeneration -- but only when the value is exactly
    # the PAT reference this tool used to inject, so a GITHUB_TOKEN the user set deliberately
    # (or already migrated to the run token) is left alone.
    def self.drop_injected_pat(env)
      env.delete('GITHUB_TOKEN') if env['GITHUB_TOKEN'] == INJECTED_PAT
      env.delete(:GITHUB_TOKEN) if env[:GITHUB_TOKEN] == INJECTED_PAT
    end

    def initialize(context:, unit_tests_conditions:)
      @options = context.options
      @submodules = context.submodules
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
      @unit_tests_conditions = unit_tests_conditions
      @file_cache = context.file_cache
      @code_deploy_pre_steps = []
      # Package managers marked `package_manager_once` that have already emitted an
      # install step in this job, so a system-wide tool install is not repeated per
      # detected sub-project. Scoped to the builder, which is per language job.
      @installed_once = []
    end

    def build
      puts('    Detecting languages...')
      languages = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.languages_config_file}"))&.deep_symbolize_keys
      service_options = SERVICES.to_h { |service| [service, load_service_options(service)] }

      languages&.each_value do |language|
        next unless language.is_a?(Hash)

        detect_language(language, service_options)
      end
    end

    private

    # Setup options declared by a service's config/options file, or nil when it declares none.
    def load_service_options(service)
      Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_files[service]}"))&.deep_symbolize_keys&.[](:options)
    end

    def detect_language(language, service_options)
      return if language[:file_extension].nil?

      language_detected = false
      detected_services = Set.new(ALWAYS_ENABLED_SERVICES)
      setup_options = {}

      # Pure Ruby file finding - avoids shell injection (SEC-002)
      excluded_paths = @options.excluded_folders + @submodules
      pattern = Regexp.new(".*\\.(#{language[:file_extension]})$")
      matches = find_files_matching('.', pattern, excluded_paths)

      if matches.any?
        dependency_detected = false
        mono_dependency_locations = []
        # Every lockfile found, root and sub-project alike, so the dependency cache can be
        # pointed at the paths it must hash (issue #263).
        detected_dependencies = []

        language[:dependencies].each do |dependency|
          if File.file?(dependency[:dependency_file])
            dependency_detected = true
            detected_dependencies << { dependency: dependency, path: dependency[:dependency_file] }
          end

          mono_dependency_locations.concat(find_subdir_dependencies(dependency, excluded_paths))
        end

        detected_dependencies.concat(mono_dependency_locations)
        dependency_detected = true if mono_dependency_locations.any?

        return unless dependency_detected

        language_detected = true

        # Pure Ruby dependency checking - avoids shell injection (SEC-002)
        language[:dependencies].each do |dependency|
          detected_services.merge(detect_services(dependency, dependency[:dependency_file]))
        end

        # Also check subdirectory dependency files for service detection
        mono_dependency_locations.each do |loc|
          detected_services.merge(detect_services(loc[:dependency], loc[:path]))
        end
      end

      return unless language_detected

      puts("        Enabling #{language[:long_name]}...")
      version_file = language[:version_files]&.find { |f| File.exist?(f) }
      add_setup_options(setup_options, language[:setup_options], version_file)
      SERVICES.each { |service| add_setup_options(setup_options, service_options[service]) if detected_services.include?(service) }
      cache_options = cache_setup_options(language, detected_dependencies)
      setup_options.merge!(cache_options)

      add_language_job(language, setup_options, version_file, mono_dependency_locations, cache_options)
    end

    # Wire the language's dependency cache (e.g. actions/setup-node's `cache:`) to the
    # lockfiles actually present in the repo.
    #
    # The cache is only ever enabled together with the paths it must hash: with a bare
    # `cache: npm` the setup action looks for a lockfile at the repo root and fails with
    # "Dependencies lock file is not found" in any repo whose lockfile lives in a
    # sub-project (ci-actions' slack/package-lock.json). That is why the two options are
    # derived here as a pair rather than carrying a static value in the config (#263).
    def cache_setup_options(language, detected_dependencies)
      cache_option = language[:cache_option]
      path_option = language[:cache_dependency_path_option]

      return {} unless cache_option && path_option
      return {} if detected_dependencies.empty?

      cacheable = detected_dependencies.select { |found| found[:dependency][:cache_name] }
      cache_names = cacheable.map { |found| found[:dependency][:cache_name] }
      cache_names.uniq!

      # The setup actions take a single package manager, so a repo mixing two (npm and
      # yarn side by side) cannot be expressed. Leave caching off rather than guess and
      # cache the wrong dependency tree.
      unless cache_names.one?
        puts("        Skipping #{cache_option}: #{cache_skip_reason(cache_names)}")

        return {}
      end

      env_key = cache_option.upcase.to_sym
      @new_workflow.env[env_key] = cache_names.first unless @new_workflow.env[env_key]
      paths = cacheable.map { |found| found[:path] }
      paths.uniq!
      paths.sort!

      { cache_option => "${{env.#{cache_option.upcase}}}", path_option => paths.join("\n") }
    end

    def cache_skip_reason(cache_names)
      return 'no cacheable package manager detected' if cache_names.empty?

      "multiple package managers detected (#{cache_names.join(', ')})"
    end

    # Services whose marker string (the `<service>_dependency` key) appears in the given
    # dependency file. Used for both the repo-root and the sub-project lockfiles so the
    # two detection sites can no longer diverge.
    def detect_services(dependency, path)
      DETECTABLE_SERVICES.select do |service|
        marker = dependency[GHB.service_dependency_key(service)]
        marker && file_contains?(path, marker)
      end
    end

    # Find a language's dependency lockfile in sub-project directories. Scans up to
    # SUBDIR_DEPENDENCY_SCAN_DEPTH levels below the repo root, skipping the root
    # itself (detected separately) and any excluded/vendored directory. Replaces the
    # former `--mono_repo`-gated one-level glob: sub-project detection is now default.
    def find_subdir_dependencies(dependency, excluded_paths)
      # find_files_matching yields root-relative paths ("./sub/file"), where a file
      # directly under the start dir is depth 1; a file N directories deep is depth
      # N+1. Allow one extra so SUBDIR_DEPENDENCY_SCAN_DEPTH counts subdir levels.
      pattern = Regexp.new("/#{Regexp.escape(dependency[:dependency_file])}\\z")
      matches = find_files_matching('.', pattern, excluded_paths, max_depth: SUBDIR_DEPENDENCY_SCAN_DEPTH + 1)

      matches.filter_map do |found|
        next if File.dirname(found) == '.' # repo root is detected separately via File.file?

        relative = found.delete_prefix('./')
        { dependency: dependency, subdir: File.dirname(relative), path: relative }
      end
    end

    # True for languages that get the extended Swift deploy `if:` checks.
    def extra_deploy_checks?(language)
      language[:short_name] == 'swift'
    end

    # Swift + Xcode Cloud: collect dependency info but drop the unit-test job.
    def xcode_cloud_unit_tests?(language)
      language[:short_name] == 'swift' && Dir.exist?('ci_scripts')
    end

    # Whether this language's dependency steps must also be staged as CodeDeploy pre-steps.
    def needs_codedeploy_setup?(language)
      CODEDEPLOY_SETUP_LANGUAGES.include?(language[:short_name]) || @options.force_codedeploy_setup
    end

    # The extra `|| (...)` deploy checks appended to the Swift unit-test `if:`.
    def additional_unit_test_checks(language)
      return '' unless extra_deploy_checks?(language)

      checks = SWIFT_DEPLOY_CHECK_FLAGS.map { |flag| "(needs.variables.outputs.#{flag} == '1')" }

      " || #{checks.join(' || ')}"
    end

    def add_language_job(language, setup_options, version_file, mono_dependency_locations, cache_options = {})
      additional_checks = additional_unit_test_checks(language)
      needs_codedeploy_setup = needs_codedeploy_setup?(language)
      # Swift with Xcode Cloud (ci_scripts): build the job to collect dependency info, then delete it below.
      skip_unit_test_job = xcode_cloud_unit_tests?(language)

      @new_workflow.do_job(:"#{language[:short_name]}_unit_tests") do |job|
        job.copy_properties(@old_workflow.jobs[job.id])
        job.do_name("#{language[:long_name]} Unit Tests")
        job.do_runs_on(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.runs_on || GHB.runner_image(language[:'runs-on']))
        job.do_needs(%w[variables])
        job.do_if("${{#{@unit_tests_conditions}#{additional_checks}}}")

        build_setup_step(job, language, version_file, setup_options, needs_codedeploy_setup, cache_options)
        dependency_detected = build_dependency_steps(job, language, needs_codedeploy_setup)
        build_mono_dependency_steps(job, language, mono_dependency_locations)

        next unless dependency_detected || mono_dependency_locations.any?

        build_system_tests_screenshots_step(job, language) if dependency_detected && system_tests?(language)
        build_licenses_step(job, language) if File.exist?('Podfile.lock') && @options.skip_license_check == false
      end

      # Remove the unit test job from the workflow when Xcode Cloud handles tests.
      return unless skip_unit_test_job

      @new_workflow.jobs.delete(:"#{language[:short_name]}_unit_tests")
      puts("        Skipping #{language[:long_name]} Unit Tests job (Xcode Cloud handles tests via ci_scripts)")
    end

    def build_setup_step(job, language, version_file, setup_options, needs_codedeploy_setup, cache_options = {})
      version_option_key = version_file && version_option_name(version_file).to_sym

      job.do_step('Setup') do |step|
        step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
        step.do_uses("cloud-officer/ci-actions/setup@#{CI_ACTIONS_VERSION}")

        # Remove version parameter from with if version file exists (version file takes precedence)
        step.with.delete(version_option_key) if version_option_key

        step.default_with(GHB.secrets(:ssh, :github_token).merge(setup_options))

        step.with[:'github-token'] = '${{github.token}}'

        # Applied outside the `with.empty?` branch above on purpose. A workflow generated
        # before the cache was wired already carries a populated `with`, so merging only on
        # the empty path would leave the cache dead in every existing repo -- exactly the
        # NODE-CACHE-is-declared-but-never-passed state issue #263 reported. An operator's
        # own value still wins: only keys absent from `with` are filled in.
        cache_options.each { |key, value| step.with[key.to_sym] = value unless step.with.key?(key.to_sym) }

        @code_deploy_pre_steps << step.deep_dup if needs_codedeploy_setup
      end
    end

    def build_dependency_steps(job, language, needs_codedeploy_setup)
      dependency_detected = false

      language[:dependencies].each do |dependency|
        next unless File.file?(dependency[:dependency_file])

        dependency_detected = true
        @installed_once << dependency[:package_manager_name] if dependency[:package_manager_once]

        job.do_step(dependency[:package_manager_name]) do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
          step.do_shell('bash')
          step.do_run(dependency[:package_manager_default]) if step.run.nil?
          step.env['GITHUB_TOKEN'] = DEPENDENCY_STEP_TOKEN
          @code_deploy_pre_steps << step.deep_dup if needs_codedeploy_setup
        end
      end

      if dependency_detected
        job.do_step(language[:unit_test_framework_name]) do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
          step.do_shell('bash')
          step.do_run(language[:unit_test_framework_default]) if step.run.nil?
          LanguageJobBuilder.drop_injected_pat(step.env)
        end
      end

      dependency_detected
    end

    def build_mono_dependency_steps(job, language, mono_dependency_locations)
      mono_dependency_locations.each do |loc|
        dep = loc[:dependency]
        subdir = loc[:subdir]

        # `package_manager_once` marks a dependency whose command installs a tool
        # system-wide rather than that sub-project's dependencies -- shell_script's
        # `.bats` is a zero-byte marker and the command installs the bats runner
        # itself. Every other ecosystem's command (npm install, composer install,
        # bundle install, pip install -r) resolves a manifest in its own directory,
        # so repeating it per sub-project is required. Emitting a system-wide
        # install once per detected directory only repeats `apt-get update` on the
        # same runner and multiplies the chances of a transient apt failure.
        if dep[:package_manager_once]
          unless @installed_once.include?(dep[:package_manager_name])
            @installed_once << dep[:package_manager_name]

            job.do_step(dep[:package_manager_name]) do |step|
              step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
              step.do_shell('bash')
              step.do_run(dep[:package_manager_default]) if step.run.nil?
              step.env['GITHUB_TOKEN'] = DEPENDENCY_STEP_TOKEN
            end
          end
        else
          job.do_step("#{dep[:package_manager_name]} (#{subdir})") do |step|
            step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
            step.do_shell('bash')
            step.do_run("cd #{subdir} && #{dep[:package_manager_default]}") if step.run.nil?
            step.env['GITHUB_TOKEN'] = DEPENDENCY_STEP_TOKEN
          end
        end

        job.do_step("#{language[:unit_test_framework_name]} (#{subdir})") do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
          step.do_shell('bash')
          step.do_run("cd #{subdir} && #{language[:unit_test_framework_default]}") if step.run.nil?
          LanguageJobBuilder.drop_injected_pat(step.env)
        end
      end
    end

    def system_tests?(language)
      language[:short_name] == 'ruby' && Dir.exist?(SYSTEM_TESTS_DIRECTORY)
    end

    # The artifact name carries the matrix leg index so a `test` / `test:system` matrix does not collide on upload.
    def build_system_tests_screenshots_step(job, language)
      job.do_step(SYSTEM_TESTS_SCREENSHOTS_STEP_NAME) do |step|
        step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
        step.do_if('failure()') if step.if.nil?
        step.do_uses(GHB.external_action('actions/upload-artifact'))

        step.default_with(
          name: 'system-test-screenshots-${{strategy.job-index}}',
          path: SYSTEM_TESTS_SCREENSHOTS_DIRECTORY,
          'if-no-files-found': 'ignore'
        )
      end
    end

    def build_licenses_step(job, language)
      job.do_step('Licenses') do |step|
        step.copy_properties(step.find_step(@old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, step.name))
        step.do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

        step.default_with(GHB.secrets(:ssh, :github_token).merge(parameters: '--no_prompt'))
      end
    end

    # .ruby-version -> ruby-version; .nvmrc is the one file not named after its option.
    def version_option_name(version_file)
      version_file == '.nvmrc' ? 'node-version' : version_file.delete_prefix('.')
    end

    def add_setup_options(setup_options, options, version_file = nil)
      skipped_option = version_file && version_option_name(version_file)

      options&.each do |option|
        if skipped_option && option[:name] == skipped_option
          reconcile_version_file(option, version_file)
        else
          merge_env_option(setup_options, option)
        end
      end
    end

    # The ci-actions setup reads the version file itself, so the option must not also land in env.
    def reconcile_version_file(option, version_file)
      @new_workflow.env.delete(option[:name].upcase.to_sym)
      recommended = option[:value]
      return unless recommended

      file_version = File.read(version_file).strip
      strict = @options.strict_version_check

      if version_file_mismatch?(file_version, recommended.to_s)
        resolution = strict ? "Updating #{version_file} to #{recommended}." : 'Using version file.'
        warn_value_mismatch(option[:name], "Version file (#{version_file}): #{file_version}", recommended, resolution)

        if strict
          File.write(version_file, "#{recommended}\n")
          file_version = recommended.to_s
        end
      end

      sync_ruby_version_files(file_version) if strict && version_file == '.ruby-version'
    end

    # A Dockerfile that pins Ruby in an ARG drifts silently from .ruby-version
    # and only fails when the image is built, which is usually a release.
    def sync_ruby_version_files(version)
      sync_file_version('Gemfile', /^(\s*ruby\s+['"])\d[\w.]*(['"])/, version)
      sync_file_version('Gemfile.lock', /^(RUBY VERSION\r?\n\s+ruby )\S+/, version)
      sync_file_version('Dockerfile', /^(ARG RUBY_VERSION=)\S+/, version)
    end

    def sync_file_version(file, pattern, version)
      return unless File.exist?(file)

      content = File.read(file)
      updated = content.sub(pattern) { "#{::Regexp.last_match(1)}#{version}#{::Regexp.last_match(2)}" }
      return if updated == content

      puts("        Updating Ruby version in #{file} to #{version}...")
      File.write(file, updated)
    end

    def merge_env_option(setup_options, option)
      env_key = option[:name].upcase.to_sym
      existing_value = @new_workflow.env[env_key]
      recommended = option[:value]
      value = existing_value || recommended
      return unless value

      if existing_value && recommended && existing_value.to_s != recommended.to_s
        update = @options.strict_version_check && env_key.to_s.include?('VERSION')
        resolution = update ? "Updating #{env_key} to #{recommended}." : 'Using existing value.'
        warn_value_mismatch(option[:name], "Existing value: #{existing_value}", recommended, resolution)
        value = recommended if update
      end

      @new_workflow.env[env_key] = value
      setup_options[option[:name]] = "${{env.#{env_key}}}"
    end

    def warn_value_mismatch(name, actual, recommended, resolution)
      puts("\e[31m\n#{'*' * 80}")
      puts("WARNING: Value mismatch for #{name.upcase}")
      puts(actual)
      puts("Recommended value: #{recommended}")
      puts(resolution)
      puts("#{'*' * 80}\n\e[0m")
    end

    # A version file may intentionally pin fewer segments than the recommended
    # value: e.g. .php-version pins "8.5" and setup-php/phpenv resolve the latest
    # patch at install time. A recommendation that only adds a more specific
    # patch within the same prefix is not a real mismatch, so it must not
    # trigger a version-mismatch warning.
    def version_file_mismatch?(file_version, recommended)
      return false if file_version == recommended
      return false if recommended.start_with?("#{file_version}.")

      true
    end
  end
end
