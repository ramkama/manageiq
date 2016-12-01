class AddStorageToEventStreams < ActiveRecord::Migration[5.0]
  def change
    add_column :event_streams, :storage_id, :bigint
    add_column :event_streams, :storage_name, :string
  end
end
