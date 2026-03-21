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
      ips.each do |ip|
        validate_ip(ip, 4)
      end
    end

    def subnets
      logger.debug('DHCP::Mikrotik::Provider#subnets: querying networks')
      networks = client.list_networks
      logger.debug("DHCP::Mikrotik::Provider#subnets: networks=#{networks.size}")
      Array(networks).map do |n|
        network = n.is_a?(Hash) ? n[:network] : (n.respond_to?(:network) ? n.network : nil)
        netmask = n.is_a?(Hash) ? n[:netmask] : (n.respond_to?(:netmask) ? n.netmask : nil)
        options = n.is_a?(Hash) ? n[:options] : (n.respond_to?(:options) ? n.options : {})
        next unless managed_subnet?("#{network}/#{netmask}")
        ::Proxy::DHCP::Subnet.new(network, netmask, options || {})
      end.compact
    end

    def all_hosts(subnet_address)
      logger.debug("DHCP::Mikrotik::Provider#all_hosts subnet=#{subnet_address}")
      leases = client.list_leases(subnet_address)
      Array(leases).select { |l| lease_static?(l) }.map { |l| build_reservation(l, subnet_address) }.compact
    end

    def all_leases(subnet_address)
      logger.debug("DHCP::Mikrotik::Provider#all_leases subnet=#{subnet_address}")
      leases = client.list_leases(subnet_address)
      Array(leases).reject { |l| lease_static?(l) }.map { |l| build_lease(l, subnet_address) }.compact
    end

    def find_subnet(subnet_address)
      subnets.find { |s| s.network == subnet_address }
    end

    def get_subnet(subnet_address)
      find_subnet(subnet_address) || raise(Proxy::DHCP::SubnetNotFound.new("No such subnet: %s" % [subnet_address]))
    end

    def find_record_by_mac(subnet_address, mac_address)
      l = client.find_lease_by_mac(subnet_address, mac_address)
      return nil if l.nil?
      lease_static?(l) ? build_reservation(l, subnet_address) : build_lease(l, subnet_address)
    end

    def find_records_by_ip(subnet_address, ip)
      ls = client.find_leases_by_ip(subnet_address, ip)
      Array(ls).map { |l| lease_static?(l) ? build_reservation(l, subnet_address) : build_lease(l, subnet_address) }.compact
    end

    def add_record(options = {})
      # Largely mirrors base implementation, but uses client-backed subnet lookups
      related_macs = options.delete('related_macs') || []
      name, ip_address, mac_address, subnet_address, opts = send(:clean_up_add_record_parameters, options.dup)

      validate_mac(mac_address)
      raise(::Proxy::DHCP::Error, 'Must provide hostname') unless name

      subnet = find_subnet(subnet_address) || raise(::Proxy::DHCP::Error, "No Subnet detected for: #{subnet_address}")
      raise(::Proxy::DHCP::Error, 'DHCP implementation does not support Vendor Options') if vendor_options_included?(opts) && !vendor_options_supported?

      to_return = ::Proxy::DHCP::Reservation.new(name, ip_address, mac_address, subnet, opts.merge!(hostname: name))

      # collision check using Mikrotik-backed finders
      similar_records = find_similar_records(subnet.network, ip_address, mac_address).reject do |record|
        related_macs.include?(record.mac)
      end
      if similar_records.any? { |r| r == to_return }
        raise ::Proxy::DHCP::AlreadyExists
      end
      unless similar_records.empty?
        raise ::Proxy::DHCP::Collision, "Record #{subnet.network}/#{ip_address} already exists"
      end

      # Guardrail: ensure IP ∈ subnet
      unless IPAddr.new("#{subnet.network}/#{subnet.netmask}").include?(IPAddr.new(ip_address))
        raise ::Proxy::DHCP::Error, "IP #{ip_address} not in subnet #{subnet.network}/#{subnet.netmask}"
      end

      pxe_opts = {}
      pxe_opts[:nextServer] = options[:nextServer] if options[:nextServer]
      pxe_opts[:filename] = options[:filename] if options[:filename]
      client.create_static_lease(to_return, pxe_opts)
      to_return
    end

    # Use client-backed lookups for collision detection
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

      # If mac already has a record within range, reuse its IP
      if mac_address
        r = find_record_by_mac(subnet_address, mac_address)
        if r
          r_ip = r.ip
          if range_cover?(from_final, to_final, r_ip)
            logger.debug "Found existing record for #{mac_address} within range; reusing #{r_ip}."
            return r_ip
          end
        end
      end

      free_ips.find_free_ip(from_final, to_final, all_hosts(subnet_address) + all_leases(subnet_address))
    end

    private

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
      logger.debug("Skipping a reservation as it failed validation: '%s'" % [lease.inspect])
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
      logger.debug("Skipping a lease as it failed validation: '%s'" % [lease.inspect])
      nil
    end

    def reservation_subnet(subnet_address)
      mask = subnet_netmask(subnet_address)
      ::Proxy::DHCP::Subnet.new(subnet_address, mask)
    end

    def subnet_netmask(subnet_address)
      s = subnets.find { |sn| sn.network == subnet_address }
      s&.netmask
    end

    def value_from(obj, key)
      return obj[key] if obj.is_a?(Hash)
      obj.respond_to?(key) ? obj.public_send(key) : nil
    end

    def adjusted_range(subnet_address, from_address, to_address, dhcp_range)
      if dhcp_range && dhcp_range.size == 2
        dhcp_from, dhcp_to = dhcp_range
        if from_address && to_address
          from = max_ip(from_address, dhcp_from)
          to = min_ip(to_address, dhcp_to)
        else
          from = dhcp_from
          to = dhcp_to
        end
      else
        if from_address && to_address
          from = from_address
          to = to_address
        else
          # Derive from full subnet range
          mask = subnet_netmask(subnet_address)
          if mask
            net = IPAddr.new("#{subnet_address}/#{mask}")
            from = (net.to_range.first + 1).to_s
            to = (net.to_range.last - 1).to_s
          else
            raise ::Proxy::DHCP::NotImplemented, 'Unable to determine address range without Mikrotik pool range or netmask.'
          end
        end
      end
      [from, to]
    end

    def range_cover?(from, to, ip)
      (IPAddr.new(from)..IPAddr.new(to)).cover?(IPAddr.new(ip))
    end

    def max_ip(a, b)
      (IPAddr.new(a).to_i >= IPAddr.new(b).to_i) ? a : b
    end

    def min_ip(a, b)
      (IPAddr.new(a).to_i <= IPAddr.new(b).to_i) ? a : b
    end
      end
    end
  end
end
