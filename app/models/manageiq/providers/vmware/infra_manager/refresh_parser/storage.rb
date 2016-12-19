class ManageIQ::Providers::Vmware::InfraManager
  module RefreshParser::Storage
    def self.parse_storage(storage_inv)
      mor = storage_inv['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

      summary = storage_inv["summary"]
      return if summary.nil?

      capability = storage_inv["capability"]

      loc = uid = normalize_storage_uid(storage_inv)

      new_result = {
        :ems_ref            => mor,
        :ems_ref_obj        => mor,
        :name               => summary["name"],
        :store_type         => summary["type"].to_s.upcase,
        :total_space        => summary["capacity"],
        :free_space         => summary["freeSpace"],
        :uncommitted        => summary["uncommitted"],
        :multiplehostaccess => summary["multipleHostAccess"].to_s.downcase == "true",
        :location           => loc,
      }

      unless capability.nil?
        new_result.merge!(
          :directory_hierarchy_supported => capability['directoryHierarchySupported'].blank? ? nil : capability['directoryHierarchySupported'].to_s.downcase == 'true',
          :thin_provisioning_supported   => capability['perFileThinProvisioningSupported'].blank? ? nil : capability['perFileThinProvisioningSupported'].to_s.downcase == 'true',
          :raw_disk_mappings_supported   => capability['rawDiskMappingsSupported'].blank? ? nil : capability['rawDiskMappingsSupported'].to_s.downcase == 'true'
        )
      end

      return new_result, uid
    end

    def self.normalize_storage_uid(inv)
      ############################################################################
      # For VMFS, we will use the GUID as the identifier
      ############################################################################

      # VMFS has the GUID in the url:
      #   From VC4:  sanfs://vmfs_uuid:49861d7d-25f008ac-ffbf-001b212bed24/
      #   From VC5:  ds:///vmfs/volumes/49861d7d-25f008ac-ffbf-001b212bed24/
      #   From ESX4: /vmfs/volumes/49861d7d-25f008ac-ffbf-001b212bed24
      url = inv.fetch_path('summary', 'url').to_s.downcase
      return $1 if url =~ /([0-9a-f]{8}-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{12})/

      ############################################################################
      # For NFS on VC5, we will use the "half GUID" as the identifier
      # For other NFS, we will use a path as the identifier in the form: ipaddress/path/parts
      ############################################################################

      # NFS on VC5 has the "half GUID" in the url:
      #   ds:///vmfs/volumes/18f2f698-aae589d5/
      return $1 if url[0, 5] == "ds://" && url =~ /([0-9a-f]{8}-[0-9a-f]{8})/

      # NFS on VC has a path in the url:
      #   netfs://192.168.254.80//shares/public/
      return url[8..-1].gsub('//', '/').chomp('/') if url[0, 8] == "netfs://"

      # NFS on ESX has the path in the datastore instead:
      #   192.168.254.80:/shares/public
      datastore = inv.fetch_path('summary', 'datastore').to_s.downcase
      return datastore.gsub(':/', '/') if datastore =~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/

      # For anything else, we return the url
      url
    end
  end
end
