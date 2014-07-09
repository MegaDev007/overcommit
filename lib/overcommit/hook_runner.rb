# encoding: utf-8

module Overcommit
  # Responsible for loading the hooks the repository has configured and running
  # them, collecting and displaying the results.
  class HookRunner
    # @param config [Overcommit::Configuration]
    # @param logger [Overcommit::Logger]
    # @param context [Overcommit::HookContext]
    # @param input [Overcommit::UserInput]
    def initialize(config, logger, context, input)
      @config = config
      @log = logger
      @context = context
      @input = input
      @hooks = []
    end

    # Loads and runs the hooks registered for this {HookRunner}.
    def run
      @context.setup_environment
      load_hooks
      run_hooks
    ensure
      @context.cleanup_environment
    end

  private

    attr_reader :log

    def run_hooks
      if @hooks.any? { |hook| hook.run? || hook.skip? }
        log.bold "Running #{hook_script_name} hooks"

        interrupted = false

        statuses = @hooks.map do |hook|
          hook_status = run_hook(hook)

          if hook_status == :interrupted
            # Stop running any more hooks and assume a bad result
            interrupted = true
            break [:bad]
          end

          hook_status
        end.compact

        log.log # Newline

        run_failed = statuses.include?(:bad)

        if interrupted
          log.warning '⚠  Hook run interrupted by user'
        elsif run_failed
          log.error "✗ One or more #{hook_script_name} hooks failed"
        else
          log.success "✓ All #{hook_script_name} hooks passed"
        end

        log.log # Newline

        !run_failed
      else
        log.success "✓ No applicable #{hook_script_name} hooks to run"
        true # Run was successful
      end
    end

    def run_hook(hook)
      return if should_skip?(hook)

      unless hook.quiet?
        print_header(hook)
      end

      begin
        status, output = hook.run
      rescue => ex
        status = :bad
        output = "Hook raised unexpected error\n#{ex.message}"
      end

      # Want to print the header in the event the result wasn't good so that the
      # user knows what failed
      if hook.quiet? && status != :good
        print_header(hook)
      end

      print_result(hook, status, output)

      status
    rescue Interrupt
      print_result(hook, :interrupted, nil)
      :interrupted
    end

    def print_header(hook)
      log.partial hook.description
      log.partial '.' * (70 - hook.description.length)
    end

    def should_skip?(hook)
      return true unless hook.enabled?

      if hook.skip?
        if hook.required?
          log.warning "Cannot skip #{hook.name} since it is required"
        else
          log.warning "Skipping #{hook.name}"
          return true
        end
      end

      !hook.run?
    end

    def print_result(hook, status, output)
      case status
      when :good
        log.success 'OK' unless hook.quiet?
      when :warn
        log.warning 'WARNING'
        print_report(output, :bold_warning)
      when :bad
        log.error 'FAILED'
        print_report(output, :bold_error)
      when :interrupted
        log.error 'INTERRUPTED'
        log.bold_error('Hook was interrupted by Ctrl-C; restoring repo state...')
      end
    end

    def print_report(output, format = :log)
      log.send(format, output) unless output.nil? || output.empty?
    end

    def load_hooks
      require "overcommit/hook/#{@context.hook_type_name}/base"

      @hooks += HookLoader::BuiltInHookLoader.new(@config, @context, @log, @input).load_hooks

      # Load plugin hooks after so they can subclass existing hooks
      @hooks += HookLoader::PluginHookLoader.new(@config, @context, @log, @input).load_hooks
    end

    def hook_script_name
      @context.hook_script_name
    end
  end
end
