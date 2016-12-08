class ManageIQ::Providers::Vmware::InfraManager::SkeletalRefreshWorker < MiqWorker
  require_nested :Runner

  include PerEmsWorkerMixin

  self.required_roles = ["ems_inventory"]

  def self.ems_class
    parent
  end

  def friendly_name
    @friendly_name ||= begin
      ems = ext_management_system
      ems.nil? ? queue_name.titleize : "Skeletal Refresh Worker for #{ui_lookup(:table => "ext_management_systems")}: #{ems.name}"
    end
  end

  def self.normalized_type
    @normalized_type ||= "ems_skeletal_refresh_worker"
  end
end
