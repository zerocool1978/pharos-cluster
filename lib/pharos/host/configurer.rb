# frozen_string_literal: true

module Pharos
  module Host
    class Configurer
      attr_reader :host

      SCRIPT_LIBRARY = File.join(__dir__, '..', 'scripts', 'pharos.sh').freeze

      def self.load_configurers
        Dir.glob(File.join(__dir__, '**', '*.rb')).each { |f| require(f) }
      end

      # @return [Array]
      def self.configurers
        @configurers ||= []
      end

      # @param [Pharos::Configuration::OsRelease]
      # @return [Class<Configurer>, NilClass]
      def self.for_os_release(os_release)
        configurers.find { |configurer| configurer.supported_os?(os_release) }
      end

      def initialize(host)
        @host = host
      end

      def config
        host.config
      end

      def transport
        host.transport
      end

      def install_essentials
        abstract_method!
      end

      def configure_repos
        abstract_method!
      end

      def configure_netfilter
        abstract_method!
      end

      def configure_cfssl
        abstract_method!
      end

      # @return [Array<String>]
      def kubelet_args
        []
      end

      # @param args [Hash]
      def ensure_kubelet(args) # rubocop:disable Lint/UnusedMethodArgument
        abstract_method!
      end

      # @param args [Hash]
      def install_kube_packages(args) # rubocop:disable Lint/UnusedMethodArgument
        abstract_method!
      end

      # @param version [String]
      def upgrade_kubeadm(version) # rubocop:disable Lint/UnusedMethodArgument
        abstract_method!
      end

      def configure_container_runtime!
        cleanup_needed = !host.new? && !custom_docker? && !configure_container_runtime_safe?
        unless cleanup_needed
          configure_container_runtime
          return
        end

        return unless docker?

        cleanup_docker! do
          configure_container_runtime
        end
      end

      def configure_container_runtime
        abstract_method!
      end

      def configure_container_runtime_safe?
        abstract_method!
      end

      def configure_firewalld
        abstract_method!
      end

      def reset
        abstract_method!
      end

      # @return [Array<Pharos::Config::Repository>]
      def default_repositories
        abstract_method!
      end

      # @return [Array<Pharos::Config::Repository>]
      def host_repositories
        return default_repositories if host.repositories.nil? || host.repositories.empty?

        host.repositories
      end

      # @param path [Array]
      # @return [String]
      def script_path(*path)
        File.join(__dir__, host.os_release.id, 'scripts', *path)
      end

      # @return [String]
      def script_library_install_path
        "/usr/local/share/pharos"
      end

      def configure_script_library
        transport.exec("sudo mkdir -p #{script_library_install_path}")
        transport.file("#{script_library_install_path}/util.sh").write(
          File.read(SCRIPT_LIBRARY)
        )
      end

      # @param script [String] name of file under ../scripts/
      def exec_script(script, vars = {})
        transport.exec_script!(
          script,
          env: (host.environment || {}).merge(vars),
          path: script_path(script)
        )
      end

      def docker?
        host.docker?
      end

      def custom_docker?
        host.custom_docker?
      end

      def containerd?
        host.containerd?
      end

      # Return stringified json array(ish) for insecure registries properly escaped for safe
      # passing to scripts via ENV.
      #
      # @return [String]
      def insecure_registries
        # docker & custom docker
        JSON.dump(config.container_runtime.insecure_registries).inspect
      end

      # @return [Pharos::Transport::TransportFile]
      def env_file
        transport.file('/etc/environment')
      end

      def update_env_file
        return if host.environment.nil? || host.environment.empty?

        host_env_file = env_file
        original_data = {}
        if host_env_file.exist?
          host_env_file.read.lines.each do |line|
            line.strip!
            next if line.start_with?('#')

            key, val = line.split('=', 2)
            val&.delete_suffix!('"') if val&.delete_prefix!('"')
            val = nil if val.to_s.empty?
            original_data[key] = val
          end
        end

        new_content = host.environment.merge(original_data) { |_key, old_val, _new_val| old_val }.compact.map do |key, val|
          "#{key}=\"#{val.shellescape}\""
        end
        host_env_file.write(new_content.join("\n") + "\n")
      end

      # @return [Boolean]
      def can_pull?
        transport.exec("sudo crictl pull #{config.image_repository}/pause:3.1").success?
      end

      def cleanup_docker!
        transport.exec!("sudo systemctl stop kubelet")
        transport.exec!("sudo docker stop $(sudo docker ps -q)")
        transport.exec!("sudo docker rm -f $(sudo docker ps -a -q)")
        yield
      ensure
        transport.exec!("sudo systemctl start kubelet")
      end

      class << self
        # @param component [Hash]
        def register_component(component)
          supported_os_releases.each do |os|
            Pharos::Phases.register_component(component.merge(os_release: os))
          end
        end

        # @return [Array<Pharos::Configuration::OsRelease>]
        def supported_os_releases
          @supported_os_releases ||= []
        end

        # @param [Pharos::Configuration::OsRelease]
        # @return [Boolean]
        def supported_os?(os_release)
          supported_os_releases.any? { |release| release.id == os_release.id && release.version == os_release.version }
        end

        def register_config(name, version)
          supported_os_releases << Pharos::Configuration::OsRelease.new(id: name, version: version)
          Pharos::Host::Configurer.configurers << self
          self
        end
      end

      private

      def abstract_method!
        raise NotImplementedError, 'This is an abstract base method. Implement in your subclass.'
      end
    end
  end
end
