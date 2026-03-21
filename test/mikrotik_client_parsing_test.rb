# frozen_string_literal: true

require_relative 'test_helper'

module Proxy
  module DHCP
    module Mikrotik
      class MikrotikClientParsingTest < Test::Unit::TestCase
        def build_client
          PluginConfiguration::MikrotikClient.new('h', 22, 'u', 'p', false, [], false)
        end

        def test_cidr_to_mask
          c = build_client
          assert_equal '255.255.255.0', c.send(:cidr_to_mask, 24)
          assert_equal '255.255.0.0', c.send(:cidr_to_mask, 16)
          assert_equal '255.255.255.255', c.send(:cidr_to_mask, 32)
          assert_equal '0.0.0.0', c.send(:cidr_to_mask, 0)
        end

        def test_parse_records_and_networks
          c = build_client
          text = <<~OUT
            0 name=default address=1.1.1.0/24 gateway=1.1.1.1 dns-server=1.1.1.1 boot-file-name=pxelinux.0 next-server=10.0.0.1
            1 name=other address=2.2.2.0/24
          OUT
          c.stubs(:logger).returns(stub(debug: nil, info: nil, warn: nil, error: nil))
          nets = c.send(:parse_networks, text)
          assert_equal 2, nets.size
          n0 = nets[0]
          assert_equal '1.1.1.0', n0[:network]
          assert_equal '255.255.255.0', n0[:netmask]
          assert_equal 'pxelinux.0', n0[:options][:filename]
          assert_equal '10.0.0.1', n0[:options][:nextServer]
        end

        def test_server_for_ip_selection
          c = build_client
          # Stub list_networks and list_servers
          c.stubs(:list_networks).returns([
            { network: '1.1.1.0', netmask: '255.255.255.0', server: 'srvA' },
            { network: '2.2.2.0', netmask: '255.255.255.0' }
          ])
          c.stubs(:list_servers).returns(%w[srvA srvB])

          assert_equal 'srvA', c.send(:server_for_ip, '1.1.1.10')
          # No per-network server, fall back to single? list has 2 -> nil without configured servers
          c.stubs(:list_networks).returns([
            { network: '2.2.2.0', netmask: '255.255.255.0' }
          ])
          c.stubs(:list_servers).returns(['onlyOne'])
          assert_equal 'onlyOne', c.send(:server_for_ip, '2.2.2.10')
        end

        def test_ensure_option_set_builds_names
          c = build_client
          # Prevent SSH calls; just assert helper build path calls
          c.stubs(:option_exists?).returns(false)
          c.stubs(:option_set_exists?).returns(false)
          captured = []
          c.stubs(:ssh).with do |args|
            captured << args.join(' ')
            true
          end
          name = c.send(:ensure_pxe_option_set, nextServer: '10.1.1.1', filename: 'pxelinux.0')
          assert_match(/^pxe-10\.1\.1\.1-pxelinux\.0$/, name)
          assert(captured.any? { |cmd| cmd.include?('/ip dhcp-server option add') })
          assert(captured.any? { |cmd| cmd.include?('/ip dhcp-server option-set add') })
        end
      end
    end
  end
end
