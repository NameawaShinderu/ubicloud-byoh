# frozen_string_literal: true

module Hosting
  class CapabilityMissing < StandardError; end

  class Base
    IpInfo = Struct.new(:ip_address, :source_host_ip, :is_failover, keyword_init: true)

    CAPABILITIES = %i[ip_pull reimage hw_reset rdns set_server_name key_mgmt].freeze

    def initialize(host_provider)
      @host = host_provider
    end

    def pull_ips
      raise NotImplementedError
    end

    def pull_dc(_server_id)
      raise NotImplementedError
    end

    def get_main_ip4(_server_id = nil)
      raise NotImplementedError
    end

    def reimage(_server_id, **_opts)
      raise CapabilityMissing, "#{self.class} does not support reimage"
    end

    def reset(_server_id)
      raise CapabilityMissing, "#{self.class} does not support hardware reset"
    end

    def set_server_name(_server_id, _name)
      raise CapabilityMissing, "#{self.class} does not support renaming"
    end

    def add_key(_name, _key)
      nil
    end

    def delete_key(_key)
      nil
    end

    def capabilities
      Set.new
    end
  end
end
