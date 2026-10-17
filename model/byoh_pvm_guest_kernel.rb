# frozen_string_literal: true

require_relative "../model"

# A PVM guest kernel (vmlinux) that a pvm host downloaded, or is
# downloading, by the sha256 of a location pin.
class ByohPvmGuestKernel < Sequel::Model
  unrestrict_primary_key
end

# Table: byoh_pvm_guest_kernel
# Primary Key: (vm_host_id, sha256)
# Columns:
#  vm_host_id     | uuid                     |
#  sha256         | text                     |
#  state          | text                     | NOT NULL
#  release        | text                     |
#  console        | text                     |
#  config_checked | boolean                  | NOT NULL DEFAULT false
#  updated_at     | timestamp with time zone | NOT NULL DEFAULT CURRENT_TIMESTAMP
# Indexes:
#  byoh_pvm_guest_kernel_pkey | PRIMARY KEY btree (vm_host_id, sha256)
# Check constraints:
#  byoh_pvm_guest_kernel_console_check | (console = ANY (ARRAY['ttyS0'::text, 'hvc0'::text]))
#  byoh_pvm_guest_kernel_sha256_check  | (sha256 ~ '^[0-9a-f]{64}$'::text)
#  byoh_pvm_guest_kernel_state_check   | (state = ANY (ARRAY['downloading'::text, 'ready'::text, 'refused'::text]))
# Foreign key constraints:
#  byoh_pvm_guest_kernel_vm_host_id_fkey | (vm_host_id) REFERENCES vm_host(id) ON DELETE CASCADE
