# frozen_string_literal: true

module Coverband
  module RailsEagerLoad
    def eager_load!
      Coverband.eager_loading_coverage!
      super
    end
  end
  Rails::Engine.prepend(RailsEagerLoad)

  class Railtie < Rails::Railtie
    initializer "coverband.configure" do |app|
      app.middleware.use Coverband::BackgroundMiddleware
    rescue Redis::CannotConnectError => error
      Coverband.configuration.logger.info "Redis is not available (#{error}), Coverband not configured"
      Coverband.configuration.logger.info "If this is a setup task like assets:precompile feel free to ignore"
    end

    config.after_initialize do
      require "coverband/integrations/sidekiq" if defined?(::Sidekiq) # Ensure Sidekiq integration is loaded

      unless Coverband.tasks_to_ignore?
        Coverband.configure unless Coverband.configured?
        Coverband.eager_loading_coverage!
        Coverband.report_coverage
        Coverband.runtime_coverage!
      end

      if defined?(::Sidekiq)
        Sidekiq.configure_client do |config|
          config.client_middleware do |chain|
            chain.add Coverband::Integrations::SidekiqClientMiddleware
          end
        end

        Sidekiq.configure_server do |config|
          config.server_middleware do |chain|
            chain.add Coverband::Integrations::SidekiqServerMiddleware
          end
        end
      end

      Coverband.configuration.railtie!
    end

    config.before_configuration do
      unless ENV["COVERBAND_DISABLE_AUTO_START"]
        begin
          Coverband.configure unless Coverband.configured?
          Coverband.start
        rescue Redis::CannotConnectError => error
          Coverband.configuration.logger.info "Redis is not available (#{error}), Coverband not configured"
          Coverband.configuration.logger.info "If this is a setup task like assets:precompile feel free to ignore"
        end
      end
    end

    rake_tasks do
      load "coverband/utils/tasks.rb"
    end
  end
end
