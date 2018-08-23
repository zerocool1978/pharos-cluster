# frozen_string_literal: true

require 'dry-validation'
require 'fugit'

require_relative 'addons/struct'
require_relative 'logging'

module Pharos
  class Addon
    include Pharos::Logging

    # @param name [String]
    # @return [Pharos::Addon]
    def self.inherited(klass)
      super
      klass.addon_location(File.dirname(caller.first[/(.+?)\:\d/, 1]))
      klass.addon_name(klass.name[/.*::(.*)/, 1].gsub(/([a-z\d])([A-Z])/, "\1-\2").downcase) if klass.name

      Pharos::AddonManager.addons << klass
    end

    # return class for use as superclass in Dry::Validation.Params
    Schema = Dry::Validation.Schema(build: false) do
      configure do
        def duration?(value)
          !Fugit::Duration.parse(value).nil?
        end

        def cron?(value)
          cron = Fugit::Cron.parse(value)

          return false if !cron
          return false if cron.seconds != [0]

          true
        end

        def self.messages
          super.merge(
            en: { errors: {
              duration?: 'is not valid duration',
              cron?: 'is not a valid crontab'
            } }
          )
        end
      end

      required(:enabled).filled(:bool?)
    end

    class << self
      # @return [String]
      def addon_location(dir = nil)
        if dir
          @addon_location = dir
        else
          @addon_location = __dir__
        end
      end

      def addon_name(name = nil)
        if name
          @addon_name = name
        else
          @addon_name
        end
      end

      def version(version = nil)
        if version
          @version = version
        else
          @version
        end
      end

      def license(license = nil)
        if license
          @license = license
        else
          @license
        end
      end

      def to_h
        { name: addon_name, version: version, license: license }
      end

      def config_schema(&block)
        @schema = Dry::Validation.Params(Schema, &block)
      end

      def config(&block)
        @config ||= Class.new(Pharos::Addons::Struct, &block)
      end

      def config?
        !@config.nil?
      end

      def custom_type(&block)
        Class.new(Pharos::Addons::Struct, &block)
      end

      # @return [Hash]
      def hooks
        @hooks ||= {}
      end

      def install(&block)
        hooks[:install] = block
      end

      def uninstall(&block)
        hooks[:uninstall] = block
      end

      def validation
        Dry::Validation.Params(Schema) { yield }
      end

      # @param config [Hash]
      def validate(config)
        if @schema
          @schema.call(config)
        else
          validation {}.call(config)
        end
      end
    end

    attr_reader :config, :cpu_arch, :cluster_config, :kube_client

    # @param config [Hash,Dry::Validation::Result]
    # @param enabled [Boolean]
    # @param kube_client [K8s::Client]
    # @param cpu_arch [String, NilClass]
    # @param cluster_config [Pharos::Config, NilClass]
    def initialize(config = nil, enabled: true, kube_client:, cpu_arch:, cluster_config:)
      @config = self.class.config? ? self.class.config.new(config) : RecursiveOpenStruct.new(Hash(config))
      @enabled = enabled
      @kube_client = kube_client
      @cpu_arch = cpu_arch
      @cluster_config = cluster_config
    end

    def name
      self.class.addon_name
    end

    def duration
      Fugit::Duration
    end

    def enabled?
      @enabled
    end

    def apply
      if enabled?
        apply_install
      else
        apply_uninstall
      end
    end

    def hooks
      self.class.hooks
    end

    def apply_install
      if hooks[:install]
        instance_eval(&hooks[:install])
      else
        apply_resources
      end
    end

    def apply_uninstall
      if hooks[:uninstall]
        instance_eval(&hooks[:uninstall])
      else
        delete_resources
      end
    end

    # @param vars [Hash]
    # @return [Pharos::Kube::Stack]
    def kube_stack(**vars)
      Pharos::Kube.stack(
        name,
        File.join(self.class.addon_location, 'resources'),
        name: name,
        version: self.class.version,
        config: config,
        arch: cpu_arch,
        **vars
      )
    end

    # @param vars [Hash]
    # @return [Array<K8s::Resource>]
    def apply_resources(**vars)
      kube_stack(vars).apply(kube_client)
    end

    # @return [Array<K8s::Resource>]
    def delete_resources
      Pharos::Kube::Stack.new(name).delete(kube_client)
    end

    def validate; end
  end
end
