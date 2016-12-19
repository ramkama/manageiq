class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::CustomizationSpec
    def self.parse_customization_spec(spec_inv)
      {
        :name             => spec_inv["name"].to_s,
        :typ              => spec_inv["type"].to_s,
        :description      => spec_inv["description"].to_s,
        :last_update_time => spec_inv["lastUpdateTime"].to_s,
        :spec             => spec_inv["spec"]
      }
    end
  end
end
