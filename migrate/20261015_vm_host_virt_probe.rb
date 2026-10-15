# frozen_string_literal: true

# Where a host stands on the virtualization ladder (docs/byoh/NO_KVM.md),
# as Prog::LearnVirt last found it. NULL until a probe ran; only BYOH
# hosts are probed.
Sequel.migration do
  change do
    alter_table(:vm_host) do
      add_column :virt_probe, :jsonb
    end
  end
end
