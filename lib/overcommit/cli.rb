require 'optparse'

module Overcommit
  # Responsible for parsing command-line options and executing appropriate
  # application logic based on those options.
  class CLI
    def initialize(arguments, logger)
      @arguments = arguments
      @log       = logger
      @options   = {}
    end

    def parse_arguments
      @parser = OptionParser.new do |opts|
        opts.banner = "Usage: #{opts.program_name} [options] [target-repo]"

        opts.on_tail('-h', '--help', 'Show this message') do
          print_help opts.help
        end

        opts.on_tail('-v', '--version', 'Show version') do
          print_version(opts.program_name)
        end

        opts.on('--uninstall', 'Remove Overcommit hooks from a repository') do
          @options[:uninstall] = true
        end

        opts.on('--install', 'Install Overcommit hooks in a repository') do
          @options[:install] = true
        end
      end

      begin
        @parser.parse!(@arguments)

        # Unconsumed arguments are our targets
        @options[:targets] = @arguments
      rescue OptionParser::InvalidOption => ex
        print_help @parser.help, ex
      end
    end

    def run
      if Array(@options[:targets]).empty?
        @options[:targets] = [Overcommit::Utils.repo_root].compact
        if @options[:targets].empty?
          log.warning 'You are not in a git repository.'
          log.log 'You must either specify the path to a repository or ' <<
                  'change your current directory to a repository.'
          halt 64 # EX_USAGE
        end
      end

      @options[:targets].each do |target|
        begin
          Installer.new(@options, target, log).run
        rescue Overcommit::Exceptions::InvalidGitRepo => error
          log.warning "Skipping #{target}: #{error}"
        end
      end
    end

  private

    attr_reader :log

    def print_help(message, error = nil)
      log.error "#{error}\n" if error
      log.log message
      halt(error ? 64 : 0) # 64 = EX_USAGE
    end

    def print_version(program_name)
      log.log "#{program_name} #{Overcommit::VERSION}"
      halt
    end

    # Used for ease of stubbing in tests
    def halt(status = 0)
      exit status
    end
  end
end
