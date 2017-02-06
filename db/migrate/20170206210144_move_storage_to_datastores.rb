class MoveStorageToDatastores < ActiveRecord::Migration[5.0]
  class Datastore < ActiveRecord::Base
  end
  class Host < ActiveRecord::Base
    self.inheritance_column = :_type_disabled # disable STI
  end
  class HostStorage < ActiveRecord::Base
  end
  class Storage < ActiveRecord::Base
  end

  def up
    host_storages = HostStorage.uniq do |hs|
      ems_id = Host.find(hs.host_id).ems_id
      [ems_id, hs.ems_ref]
    end

    host_storages.each do |hs|
      ems_id = Host.find(hs.host_id).ems_id
      storage_name = Storage.find(hs.storage_id).name

      Datastore.create!(:ems_id => ems_id, :ems_ref => hs.ems_ref, :name => storage_name, :storage_id => hs.storage_id)
    end

    remove_column :storages, :name
    remove_column :storages, :ems_ref
    remove_column :storages, :ems_ref_obj
  end

  def down
    add_column :storages, :name, :string
    add_column :storages, :ems_ref, :string
    add_column :storages, :ems_ref_obj, :string
  end
end
