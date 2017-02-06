class Datastore < ApplicationRecord
  include SerializedEmsRefObjMixin

  belongs_to :ext_management_system, :foreign_key => "ems_id"
  belongs_to :storage
end
