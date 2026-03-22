# frozen_string_literal: true

require_relative 'test_helper'

module Proxy
  module DHCP
    module Mikrotik
      class MikrotikClientParsingTest < Test::Unit::TestCase
        def build_client
          PluginConfiguration::MikrotikClient.new('h', 22, 'u', 'p', false, [], debug_dump: false)
        end

        def test_cidr_to_mask
          client = build_client

          assert_equal '255.255.255.0', client.send(:cidr_to_mask, 24)
          assert_equal '255.255.0.0', client.send(:cidr_to_mask, 16)
          assert_equal '255.255.255.255', client.send(:cidr_to_mask, 32)
          assert_equal '0.0.0.0', client.send(:cidr_to_mask, 0)
        end

        def test_parse_records_and_networks
          client = build_client
          text = <<~OUT
            0 name=default address=1.1.1.0/24 gateway=1.1.1.1 dns-server=1.1.1.1,1.1.1.2 domain=example.test boot-file-name=pxelinux.0 next-server=10.0.0.1
            1 name=other address=2.2.2.0/24
          OUT

          client.stubs(:logger).returns(stub(debug: nil, info: nil, warn: nil, error: nil))
          networks = client.send(:parse_networks, text)

          assert_equal 2, networks.size
          network = networks.first
          assert_equal '1.1.1.0', network[:network]
          assert_equal '255.255.255.0', network[:netmask]
          assert_equal ['1.1.1.1'], network[:options][:routers]
          assert_equal ['1.1.1.1', '1.1.1.2'], network[:options][:domain_name_servers]
          assert_equal 'example.test', network[:options][:domain_name]
          assert_equal 'pxelinux.0', network[:options][:filename]
          assert_equal '10.0.0.1', network[:options][:nextServer]
        end

        def test_server_for_ip_selection
          client = build_client
          client.stubs(:list_networks).returns(
            [
              { network: '1.1.1.0', netmask: '255.255.255.0', server: 'srvA' },
              { network: '2.2.2.0', netmask: '255.255.255.0' }
            ]
          )
          client.stubs(:list_servers).returns(%w[srvA srvB])

          assert_equal 'srvA', client.send(:server_for_ip, '1.1.1.10')

          client.stubs(:list_networks).returns(
            [
              { network: '2.2.2.0', netmask: '255.255.255.0' }
            ]
          )
          client.stubs(:list_servers).returns(['onlyOne'])
          assert_equal 'onlyOne', client.send(:server_for_ip, '2.2.2.10')
        end

        def test_ensure_option_set_builds_names
          client = build_client
          client.stubs(:option_exists?).returns(false)
          client.stubs(:option_set_exists?).returns(false)

          captured = []
          client.stubs(:ssh).with do |args|
            captured << args.join(' ')
            true
          end

          name = client.send(:ensure_option_set_for_options, { nextServer: '10.1.1.1', filename: 'pxelinux.0' }, 'host01')
          assert_match(/^mtik-set-/, name)
          assert(captured.any? { |cmd| cmd.include?('/ip dhcp-server option add') })
          assert(captured.any? { |cmd| cmd.include?('/ip dhcp-server option-set add') })
        end

        def test_option_definitions_include_routeros_encodings_for_supported_options
          client = build_client
          definitions = client.send(:option_definitions_for, {
                                      hostname: 'host01',
                                      nextServer: '10.1.1.1',
                                      filename: 'ztp.cfg/HOST.cfg',
                                      ztp_vendor: 'huawei',
                                      ztp_firmware: { core: 'images/firmware.cc', web: 'images/web.7z' }
                                    }, 'host01')

          codes = definitions.map { |definition| definition[:code] }
          assert_includes codes, 12
          assert_includes codes, 66
          assert_includes codes, 67
          assert_includes codes, 143
          assert_includes codes, 150
        end

        def test_option_definitions_build_sunw_vendor_payload
          client = build_client
          definitions = client.send(:option_definitions_for, {
                                      '<SPARC-Enterprise-T5120>root_server_ip' => '192.168.122.24',
                                      '<SPARC-Enterprise-T5120>install_path' => '/Solaris/install'
                                    }, 'host01')

          vendor_definition = definitions.find { |definition| definition[:code] == 43 }
          assert_not_nil vendor_definition
          assert_match(/^0x/i, vendor_definition[:value])
        end

        def test_invalid_vendor_options_raise_clear_error
          client = build_client

          error = assert_raise(::Proxy::DHCP::Error) do
            client.send(:option_definitions_for, { '<Some-Vendor>mystery_option' => 'value' }, 'host01')
          end

          assert_match(/Unsupported vendor options/, error.message)
        end

        def test_custom_known_hosts_file_is_applied_to_ssh_options
          client = PluginConfiguration::MikrotikClient.new(
            'h',
            22,
            'u',
            'p',
            false,
            [],
            debug_dump: false,
            host_key_verification: 'always',
            known_hosts_file: '/tmp/known_hosts'
          )
          options = client.send(:ssh_options)

          assert_equal :always, options[:verify_host_key]
          assert_equal ['/tmp/known_hosts'], options[:user_known_hosts_file]
          assert_equal [], options[:global_known_hosts_file]
        end
      end
    end
  end
end
