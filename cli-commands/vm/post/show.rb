# frozen_string_literal: true

class UbiCli
  on("vm").run_on("show") do
    desc "Show details for a virtual machine"

    fields = %w[id name state location size unix-user storage-size-gib boot-image ip6 ip4-enabled ip4 ip4-scope ip4-internal private-ipv4 private-ipv6 subnet maintenance-window-start-at firewalls].freeze.each(&:freeze)
    # Only lower-tier VMs (docs/byoh/NO_KVM.md) have virt-tier. It shows
    # after boot-image and -f takes it, but the help does not list it, so
    # the help of every other user stays as it was (U1).
    all_fields = fields.dup.insert(fields.index("boot-image") + 1, "virt-tier").freeze
    # Only VMs on BYOH hosts have these, so other VMs show what they did
    # before unless the fields are asked for.
    byoh_fields = %w[virt-tier ip4-scope ip4-internal].freeze.each(&:freeze)
    firewall_fields = %w[id name description location path firewall-rules].freeze.each(&:freeze)
    firewall_rule_fields = %w[id cidr port-range protocol].freeze.each(&:freeze)

    options("ubi vm (location/vm-name | vm-id) show [options]", key: :vm_show) do
      on("-f", "--fields=fields", "show specific fields (comma separated)")
      on("-r", "--rule-fields=fields", "show specific firewall rule fields (comma separated)")
      on("-w", "--firewall-fields=fields", "show specific firewall fields (comma separated)")
    end
    help_option_values("Fields:", fields)
    help_option_values("Firewall Rule Fields:", firewall_rule_fields)
    help_option_values("Firewall Fields:", firewall_fields)

    run do |opts, cmd|
      data = sdk_object.info
      opts = opts[:vm_show]
      keys = check_fields(opts[:fields], all_fields, "vm show -f option", cmd)
      keys -= byoh_fields.reject { data.values.key?(it.tr("-", "_").to_sym) } unless opts[:fields]
      firewall_keys = check_fields(opts[:"firewall-fields"], firewall_fields, "vm show -w option", cmd)
      firewall_rule_keys = check_fields(opts[:"rule-fields"], firewall_rule_fields, "vm show -r option", cmd)

      body = []

      firewall_keys = underscore_keys(firewall_keys)
      firewall_rule_keys = underscore_keys(firewall_rule_keys)
      each_with_dashed(underscore_keys(keys)) do |key, display_key|
        case key
        when :firewalls
          data[key].each_with_index do |firewall, i|
            body << "firewall " << (i + 1).to_s << ":\n"
            each_with_dashed(firewall_keys) do |fw_key, display_fw_key|
              if fw_key == :firewall_rules
                body << "  rules:\n"
                firewall[fw_key].each_with_index do |rule, i|
                  body << "    " << (i + 1).to_s << ": "
                  firewall_rule_keys.each do |fwr_key|
                    body << rule[fwr_key].to_s << "  "
                  end
                  body << "\n"
                end
              else
                body << "  " << display_fw_key << ": " << firewall[fw_key].to_s << "\n"
              end
            end
          end
        when :subnet
          body << display_key << ": " << data[key].name << "\n"
        when :virt_tier
          if (tier = data[key])
            body << display_key << ": " << tier[:tier] << " (experimental) " << tier[:description] << "\n"
            body << "  host-kernel: " << tier[:host_kernel] << "\n" if tier[:host_kernel]
            if (guest = tier[:guest_kernel])
              body << "  guest-kernel: " << (guest[:release] || "unknown release") << " sha256 " << guest[:sha256] << " config " << (guest[:config_checked] ? "checked" : "unchecked") << "\n"
            end
          else
            body << display_key << ": \n"
          end
        else
          body << display_key << ": " << data[key].to_s << "\n"
        end
      end

      response(body)
    end
  end
end
