# frozen_string_literal: true

require_relative "../model"

# The PVM kernel of a pvm-tier host (docs/byoh/NO_KVM.md section 6.7):
# where its install stands, and what the install recorded so that it can
# be undone (the stock GRUB entry and kernel).
class ByohPvmHost < Sequel::Model
  unrestrict_primary_key

  many_to_one :vm_host

  # The states before the host first boots its PVM kernel: its probe
  # still shows the stock kernel (ByohVirtTiers.accepts_probe?).
  PRE_BOOT_STATES = %w[install_pending installing armed].freeze
end

# Table: byoh_pvm_host
# Columns:
#  vm_host_id              | uuid                     | PRIMARY KEY
#  state                   | text                     | NOT NULL
#  install                 | boolean                  | NOT NULL
#  host_kver               | text                     |
#  stock_entry             | text                     |
#  stock_kver              | text                     |
#  host_deb_sha256         | text                     |
#  lockdown                | text                     |
#  meltdown                | text                     |
#  last_error              | text                     |
#  updated_at              | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
#  upgrade_host_deb_sha256 | text                     |
# Indexes:
#  byoh_pvm_host_pkey | PRIMARY KEY btree (vm_host_id)
# Check constraints:
#  byoh_pvm_host_deb_sha256_check              | (host_deb_sha256 ~ '^[0-9a-f]{64}$'::text)
#  byoh_pvm_host_state_check                   | (state = ANY (ARRAY['install_pending'::text, 'installing'::text, 'armed'::text, 'committed'::text, 'failed'::text, 'upgrade_pending'::text, 'uninstalled'::text]))
#  byoh_pvm_host_upgrade_host_deb_sha256_check | (upgrade_host_deb_sha256 ~ '^[0-9a-f]{64}$'::text)
# Foreign key constraints:
#  byoh_pvm_host_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id) ON DELETE CASCADE
