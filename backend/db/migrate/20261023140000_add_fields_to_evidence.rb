# Which of a record's fields a quote backs (#398): a company's or plant's
# own evidence ("Headquarters: Bethesda") can then mark that one row, not
# the whole record. Null means "about the record" (older evidence, and all
# link and tag evidence, whose subject already is the fact).
class AddFieldsToEvidence < ActiveRecord::Migration[8.1]
  def change
    add_column :evidence, :fields, :string, array: true
    # Added unvalidated, so this short transaction never scans evidence under
    # its lock; the next migration validates it.
    add_check_constraint :evidence, "fields IS NULL OR cardinality(fields) > 0", name: "evidence_fields_check", validate: false
  end
end
