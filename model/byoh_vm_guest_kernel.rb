# frozen_string_literal: true

require_relative "../model"

# The guest kernel a PVM VM boots, by sha256, with the console its
# config gives it.
class ByohVmGuestKernel < Sequel::Model
  unrestrict_primary_key
end

# Table: byoh_vm_guest_kernel
# Columns:
#  vm_id   | uuid | PRIMARY KEY
#  sha256  | text | NOT NULL
#  release | text |
#  console | text | NOT NULL
# Indexes:
#  byoh_vm_guest_kernel_pkey | PRIMARY KEY btree (vm_id)
# Check constraints:
#  byoh_vm_guest_kernel_console_check | (console = ANY (ARRAY['ttyS0'::text, 'hvc0'::text]))
#  byoh_vm_guest_kernel_sha256_check  | (sha256 ~ '^[0-9a-f]{64}$'::text)
# Foreign key constraints:
#  byoh_vm_guest_kernel_vm_id_fkey | (vm_id) REFERENCES vm(id) ON DELETE CASCADE
