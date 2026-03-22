# frozen_string_literal: true

require 'ipaddr'

module Proxy
  module DHCP
    module Mikrotik
      class Provider < ::Proxy::DHCP::Server
        attr_reader :client, :servers

        def initialize(server, client, servers, managed_subnets = nil, free_ips_service = nil)
          @client = client
          @servers = servers || []
          super(server, managed_subnets, nil, free_ips_service)
        end

        def validate_supported_address(*ips)
          ips.each { |ip| validate_ip(ip, 4) }
        end

        def subnets
          logger.debug('DHCP::Mikrotik::Provider#subnets: querying networks')
          networks = client.list_networks
          logger.debug("DHCP::Mikrotik::Provider#subnets: networks=#{networks.size}")

          Array(networks).filter_map do |network|
            address = network_value(network, :network)
            netmask = network_value(network, :netmask)
            options = network_value(network, :options) || {}
            next unless managed_subnet?("#{address}/#{netmask}")

            ::Proxy::DHCP::Subnet.new(address, netmask, options)
          end
        end

        def all_hosts(subnet_address)
          logger.debug("DHCP::Mikrotik::Provider#all_hosts subnet=#{subnet_address}")
          leases = client.list_leases(subnet_address)
          Array(leases).select { |lease| lease_static?(lease) }.filter_map { |lease| build_reservation(lease, subnet_address) }
        end

        def all_leases(subnet_address)
          logger.debug("DHCP::Mikrotik::Provider#all_leases subnet=#{subnet_address}")
          leases = client.list_leases(subnet_address)
          Array(leases).reject { |lease| lease_static?(lease) }.filter_map { |lease| build_lease(lease, subnet_address) }
        end

        def find_subnet(subnet_address)
          subnets.find { |subnet| subnet.network == subnet_address }
        end

        def get_subnet(subnet_address)
          find_subnet(subnet_address) || raise(Proxy::DHCP::SubnetNotFound, format('No such subnet: %s', subnet_address))
        end

        def find_record_by_mac(subnet_address, mac_address)
          lease = client.find_lease_by_mac(subnet_address, mac_address)
          return nil if lease.nil?

          lease_static?(lease) ? build_reservation(lease, subnet_address) : build_lease(lease, subnet_address)
        end

        def find_records_by_ip(subnet_address, ip)
          leases = client.find_leases_by_ip(subnet_address, ip)
          Array(leases).filter_map do |lease|
            lease_static?(lease) ? build_reservation(lease, subnet_address) : build_lease(lease, subnet_address)
          end
        end

        def add_record(options = {})
          related_macs = Array(options.delete('related_macs') || options.delete(:related_macs))
          name, ip_address, mac_address, subnet_address, reservation_options = clean_up_add_record_parameters(options.dup)

          validate_mac(mac_address)
          raise(::Proxy::DHCP::Error, 'Must provide hostname') unless name

          subnet = find_subnet(subnet_address) || raise(::Proxy::DHCP::Error, "No Subnet detected for: #{subnet_address}")
          normalized_options = reservation_options.merge(hostname: name)
          reservation = ::Proxy::DHCP::Reservation.new(name, ip_address, mac_address, subnet, normalized_options)

          similar_records = find_similar_records(subnet.network, ip_address, mac_address).reject do |record|
            related_macs.include?(record.mac)
          end

          raise(::Proxy::DHCP::AlreadyExists) if similar_records.any? { |record| record == reservation }
          raise(::Proxy::DHCP::Collision, "Record #{subnet.network}/#{ip_address} already exists") unless similar_records.empty?

          unless IPAddr.new("#{subnet.network}/#{subnet.netmask}").include?(IPAddr.new(ip_address))
            raise ::Proxy::DHCP::Error, "IP #{ip_address} not in subnet #{subnet.network}/#{subnet.netmask}"
          end

          client.create_static_lease(reservation, normalized_options)
          reservation
        end

        def find_similar_records(subnet_address, ip_address, mac_address)
          records = []
          records << find_records_by_ip(subnet_address, ip_address)
          records << find_record_by_mac(subnet_address, mac_address)
          records.flatten.compact.uniq
        end

        def del_record(record)
          client.delete_lease(record)
        end

        def unused_ip(subnet_address, mac_address, from_address, to_address)
          dhcp_range = begin
            client.subnet_pool_range(subnet_address)
          rescue StandardError
            nil
          end

          from_final, to_final = adjusted_range(subnet_address, from_address, to_address, dhcp_range)

          return reused_ip_for_mac(subnet_address, mac_address, from_final, to_final) if mac_address

          free_ips.find_free_ip(from_final, to_final, all_hosts(subnet_address) + all_leases(subnet_address))
        end

        def vendor_options_supported?
          true
        end

        private

        def network_value(network, key)
          return network[key] if network.is_a?(Hash)

          network.respond_to?(key) ? network.public_send(key) : nil
        end

        def lease_static?(lease)
          return lease[:type] == :reservation if lease.is_a?(Hash) && lease.key?(:type)
          return lease[:static] if lease.is_a?(Hash) && lease.key?(:static)

          lease.respond_to?(:static) ? lease.static : false
        end

        def build_reservation(lease, subnet_address)
          name = value_from(lease, :hostname)
          ip = value_from(lease, :ip)
          mac = value_from(lease, :mac)
          subnet = reservation_subnet(subnet_address)
          options = { hostname: name, deleteable: true }

          ::Proxy::DHCP::Reservation.new(name, ip, mac&.downcase, subnet, options)
        rescue StandardError
          logger.debug(format("Skipping a reservation as it failed validation: '%s'", lease.inspect))
          nil
        end

        def build_lease(lease, subnet_address)
          name = value_from(lease, :hostname)
          ip = value_from(lease, :ip)
          mac = value_from(lease, :mac)
          ends = value_from(lease, :ends)
          subnet = reservation_subnet(subnet_address)

          ::Proxy::DHCP::Lease.new(name, ip, mac&.downcase, subnet, nil, ends, nil, {})
        rescue StandardError
          logger.debug(format("Skipping a lease as it failed validation: '%s'", lease.inspect))
          nil
        end

        def reservation_subnet(subnet_address)
          ::Proxy::DHCP::Subnet.new(subnet_address, subnet_netmask(subnet_address))
        end

        def subnet_netmask(subnet_address)
          subnets.find { |subnet| subnet.network == subnet_address }&.netmask
        end

        def value_from(object, key)
          return object[key] if object.is_a?(Hash)

          object.respond_to?(key) ? object.public_send(key) : nil
        end

        def adjusted_range(subnet_address, from_address, to_address, dhcp_range)
          if dhcp_range&.size == 2
            dhcp_from, dhcp_to = dhcp_range
            if from_address && to_address
              [max_ip(from_address, dhcp_from), min_ip(to_address, dhcp_to)]
            else
              [dhcp_from, dhcp_to]
            end
          elsif from_address && to_address
            [from_address, to_address]
          else
            mask = subnet_netmask(subnet_address)
            unless mask
              raise ::Proxy::DHCP::NotImplemented,
                    'Unable to determine address range without Mikrotik pool range or netmask.'
            end

            network = IPAddr.new("#{subnet_address}/#{mask}")
            [(network.to_range.first + 1).to_s, (network.to_range.last - 1).to_s]
          end
        end

        def reused_ip_for_mac(subnet_address, mac_address, from_final, to_final)
          record = find_record_by_mac(subnet_address, mac_address)
          return nil unless record && range_cover?(from_final, to_final, record.ip)

          logger.debug "Found existing record for #{mac_address} within range; reusing #{record.ip}."
          record.ip
        end

        def range_cover?(from, to, ip)
          (IPAddr.new(from)..IPAddr.new(to)).cover?(IPAddr.new(ip))
        end

        def max_ip(left, right)
          IPAddr.new(left).to_i >= IPAddr.new(right).to_i ? left : right
        end

        def min_ip(left, right)
          IPAddr.new(left).to_i <= IPAddr.new(right).to_i ? left : right
        end
      end
    end
  end
end
