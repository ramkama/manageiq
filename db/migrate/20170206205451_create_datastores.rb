class CreateDatastores < ActiveRecord::Migration[5.0]
  def change
    create_table :datastores do |t|
      t.bigint :ems_id
      t.string :ems_ref
      t.string :ems_ref_obj
      t.string :name
      t.bigint :storage_id

      t.timestamps
    end
  end
end
