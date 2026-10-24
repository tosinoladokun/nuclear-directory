# Validates the check #398 added unvalidated: a scan that takes only a
# SHARE UPDATE EXCLUSIVE lock, so evidence stays readable and writable.
class ValidateEvidenceFieldsCheck < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :evidence, name: "evidence_fields_check"
  end
end
