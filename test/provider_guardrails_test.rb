# frozen_string_literal: true

require_relative 'test_helper'
require 'dhcp_mikrotik/dhcp_mikrotik_main'

module Proxy
  module DHCP
    module Mikrotik
      class ProviderGuardrailsTest < Test::Unit::TestCase
        def build_provider_with(client:, subnets: [{ network: '1.1.1.0', netmask: '255.255.255.0', options: {} }])
          prov = Provider.new('1.1.1.0', client, nil, nil)
          prov.stubs(:subnets).returns(subnets.map { |h| ::Proxy::DHCP::Subnet.new(h[:network], h[:netmask], h[:options] || {}) })
          prov
        end

        def test_add_record_ip_outside_subnet_raises
          client = mock('client')
          prov = build_provider_with(client: client)
          # Avoid collision lookups from base before our guardrail raises
          prov.stubs(:find_records_by_ip).returns([])
          prov.stubs(:find_record_by_mac).returns(nil)
          body = { 'name' => 'host', 'ip' => '1.1.2.10', 'mac' => '00:11:22:33:44:55', 'network' => '1.1.1.0' }
          assert_raise(::Proxy::DHCP::Error) { prov.add_record(body) }
        end

        def test_subnets_honor_managed_subnet_filter
          client = mock('client')
          client.expects(:list_networks).returns([
            { network: '1.1.1.0', netmask: '255.255.255.0', options: {} },
            { network: '2.2.2.0', netmask: '255.255.255.0', options: {} }
          ])

          prov = Provider.new('router', client, nil, ['2.2.2.0/255.255.255.0'], nil)
          prov.stubs(:logger).returns(stub(debug: nil, info: nil, warn: nil, error: nil))

          assert_equal ['2.2.2.0'], prov.subnets.map(&:network)
        end

        def test_add_record_ignores_conflicts_for_related_macs
          client = mock('client')
          client.expects(:create_static_lease).returns(true)
          prov = build_provider_with(client: client)

          related_record = ::Proxy::DHCP::Reservation.new(
            'host-01',
            '1.1.1.10',
            '00:11:22:33:44:66',
            ::Proxy::DHCP::Subnet.new('1.1.1.0', '255.255.255.0'),
            hostname: 'host-01'
          )

          prov.stubs(:find_records_by_ip).returns([related_record])
          prov.stubs(:find_record_by_mac).returns(nil)

          body = {
            'name' => 'host-02',
            'ip' => '1.1.1.10',
            'mac' => '00:11:22:33:44:55',
            'network' => '1.1.1.0',
            'related_macs' => ['00:11:22:33:44:66']
          }

          assert_nothing_raised { prov.add_record(body) }
        end
      end
    end
  end
end
