# frozen_string_literal: true

require 'digest/sha1'
require 'ipaddr'
require 'net/ssh'
require 'timeout'

module Proxy
  module DHCP
    module Mikrotik
      class PluginConfiguration
        class MikrotikClient
          include ::Proxy::Log

          SUNW_VENDOR_OPTIONS = {
            root_server_ip: { code: 2, kind: :ip },
            root_server_hostname: { code: 3, kind: :string },
            root_path_name: { code: 4, kind: :string },
            install_server_ip: { code: 10, kind: :ip },
            install_server_name: { code: 11, kind: :string },
            install_path: { code: 12, kind: :string },
            sysid_server_path: { code: 13, kind: :string },
            jumpstart_server_path: { code: 14, kind: :string }
          }.freeze

          def initialize(
            host,
            port,
            username,
            password,
            use_tls,
            servers,
            debug_dump: false,
            host_key_verification: 'accept_new',
            known_hosts_file: nil
          )
            @host = host
            @port = port&.to_i&.positive? ? port.to_i : 22
            @username = username
            @password = password
            @use_tls = use_tls
            @servers = Array(servers)
            @debug_dump = debug_dump ? true : false
            @host_key_verification = host_key_verification
            @known_hosts_file = known_hosts_file
            @server_cache = nil
          end

          def list_networks
            logger.debug('MikrotikClient#list_networks: start')
            return [] unless connection_ready?

            out = ssh(%w[/ip dhcp-server network print detail without-paging])
            debug_log_output('list_networks', out)
            networks = parse_networks(out)
            logger.debug("MikrotikClient#list_networks: parsed=#{networks.size}")
            networks
          rescue StandardError => e
            logger.warn("Mikrotik list_networks failed: #{e.message}")
            []
          end

          def list_leases(subnet)
            logger.debug("MikrotikClient#list_leases: start subnet=#{subnet}")
            return [] unless connection_ready?

            out = ssh(%w[/ip dhcp-server lease print detail without-paging])
            debug_log_output('list_leases', out)
            leases = parse_leases(out)
            return leases if subnet.nil? || subnet.to_s.empty?

            filtered = leases.select { |lease| ip_in_subnet?(lease[:ip], subnet) }
            logger.debug("MikrotikClient#list_leases: parsed=#{leases.size} filtered=#{filtered.size}")
            filtered
          rescue StandardError => e
            logger.warn("Mikrotik list_leases failed: #{e.message}")
            []
          end

          def find_lease_by_mac(subnet, mac)
            logger.debug("MikrotikClient#find_lease_by_mac: subnet=#{subnet} mac=#{mac}")
            normalized_mac = mac&.downcase
            record = list_leases(subnet).find { |lease| lease[:mac]&.downcase == normalized_mac }
            logger.debug("MikrotikClient#find_lease_by_mac: found=#{!record.nil?}")
            record
          end

          def find_leases_by_ip(subnet, ip)
            logger.debug("MikrotikClient#find_leases_by_ip: subnet=#{subnet} ip=#{ip}")
            records = list_leases(subnet).select { |lease| lease[:ip] == ip }
            logger.debug("MikrotikClient#find_leases_by_ip: count=#{records.size}")
            records
          end

          def create_static_lease(reservation, options = {})
            logger.debug("MikrotikClient#create_static_lease: ip=#{reservation.ip} mac=#{reservation.mac}")
            return false unless connection_ready?

            server_arg = server_for_ip(reservation.ip)
            if server_arg.nil? && list_servers.size > 1
              raise ::Proxy::DHCP::Error, 'Unable to determine DHCP server for reservation; multiple servers present'
            end

            option_set = ensure_option_set_for_options(options, reservation.name)
            args = [
              '/ip', 'dhcp-server', 'lease', 'add',
              "address=#{reservation.ip}",
              "mac-address=#{reservation.mac}"
            ]
            args << "server=#{server_arg}" if server_arg
            args << "comment=#{quote(reservation.name)}" if reservation.name
            args << "dhcp-option-set=#{option_set}" if option_set

            out = ssh(args)
            raise(::Proxy::DHCP::Error, "RouterOS error when creating lease: #{out.strip}") if out&.downcase&.include?('failure')

            true
          rescue StandardError => e
            logger.error("Mikrotik create_static_lease failed: #{e.message}")
            raise
          end

          def delete_lease(record)
            logger.debug(
              "MikrotikClient#delete_lease: ip=#{record.respond_to?(:ip) ? record.ip : nil} " \
              "mac=#{record.respond_to?(:mac) ? record.mac : nil}"
            )
            return false unless connection_ready?

            conditions = []
            if record.respond_to?(:ip) && record.respond_to?(:mac)
              conditions << "address=#{record.ip} and mac-address=#{record.mac}"
            end
            conditions << "address=#{record.ip}" if record.respond_to?(:ip)
            conditions << "mac-address=#{record.mac}" if record.respond_to?(:mac)

            conditions.each do |where|
              ssh(['/ip', 'dhcp-server', 'lease', 'remove', %([find where #{where}])])
            end
            true
          rescue StandardError => e
            logger.warn("Mikrotik delete_lease failed: #{e.message}")
            false
          end

          def subnet_pool_range(subnet)
            logger.debug("MikrotikClient#subnet_pool_range: subnet=#{subnet}")
            return nil unless connection_ready?

            network = find_network(subnet)
            return nil unless network && network[:pool]

            out = ssh(['/ip', 'pool', 'print', 'detail', 'without-paging', 'where', "name=#{network[:pool]}"])
            debug_log_output('subnet_pool_range', out)
            parse_pool_ranges(out)&.first
          rescue StandardError => e
            logger.debug("Mikrotik subnet_pool_range failed: #{e.message}")
            nil
          end

          private

          def connection_ready?
            if @host.to_s.empty? || @username.to_s.empty?
              logger.debug('Mikrotik host/username not configured; returning empty results')
              return false
            end

            true
          end

          def ssh(cmd_parts)
            cmd = cmd_parts.join(' ')
            out = String.new
            logger.debug("MikrotikClient#ssh: exec '#{cmd}' host=#{@host} port=#{@port} user=#{@username}")

            Timeout.timeout(10) do
              Net::SSH.start(@host, @username, **ssh_options) do |ssh|
                channel = ssh.open_channel do |ch|
                  ch.exec(cmd) do |_, success|
                    raise 'Failed to execute command' unless success

                    ch.on_data { |_, data| out << data }
                    ch.on_extended_data { |_, _, data| out << data }
                  end
                end
                channel.wait
              end
            end

            logger.debug("MikrotikClient#ssh: received bytes=#{out.bytesize}")
            out
          end

          def ssh_options
            options = {
              password: @password,
              port: @port,
              non_interactive: true,
              timeout: 5,
              verify_host_key: normalize_verify_host_key(@host_key_verification)
            }
            return options if @known_hosts_file.to_s.empty?

            options.merge(
              user_known_hosts_file: [@known_hosts_file],
              global_known_hosts_file: []
            )
          end

          def normalize_verify_host_key(value)
            normalized = value.to_s.strip
            normalized = 'accept_new' if normalized.empty?
            normalized.tr!('-', '_')
            normalized = 'always' if normalized == 'strict'
            normalized = 'accept_new_or_local_tunnel' if normalized == 'local_tunnel'

            accepted = %w[never accept_new accept_new_or_local_tunnel always]
            return normalized.to_sym if accepted.include?(normalized)

            raise ::Proxy::DHCP::Error, "Unsupported host_key_verification value '#{value}'. Valid values: #{accepted.join(', ')}"
          end

          def parse_records(text)
            records = []
            current = String.new

            text.each_line do |line|
              if line =~ /^\s*\d+\s/ || (current.empty? && !line.strip.empty?)
                records << current unless current.empty?
                current = line.strip
              else
                current << ' ' << line.strip
              end
            end
            records << current unless current.empty?

            parsed = records.map do |record|
              parsed_record = {}
              record.scan(/(\w[\w-]*?)=([^\s]+)/).each do |key, value|
                parsed_record[key.downcase.to_sym] = value
              end
              parsed_record
            end

            logger.debug("MikrotikClient#parse_records: records=#{records.size} parsed=#{parsed.size}")
            parsed
          end

          def quote(value)
            return '""' if value.nil? || value == ''

            "\"#{value.to_s.gsub('"', '\"')}\""
          end

          def quote_single(value)
            return "''" if value.nil? || value == ''

            "'#{value.to_s.gsub("'", "\\'")}'"
          end

          def ensure_option_set_for_options(options, reservation_name)
            definitions = option_definitions_for(options, reservation_name)
            return nil if definitions.empty?

            definitions.each do |definition|
              ensure_option(definition[:name], definition[:code], definition[:value])
            end

            option_names = definitions.map { |definition| definition[:name] }.sort
            set_name = "mtik-set-#{Digest::SHA1.hexdigest(option_names.join(','))[0, 16]}"
            ensure_option_set(set_name, option_names)
            set_name
          end

          def option_definitions_for(options, reservation_name)
            normalized = normalize_option_values(options, reservation_name)
            definitions = []
            definitions.concat(build_standard_option_definitions(normalized))
            definitions.concat(build_vendor_option_definition(normalized))
            definitions.concat(build_ztp_option_definitions(normalized))
            definitions.uniq { |definition| [definition[:code], definition[:value]] }
          end

          def normalize_option_values(options, reservation_name)
            normalized = options.each_with_object({}) do |(key, value), result|
              result[key.to_sym] = value
            end
            normalized[:hostname] ||= reservation_name
            normalized
          end

          def build_standard_option_definitions(options)
            definitions = []
            definitions << option_definition(12, options[:hostname], :string, 'hostname') if present?(options[:hostname])
            definitions << option_definition(60, options[:PXEClient], :string, 'pxeclient') if present?(options[:PXEClient])
            definitions << option_definition(66, options[:nextServer], :string, 'next-server') if present?(options[:nextServer])
            definitions << option_definition(67, options[:filename], :string, 'filename') if present?(options[:filename])
            definitions
          end

          def build_vendor_option_definition(options)
            vendor_entries = extract_vendor_entries(options)
            return [] if vendor_entries.empty?

            unsupported = vendor_entries.reject { |entry| supported_vendor_entry?(entry) }
            unless unsupported.empty?
              unsupported_keys = unsupported.map { |entry| entry[:original_key] }
              raise ::Proxy::DHCP::Error, "Unsupported vendor options for Mikrotik: #{unsupported_keys.join(', ')}"
            end

            payload = vendor_entries.sort_by { |entry| SUNW_VENDOR_OPTIONS.fetch(entry[:attribute])[:code] }.map do |entry|
              suboption_bytes(entry[:attribute], entry[:value])
            end.join

            [option_definition(43, payload, :raw_bytes, 'vendor43')]
          end

          def build_ztp_option_definitions(options)
            return [] unless options[:filename].to_s.match?(/^ztp\.cfg.*/i)

            definitions = []
            definitions << option_definition(150, options[:nextServer], :ip, 'ztp-server') if present?(options[:nextServer])
            if options[:ztp_vendor].to_s.casecmp('huawei').zero? && options[:ztp_firmware].is_a?(Hash)
              firmware = options[:ztp_firmware]
              if present?(firmware[:core]) && present?(firmware[:web])
                value = "vrpfile=#{firmware[:core]};webfile=#{firmware[:web]};"
                definitions << option_definition(143, value, :string, 'ztp-huawei')
              end
            end
            definitions
          end

          def extract_vendor_entries(options)
            options.each_with_object([]) do |(key, value), entries|
              match = key.to_s.match(/^<([^>]+)>(.*)$/)
              next unless match

              entries << {
                original_key: key.to_s,
                vendor: match[1],
                attribute: match[2].to_sym,
                value: value
              }
            end
          end

          def supported_vendor_entry?(entry)
            entry[:vendor].match?(/sun|sparc|solaris/i) && SUNW_VENDOR_OPTIONS.key?(entry[:attribute])
          end

          def suboption_bytes(attribute, value)
            definition = SUNW_VENDOR_OPTIONS.fetch(attribute)
            payload =
              case definition[:kind]
              when :ip
                ip_bytes(value)
              else
                value.to_s.b
              end

            [definition[:code], payload.bytesize].pack('CC') + payload
          end

          def option_definition(code, value, kind, hint)
            encoded_value = encode_option_value(value, kind)
            {
              name: "mtik-#{code}-#{hint}-#{Digest::SHA1.hexdigest(encoded_value)[0, 12]}",
              code: code,
              value: encoded_value
            }
          end

          def encode_option_value(value, kind)
            case kind
            when :string
              quote_single(value)
            when :ip
              "0x#{ip_bytes(value).unpack1('H*').upcase}"
            when :raw_bytes
              "0x#{value.unpack1('H*').upcase}"
            else
              raise ::Proxy::DHCP::Error, "Unsupported option encoding kind '#{kind}'"
            end
          end

          def ip_bytes(value)
            IPAddr.new(value).hton
          rescue IPAddr::InvalidAddressError
            raise ::Proxy::DHCP::Error, "Expected an IPv4 address for DHCP option value, got '#{value}'"
          end

          def present?(value)
            !value.nil? && value != ''
          end

          def option_exists?(name)
            out = ssh(['/ip', 'dhcp-server', 'option', 'print', 'detail', 'without-paging', 'where', "name=#{name}"])
            !parse_records(out).empty?
          end

          def ensure_option(name, code, encoded_value)
            return if option_exists?(name)

            ssh(['/ip', 'dhcp-server', 'option', 'add', "name=#{name}", "code=#{code}", "value=#{encoded_value}"])
          end

          def option_set_exists?(name)
            out = ssh(['/ip', 'dhcp-server', 'option-set', 'print', 'detail', 'without-paging', 'where', "name=#{name}"])
            !parse_records(out).empty?
          end

          def ensure_option_set(name, option_names)
            return if option_set_exists?(name)

            ssh(['/ip', 'dhcp-server', 'option-set', 'add', "name=#{name}", "options=#{option_names.join(',')}"])
          end

          def list_servers
            return @server_cache if @server_cache
            return [] unless connection_ready?

            out = ssh(%w[/ip dhcp-server print detail without-paging])
            debug_log_output('list_servers', out)
            names = parse_records(out).map { |record| record[:name] }.compact
            @server_cache = names
            names
          rescue StandardError => e
            logger.warn("Mikrotik list_servers failed: #{e.message}")
            []
          end

          def debug_log_output(kind, out)
            return if out.nil?

            if @debug_dump
              logger.debug("MikrotikClient##{kind}: full='#{out.gsub(/\n/, '\\n')}'")
            else
              sample = out.strip[0, 200].gsub(/\n/, ' ')
              logger.debug("MikrotikClient##{kind}: bytes=#{out.bytesize} sample='#{sample}'")
            end
          end

          def parse_networks(text)
            parse_records(text).filter_map do |record|
              cidr = record[:address]
              next unless cidr

              network, prefix = cidr.split('/')
              {
                network: network,
                netmask: cidr_to_mask(prefix.to_i),
                options: build_network_options(record),
                pool: record[:'address-pool'],
                server: record[:'dhcp-server'] || record[:server]
              }
            end
          end

          def build_network_options(record)
            options = {}
            options[:routers] = split_csv_option(record[:gateway]) if present?(record[:gateway])
            options[:domain_name_servers] = split_csv_option(record[:'dns-server']) if present?(record[:'dns-server'])
            options[:ntp_servers] = split_csv_option(record[:'ntp-server']) if present?(record[:'ntp-server'])
            options[:domain_name] = record[:domain] if present?(record[:domain])
            options[:nextServer] = record[:'next-server'] if present?(record[:'next-server'])
            options[:filename] = record[:'boot-file-name'] if present?(record[:'boot-file-name'])
            options
          end

          def split_csv_option(value)
            value.to_s.split(',').map(&:strip).reject(&:empty?)
          end

          def parse_leases(text)
            leases = parse_records(text).map do |record|
              {
                ip: record[:address],
                mac: record[:'mac-address']&.downcase,
                hostname: record[:'host-name'],
                static: record[:dynamic] == 'no',
                server: record[:server]
              }
            end

            leases.select { |lease| lease[:ip] && lease[:mac] }
          end

          def parse_pool_ranges(text)
            records = parse_records(text)
            return nil if records.empty?

            ranges = records.first[:ranges]
            return nil unless ranges

            ranges.split(',').filter_map do |range|
              bounds = range.split('-', 2)
              bounds if bounds.size == 2
            end
          end

          def find_network(subnet)
            list_networks.find { |network| network[:network] == subnet }
          end

          def ip_in_subnet?(ip, subnet)
            network = list_networks.find { |entry| entry[:network] == subnet }
            return false unless network

            IPAddr.new("#{network[:network]}/#{network[:netmask]}").include?(IPAddr.new(ip))
          end

          def server_for_ip(ip)
            network = list_networks.find do |entry|
              IPAddr.new("#{entry[:network]}/#{entry[:netmask]}").include?(IPAddr.new(ip))
            rescue StandardError
              false
            end
            return network[:server] if network && network[:server]

            server_names = list_servers
            return server_names.first if server_names.size == 1
            return @servers.first unless @servers.empty?

            nil
          end

          def cidr_to_mask(prefix)
            length = [[prefix.to_i, 0].max, 32].min
            mask = (0xffffffff << (32 - length)) & 0xffffffff
            [24, 16, 8, 0].map { |bit| (mask >> bit) & 255 }.join('.')
          end
        end

        def load_dependency_injection_wirings(container, settings)
          container.singleton_dependency :free_ips, -> { ::Proxy::DHCP::FreeIps.new(settings[:blacklist_duration_minutes]) }
          container.dependency :mtik_client, lambda {
            ::Proxy::DHCP::Mikrotik::PluginConfiguration::MikrotikClient.new(
              settings[:host],
              settings[:port],
              settings[:username],
              settings[:password],
              settings[:use_tls],
              settings[:servers],
              debug_dump: settings[:mikrotik_debug_dump],
              host_key_verification: settings[:host_key_verification],
              known_hosts_file: settings[:known_hosts_file]
            )
          }
          container.dependency :dhcp_provider, lambda {
            ::Proxy::DHCP::Mikrotik::Provider.new(
              settings[:server],
              container.get_dependency(:mtik_client),
              settings[:servers],
              settings[:subnets],
              container.get_dependency(:free_ips)
            )
          }
        end

        def load_classes
          require 'dhcp_common/dhcp_common'
          require 'dhcp_common/free_ips'
          require 'dhcp_common/server'
          require 'dhcp_mikrotik/dhcp_mikrotik_main'
        end
      end
    end
  end
end
