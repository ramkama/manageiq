class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::Cluster
    def self.parse_cluster(data)
      mor = data['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

      config = data["configuration"]
      das_config = config["dasConfig"]
      drs_config = config["drsConfig"]

      effective_cpu = data.fetch_path("summary", "effectiveCpu")
      effective_cpu = effective_cpu.blank? ? nil : effective_cpu.to_i
      effective_memory = data.fetch_path("summary", "effectiveMemory")
      effective_memory = effective_memory.blank? ? nil : effective_memory.to_i.megabytes

      new_result = {
        :ems_ref                 => mor,
        :ems_ref_obj             => mor,
        :uid_ems                 => mor,
        :name                    => data["name"],
        :effective_cpu           => effective_cpu,
        :effective_memory        => effective_memory,

        :ha_enabled              => das_config["enabled"].to_s.downcase == "true",
        :ha_admit_control        => das_config["admissionControlEnabled"].to_s.downcase == "true",
        :ha_max_failures         => das_config["failoverLevel"],

        :drs_enabled             => drs_config["enabled"].to_s.downcase == "true",
        :drs_automation_level    => drs_config["defaultVmBehavior"],
        :drs_migration_threshold => drs_config["vmotionRate"],

        :child_uids              => RefreshParser.get_mors(data, 'resourcePool')
      }
    end
  end
end
