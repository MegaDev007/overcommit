begin
  require 'rubygems'
  require 'haml'
rescue LoadError => e
  missing = e.message.split(' ').last
  puts "'#{missing}' gem not available"
end

real_hook = File.symlink?(__FILE__) ? File.readlink(__FILE__) : __FILE__

require File.expand_path('../../staged_file', __FILE__)

SCRIPTS_PATH = File.expand_path('../../scripts/', real_hook)

module Causes
  class PreCommitHook
    include GitHook

    def initialize
      skip_checks = ENV.fetch('SKIP_CHECKS', '').split

      @checks = %w[
        erb_syntax
        haml_syntax
        js_syntax
        js_console_log
        restricted_paths
        ruby_syntax
        whitespace
        yaml_syntax
        css_linter
        test_history
      ] - skip_checks

      # Only check test history if repo supports it
      unless FileTest.exist?('spec/support/record_results_formatter.rb')
        @checks.delete 'test_history'
      end

      @checks.clear if skip_checks.include? 'all'

      @width = 60 - (@checks.map{|s| s.length}.max || 0)
    end

    ERB_CHECKER = 'bin/check-rails-erb'
    def check_erb_syntax
      return :warn, 'Bundler is not installed' unless in_path? 'bundle'
      unless File.executable? ERB_CHECKER
        return :warn, "Can't find/execute #{ERB_CHECKER}"
      end

      staged = staged_files('erb')
      return :good, nil if staged.empty?

      output = `bundle exec #{ERB_CHECKER} #{staged.map{|file| file.path}.join(' ')}`
      staged.each { |s| output = s.filter_string(output) }
      return (output !~ /: compile error$/ ? :good : :bad), output
    end

    def check_haml_syntax
      staged = staged_files('haml')
      return :good, nil if staged.empty?

      unless defined? Haml
        return :warn, "Can't find Haml gem"
      end

      staged.map { |s| s.path }.each do |path|
        begin
          Haml::Engine.new(File.read(path), :check_syntax => true)
        rescue Haml::Error => e
          return :bad, e.message
        end
      end
      return :good, nil
    end

    JS_HINT_PATH = File.join(SCRIPTS_PATH, 'jshint.js')
    JS_HINT_RUNNER_PATH = File.join(SCRIPTS_PATH, 'jshint_runner.js')
    def check_js_syntax
      return :warn, "Rhino is not installed" unless in_path? 'rhino'

      staged = staged_files('js')
      return :good, nil if staged.empty?
      paths = staged.map { |s| s.path }.join(' ')

      output = `rhino -strict -f #{JS_HINT_PATH} #{JS_HINT_RUNNER_PATH} #{paths} 2>&1 | grep -v warning | grep -v -e '^js: '`
      staged.each { |s| output = s.filter_string(output) }
      return (output !~ /^ERROR/ ? :good : :bad), output
    end

    # https://www.pivotaltracker.com/story/show/18119495
    def check_js_console_log
      staged = staged_files('js')
      return :good, nil if staged.empty?

      paths = staged.map { |s| s.path }.join(' ')
      output = `grep -n -e 'console\\.log' #{paths}`.split("\n").reject do |line|
        /^\d+:\s*\/\// =~ line ||     # Skip comments
          /ALLOW_CONSOLE_LOG/ =~ line # and lines with ALLOW_CONSOLE_LOG
      end.join("\n")
      staged.each { |s| output = s.filter_string(output) }
      return (output.empty? ? :good : :bad), output
    end

    CSS_LINTER_PATH = File.join(SCRIPTS_PATH, 'csslint-rhino.js')
    def check_css_linter
      staged = staged_files('css')
      return :good, nil if staged.empty?

      return :warn, "Rhino is not installed" unless in_path? 'rhino'

      paths = staged.map { |s| s.path }.join(' ')

      output = `rhino #{CSS_LINTER_PATH} --quiet --format=compact #{paths} | grep 'Error - '`
      staged.each { |s| output = s.filter_string(output) }
      return (output !~ /Error - (?!Unknown @ rule)/ ? :good : :bad), output
    end

    RESTRICTED_PATHS = %w[
      vendor
    ]
    def check_restricted_paths
      RESTRICTED_PATHS.each do |path|
        if !system("git diff --cached --quiet -- #{path}")
          return :stop, "changes staged under #{path}"
        end
      end
      return :good
    end

    def check_ruby_syntax
      clean = true
      output = []
      staged_files('rb').each do |staged|
        syntax = `ruby -c #{staged.path} 2>&1`
        unless $? == 0
          output += staged.filter_string(syntax).to_a
          clean = false
        end
      end
      return (clean ? :good : :bad), output
    end

    # catches trailing whitespace, conflict markers etc
    def check_whitespace
      output = `git diff --check --cached`
      return ($?.exitstatus.zero? ? :good : :stop), output
    end

    def check_yaml_syntax
      clean = true
      output = []
      modified_files('yml').each do |file|
        staged = StagedFile.new(file)
        begin
          YAML.load_file(staged.path)
        rescue ArgumentError => e
          output << "#{e.message} parsing #{file}"
          clean = false
        end
      end
      return (clean ? :good : :bad), output
    end

    TEST_RESULTS_FILE = '.spec-results'
    def check_test_history
      output = []
      relevant_tests =
        `relevant-tests -- #{modified_files.join(' ')} > /dev/null 2>&1`.
        split("\n")
      relevant_tests = relevant_tests.map { |r| File.expand_path r }
      unless relevant_tests.any?
        return :warn, 'No relevant tests for this change...write some?'
      end

      begin
        good_tests = File.open(TEST_RESULTS_FILE, 'r').readlines.map do |spec_file|
          File.expand_path spec_file.strip
        end
      rescue Errno::ENOENT
        good_tests = []
      end

      unless good_tests.any?
        return :bad,
          'The relevant tests for this change have not yet been run using `specr`'
      end

      missed_tests = (relevant_tests - good_tests)
      unless missed_tests.empty?
        output << 'The following relevant tests have not been run recently:'
        output << missed_tests.sort
        return :bad, output
      end

      # Find files modified after the tests were run
      test_time = File.mtime(TEST_RESULTS_FILE)
      untested_files = modified_files.reject do |file|
        File.mtime(file) < test_time
      end

      unless untested_files.empty?
        output << 'The following files were modified after `specr` was run.'
        output << '(their associated tests may be broken):'
        output << untested_files.sort
        return :bad, output
      end

      return :good
    end
  end
end
