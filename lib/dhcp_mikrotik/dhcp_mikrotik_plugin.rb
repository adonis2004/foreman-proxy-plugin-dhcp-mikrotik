# frozen_string_literal: true

module Proxy
  module DHCP
    module Mikrotik
      class Plugin < ::Proxy::Provider
        plugin :dhcp_mikrotik, '0.1.1'

    capability 'dhcp_filename_ipv4'
    capability 'dhcp_filename_hostname'

    requires :dhcp, '>= 0'

    default_settings blacklist_duration_minutes: 30 * 60,
                     mikrotik_debug_dump: false

    load_classes 'Proxy::DHCP::Mikrotik::PluginConfiguration'
    load_dependency_injection_wirings 'Proxy::DHCP::Mikrotik::PluginConfiguration'

    start_services :free_ips
      end
    end
  end
end
