class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::ResourcePool
    def self.parse_rp(data)
      mor = data['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

      config = data.fetch_path("summary", "config")
      memory = config["memoryAllocation"]
      cpu = config["cpuAllocation"]
      child_uids = RefreshParser.get_mors(data, 'resourcePool') + RefreshParser.get_mors(data, 'vm')

      # :is_default will be set later as we don't know until we find out who the parent is.

      new_result = {
        :ems_ref               => mor,
        :ems_ref_obj           => mor,
        :uid_ems               => mor,
        :name                  => URI.decode(data["name"].to_s),
        :vapp                  => mor.vimType == "VirtualApp",

        :memory_reserve        => memory["reservation"],
        :memory_reserve_expand => memory["expandableReservation"].to_s.downcase == "true",
        :memory_limit          => memory["limit"],
        :memory_shares         => memory.fetch_path("shares", "shares"),
        :memory_shares_level   => memory.fetch_path("shares", "level"),

        :cpu_reserve           => cpu["reservation"],
        :cpu_reserve_expand    => cpu["expandableReservation"].to_s.downcase == "true",
        :cpu_limit             => cpu["limit"],
        :cpu_shares            => cpu.fetch_path("shares", "shares"),
        :cpu_shares_level      => cpu.fetch_path("shares", "level"),

        :child_uids            => child_uids
      }
    end
  end
end
