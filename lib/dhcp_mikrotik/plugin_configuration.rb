# frozen_string_literal: true

require 'ipaddr'
require 'net/ssh'
require 'timeout'

module Proxy
  module DHCP
    module Mikrotik
      class PluginConfiguration
    # SSH-based Mikrotik client (RouterOS CLI parsing)
    class MikrotikClient
      include ::Proxy::Log

      def initialize(host, port, username, password, use_tls, servers, debug_dump = false)
        @host = host
        @port = (port && port.to_i > 0) ? port.to_i : 22
        @username = username
        @password = password
        @use_tls = use_tls
        @servers = Array(servers)
        @debug_dump = !!debug_dump
        @server_cache = nil
      end

      def list_networks
        logger.debug('MikrotikClient#list_networks: start')
        return [] unless connection_ready?
        out = ssh(%w[/ip dhcp-server network print detail without-paging])
        debug_log_output('list_networks', out)
        nets = parse_networks(out)
        logger.debug("MikrotikClient#list_networks: parsed=#{nets.size}")
        nets
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
        filtered = leases.select { |l| ip_in_subnet?(l[:ip], subnet) }
        logger.debug("MikrotikClient#list_leases: parsed=#{leases.size} filtered=#{filtered.size}")
        filtered
      rescue StandardError => e
        logger.warn("Mikrotik list_leases failed: #{e.message}")
        []
      end

      def find_lease_by_mac(subnet, mac)
        logger.debug("MikrotikClient#find_lease_by_mac: subnet=#{subnet} mac=#{mac}")
        mac_d = mac&.downcase
        r = list_leases(subnet).find { |l| l[:mac]&.downcase == mac_d }
        logger.debug("MikrotikClient#find_lease_by_mac: found=#{!r.nil?}")
        r
      end

      def find_leases_by_ip(subnet, ip)
        logger.debug("MikrotikClient#find_leases_by_ip: subnet=#{subnet} ip=#{ip}")
        rs = list_leases(subnet).select { |l| l[:ip] == ip }
        logger.debug("MikrotikClient#find_leases_by_ip: count=#{rs.size}")
        rs
      end

      def create_static_lease(reservation, pxe_options = {})
        logger.debug("MikrotikClient#create_static_lease: ip=#{reservation.ip} mac=#{reservation.mac}")
        return false unless connection_ready?
        server_arg = server_for_ip(reservation.ip)
        if server_arg.nil?
          sv = list_servers
          raise ::Proxy::DHCP::Error, 'Unable to determine DHCP server for reservation; multiple servers present' if sv.size > 1
        end
        option_set = ensure_pxe_option_set(pxe_options)
        args = ['/ip', 'dhcp-server', 'lease', 'add',
                "address=#{reservation.ip}",
                "mac-address=#{reservation.mac}"]
        args << "server=#{server_arg}" if server_arg
        args << "comment=#{quote(reservation.name)}" if reservation.name
        args << "dhcp-option=#{option_set}" if option_set
        # PXE per-lease requires option sets; not implemented yet
        out = ssh(args)
        if out && out.downcase.include?('failure')
          raise ::Proxy::DHCP::Error, "RouterOS error when creating lease: #{out.strip}"
        end
        true
      rescue StandardError => e
        logger.error("Mikrotik create_static_lease failed: #{e.message}")
        raise
      end

      def delete_lease(record)
        logger.debug("MikrotikClient#delete_lease: ip=#{record.respond_to?(:ip) ? record.ip : nil} mac=#{record.respond_to?(:mac) ? record.mac : nil}")
        return false unless connection_ready?
        # Try by address+mac first, then by address, then by mac
        conds = []
        conds << %[address=#{record.ip} and mac-address=#{record.mac}] if record.respond_to?(:ip) && record.respond_to?(:mac)
        conds << %[address=#{record.ip}] if record.respond_to?(:ip)
        conds << %[mac-address=#{record.mac}] if record.respond_to?(:mac)
        conds.each do |where|
          ssh(['/ip', 'dhcp-server', 'lease', 'remove', %$[find where #{where}]$])
        end
        true
      rescue StandardError => e
        logger.warn("Mikrotik delete_lease failed: #{e.message}")
        false
      end

      # Returns [from_ip, to_ip] or nil
      def subnet_pool_range(subnet)
        logger.debug("MikrotikClient#subnet_pool_range: subnet=#{subnet}")
        return nil unless connection_ready?
        net = find_network(subnet)
        return nil unless net && net[:pool]
        po = ssh(["/ip", "pool", "print", "detail", "without-paging", "where", "name=#{net[:pool]}"])
        debug_log_output('subnet_pool_range', po)
        ranges = parse_pool_ranges(po)
        ranges&.first
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
          Net::SSH.start(@host, @username,
                         password: @password,
                         port: @port,
                         non_interactive: true,
                         timeout: 5,
                         verify_host_key: :never) do |ssh|
            ch = ssh.open_channel do |channel|
              channel.exec(cmd) do |_, success|
                raise 'Failed to execute command' unless success
                channel.on_data { |_, data| out << data }
                channel.on_extended_data { |_, _, data| out << data }
              end
            end
            ch.wait
          end
        end
        logger.debug("MikrotikClient#ssh: received bytes=#{out.bytesize}")
        out
      end

      def parse_records(text)
        # Merge wrapped lines; new record starts with optional spaces + digits
        records = []
        current = String.new
        text.each_line do |ln|
          if ln =~ /^\s*\d+\s/ || (current.empty? && ln.strip != '')
            records << current unless current.empty?
            current = ln.strip
          else
            current << ' ' << ln.strip
          end
        end
        records << current unless current.empty?
        parsed = records.map do |rec|
          h = {}
          rec.scan(/(\w[\w\-]*?)=([^\s]+)/).each do |k, v|
            h[k.downcase.to_sym] = v
          end
          h
        end
        logger.debug("MikrotikClient#parse_records: records=#{records.size} parsed=#{parsed.size}")
        parsed
      end

      def quote(val)
        return '""' if val.nil? || val == ''
        '"' + val.to_s.gsub('"','\"') + '"'
      end

      def quote_single(val)
        return "''" if val.nil? || val == ''
        "'" + val.to_s.gsub("'","\\'") + "'"
      end

      # Ensure PXE option-set exists for nextServer (66) and filename (67)
      # Returns option-set name or nil if no PXE options provided
      def ensure_pxe_option_set(pxe_options)
        ns = pxe_options && (pxe_options[:nextServer] || pxe_options['nextServer'])
        fn = pxe_options && (pxe_options[:filename] || pxe_options['filename'])
        return nil if ns.nil? && fn.nil?

        # Build stable names based on values
        parts = []
        opt_names = []
        if ns
          opt66 = "pxe66-#{sanitize_name(ns)}"
          ensure_option(opt66, 66, quote_single(ns))
          opt_names << opt66
          parts << sanitize_name(ns)
        end
        if fn
          opt67 = "pxe67-#{sanitize_name(fn)}"
          ensure_option(opt67, 67, quote_single(fn))
          opt_names << opt67
          parts << sanitize_name(fn)
        end

        set_name = "pxe-#{parts.join('-')}"
        ensure_option_set(set_name, opt_names)
        set_name
      end

      def option_exists?(name)
        out = ssh(["/ip","dhcp-server","option","print","detail","without-paging","where","name=#{name}"])
        recs = parse_records(out)
        !recs.empty?
      end

      def ensure_option(name, code, value_quoted)
        return if option_exists?(name)
        ssh(["/ip","dhcp-server","option","add","name=#{name}","code=#{code}","value=#{value_quoted}"])
      end

      def option_set_exists?(name)
        out = ssh(["/ip","dhcp-server","option-set","print","detail","without-paging","where","name=#{name}"])
        recs = parse_records(out)
        !recs.empty?
      end

      def ensure_option_set(name, option_names)
        return if option_set_exists?(name)
        ssh(["/ip","dhcp-server","option-set","add","name=#{name}","options=#{option_names.join(',')}"])
      end

      def sanitize_name(s)
        s.to_s.gsub(/[^A-Za-z0-9_\-\.]/, '_')[0, 50]
      end

      def list_servers
        return @server_cache if @server_cache
        return [] unless connection_ready?
        out = ssh(%w[/ip dhcp-server print detail without-paging])
        debug_log_output('list_servers', out)
        names = parse_records(out).map { |h| h[:name] }.compact
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
          logger.debug("MikrotikClient##{kind}: bytes=#{out.bytesize} sample='#{out.strip[0,200].gsub(/\n/, ' ')}'")
        end
      end

      def parse_networks(text)
        parse_records(text).map do |h|
          cidr = h[:address]
          next unless cidr
          ip, prefix = cidr.split('/')
          netmask = cidr_to_mask(prefix.to_i)
          {
            network: ip,
            netmask: netmask,
            options: build_network_options(h),
            pool: h[:'address-pool'],
            server: (h[:'dhcp-server'] || h[:server])
          }
        end.compact
      end

      def build_network_options(h)
        opts = {}
        opts[:nextServer] = h[:'next-server'] if h[:'next-server']
        opts[:filename] = h[:'boot-file-name'] if h[:'boot-file-name']
        opts
      end

      def parse_leases(text)
        parse_records(text).map do |h|
          {
            ip: h[:address],
            mac: h[:'mac-address']&.downcase,
            hostname: h[:'host-name'],
            static: (h[:dynamic] == 'no'),
            server: h[:server]
          }
        end.compact.select { |l| l[:ip] && l[:mac] }
      end

      def parse_pool_ranges(text)
        recs = parse_records(text)
        return nil if recs.empty?
        ranges = recs.first[:ranges]
        return nil unless ranges
        ranges.split(',').map do |rng|
          parts = rng.split('-', 2)
          [parts[0], parts[1]] if parts.size == 2
        end.compact
      end

      def find_network(subnet)
        list_networks.find { |n| n[:network] == subnet }
      end

      def ip_in_subnet?(ip, subnet)
        n = list_networks.find { |s| s[:network] == subnet }
        return false unless n
        IPAddr.new("#{n[:network]}/#{n[:netmask]}").include?(IPAddr.new(ip))
      end

      def server_for_ip(ip)
        # Always try to auto-map server without constraints
        # 1) If a network covering IP has an explicit server, use it
        net = list_networks.find do |n|
          begin
            IPAddr.new("#{n[:network]}/#{n[:netmask]}").include?(IPAddr.new(ip))
          rescue StandardError
            false
          end
        end
        return net[:server] if net && net[:server]
        # 2) If exactly one server exists on router, use it
        sv = list_servers
        return sv.first if sv.size == 1
        # 3) If user configured servers, prefer the first as tie-breaker
        return @servers.first unless @servers.empty?
        # 4) Otherwise, let RouterOS default selection apply (nil)
        nil
      end

      def cidr_to_mask(prefix)
        p = prefix.to_i
        p = [[p, 0].max, 32].min
        mask = (0xffffffff << (32 - p)) & 0xffffffff
        [24, 16, 8, 0].map { |b| ((mask >> b) & 255) }.join('.')
      end
    end

    def load_dependency_injection_wirings(container, settings)
      container.singleton_dependency :free_ips, -> { ::Proxy::DHCP::FreeIps.new(settings[:blacklist_duration_minutes]) }
      container.dependency :mtik_client, (lambda do
        ::Proxy::DHCP::Mikrotik::PluginConfiguration::MikrotikClient.new(
          settings[:host], settings[:port], settings[:username], settings[:password], settings[:use_tls], settings[:servers], settings[:mikrotik_debug_dump]
        )
      end)
      container.dependency :dhcp_provider, (lambda do
        ::Proxy::DHCP::Mikrotik::Provider.new(
          settings[:server],
          container.get_dependency(:mtik_client),
          settings[:servers],
          settings[:subnets],
          container.get_dependency(:free_ips)
        )
      end)
    end

    def load_classes
      require 'dhcp_common/server'
      require 'dhcp_common/free_ips'
      require 'dhcp_mikrotik/dhcp_mikrotik_main'
    end
      end
    end
  end
end
