require 'miq-uuid'

module ManageIQ::Providers
  module Vmware
    module InfraManager::RefreshParser

      #
      # EMS Inventory Parsing
      #

      def self.ems_inv_to_hashes(inv)
        uids = {}
        result = {:uid_lookup => uids}

        result[:storages], uids[:storages] = storage_inv_to_hashes(inv[:storage])
        result[:clusters], uids[:clusters] = cluster_inv_to_hashes(inv[:cluster])
        result[:storage_profiles], uids[:storage_profiles] = storage_profile_inv_to_hashes(inv[:storage_profile], uids[:storages], inv[:storage_profile_datastore])

        result[:hosts], uids[:hosts], uids[:clusters_by_host], uids[:lans], uids[:switches], uids[:guest_devices], uids[:scsi_luns] = host_inv_to_hashes(inv[:host], inv, uids[:storages], uids[:clusters])
        result[:vms], uids[:vms] = vm_inv_to_hashes(
          inv[:vm],
          inv[:storage],
          inv[:storage_profile_entity],
          uids[:storages],
          uids[:storage_profiles],
          uids[:hosts],
          uids[:clusters_by_host],
          uids[:lans]
        )

        result[:folders], uids[:folders] = inv_to_ems_folder_hashes(inv)
        result[:resource_pools], uids[:resource_pools] = rp_inv_to_hashes(inv[:rp])

        result[:customization_specs] = customization_spec_inv_to_hashes(inv[:customization_specs]) if inv.key?(:customization_specs)

        link_ems_metadata(result, inv)
        link_root_folder(result)
        set_hidden_folders(result)
        set_default_rps(result)

        result
      end

      def self.storage_inv_to_hashes(inv)
        result = []
        result_uids = {:storage_id => {}}
        return result, result_uids if inv.nil?

        inv.each do |mor, storage_inv|
          new_result, uid = InfraManager::RefreshParser::Storage.parse_storage(storage_inv)
          next if new_result.nil?

          result << new_result
          result_uids[mor] = new_result
          result_uids[:storage_id][uid] = new_result
        end
        return result, result_uids
      end

      def self.storage_profile_inv_to_hashes(profile_inv, storage_uids, placement_inv)
        result = []
        result_uids = {}

        profile_inv.each do |uid, profile|
          new_result = {
            :ems_ref                  => uid,
            :name                     => profile.name,
            :profile_type             => profile.profileCategory,
            :storage_profile_storages => []
          }

          placement_inv[uid].to_miq_a.each do |placement_hub|
            datastore = storage_uids[placement_hub.hubId] if placement_hub.hubType == "Datastore"
            new_result[:storage_profile_storages] << datastore unless datastore.nil?
          end

          result << new_result
          result_uids[uid] = new_result
        end unless profile_inv.nil?

        return result, result_uids
      end

      def self.host_inv_to_hashes(inv, ems_inv, storage_uids, cluster_uids)
        result = []
        result_uids = {}
        cluster_uids_by_host = {}
        lan_uids = {}
        switch_uids = {}
        guest_device_uids = {}
        scsi_lun_uids = {}
        return result, result_uids, lan_uids, switch_uids, guest_device_uids, scsi_lun_uids if inv.nil?

        dvswitch_by_host    = InfraManager::RefreshParser::Dvswitch.group_dvswitch_by_host(ems_inv[:dvswitch])
        dvportgroup_by_host = InfraManager::RefreshParser::Dvswitch.group_dvportgroup_by_host(ems_inv[:dvportgroup], ems_inv[:dvswitch])
        dvswitch_uid_ems = {}
        dvportgroup_uid_ems = {}

        inv.each do |mor, host_inv|
          new_result = InfraManager::RefreshParser::Host.parse_host(
            host_inv,
            ems_inv,
            storage_uids,
            cluster_uids,
            cluster_uids_by_host,
            lan_uids,
            switch_uids,
            guest_device_uids,
            scsi_lun_uids,
            dvswitch_by_host,
            dvportgroup_by_host,
            dvswitch_uid_ems,
            dvportgroup_uid_ems
          )

          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids, cluster_uids_by_host, lan_uids, switch_uids, guest_device_uids, scsi_lun_uids
      end

      def self.storage_profile_by_entity(storage_profile_entity_inv, storage_profile_uids)
        groupings = {'virtualDiskId' => {}, 'virtualMachine' => {}}
        storage_profile_entity_inv.each do |storage_profile_uid, entities|
          next if storage_profile_uids[storage_profile_uid][:profile_type] == 'RESOURCE'
          entities.each do |entity|
            groupings[entity.objectType][entity.key] = storage_profile_uids[storage_profile_uid]
          end
        end
        [groupings['virtualDiskId'], groupings['virtualMachine']]
      end

      def self.vm_inv_to_hashes(
        inv,
        storage_inv,
        storage_profile_entity_inv,
        storage_uids,
        storage_profile_uids,
        host_uids,
        cluster_uids_by_host,
        lan_uids
      )
        result = []
        result_uids = {}
        guest_device_uids = {}
        return result, result_uids if inv.nil?

        storage_profile_by_disk_mor, storage_profile_by_vm_mor = storage_profile_by_entity(
          storage_profile_entity_inv,
          storage_profile_uids
        )

        inv.each do |mor, vm_inv|
          new_result = InfraManager::RefreshParser::VM.parse_vm(
            vm_inv,
            storage_inv,
            storage_uids,
            storage_profile_uids,
            host_uids,
            cluster_uids_by_host,
            lan_uids,
            guest_device_uids,
            storage_profile_by_disk_mor,
            storage_profile_by_vm_mor
          )

          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.inv_to_ems_folder_hashes(inv)
        result = []
        result_uids = {}

        folder_inv_to_hashes(inv[:folder], result, result_uids)
        datacenter_inv_to_hashes(inv[:dc], result, result_uids)
        storage_pod_inv_to_hashes(inv[:storage_pod], result, result_uids)

        return result, result_uids
      end

      def self.folder_inv_to_hashes(inv, result, result_uids)
        return result, result_uids if inv.nil?

        inv.each do |mor, data|
          mor = data['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

          child_mors = get_mors(data, 'childEntity')

          new_result = {
            :type        => EmsFolder.name,
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => data["name"],
            :child_uids  => child_mors,
            :hidden      => false
          }
          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.datacenter_inv_to_hashes(inv, result, result_uids)
        return result, result_uids if inv.nil?

        inv.each do |mor, data|
          mor = data['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

          child_mors = get_mors(data, 'hostFolder') + get_mors(data, 'vmFolder') + get_mors(data, 'datastoreFolder')

          new_result = {
            :type        => Datacenter.name,
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => data["name"],
            :child_uids  => child_mors,
            :hidden      => false
          }
          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.storage_pod_inv_to_hashes(inv, result, result_uids)
        return result, result_uids if inv.nil?

        inv.each do |mor, data|
          mor = data['MOR'] # Use the MOR directly from the data since the mor as a key may be corrupt

          child_mors = get_mors(data, 'childEntity')
          name       = data.fetch_path('summary', 'name')

          new_result = {
            :type        => StorageCluster.name,
            :ems_ref     => mor,
            :ems_ref_obj => mor,
            :uid_ems     => mor,
            :name        => name,
            :child_uids  => child_mors,
            :hidden      => false
          }

          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.cluster_inv_to_hashes(inv)
        result = []
        result_uids = {}
        return result, result_uids if inv.nil?

        inv.each do |mor, data|
          new_result = InfraManager::RefreshParser::Cluster.parse_cluster(data)

          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.rp_inv_to_hashes(inv)
        result = []
        result_uids = {}
        return result, result_uids if inv.nil?

        inv.each do |mor, data|
          new_result = InfraManager::RefreshParser::ResourcePool.parse_rp(data)

          result << new_result
          result_uids[mor] = new_result
        end
        return result, result_uids
      end

      def self.customization_spec_inv_to_hashes(inv)
        result = []
        return result if inv.nil?

        inv.each do |spec_inv|
          result << InfraManager::RefreshParser::CustomizationSpec.parse_customization_spec(spec_inv)
        end
        result
      end

      def self.link_ems_metadata(data, inv)
        inv_to_data_types = {:folder => :folders, :dc => :folders, :storage_pod => :folders,
                             :cluster => :clusters, :rp => :resource_pools,
                             :storage => :storages, :host => :hosts, :vm => :vms}

        [:folders, :clusters, :resource_pools, :hosts].each do |parent_type|
          data[parent_type].each do |parent_data|
            child_uids = parent_data.delete(:child_uids)
            next if child_uids.blank?

            ems_children = parent_data[:ems_children] = {}

            child_uids.each do |child_uid|
              # Find this child in the inventory data.  If we have a host_res,
              #   check its children instead.
              child_type, child_inv = inv_target_by_mor(child_uid, inv)
              if child_type == :host_res
                child_uid = get_mors(child_inv, 'host')[0]
                if child_uid.nil?
                  child_type = child_inv = nil
                else
                  child_type, child_inv = inv_target_by_mor(child_uid, inv)
                end
              end
              next if child_inv.nil?

              child_type = inv_to_data_types[child_type]

              child = data.fetch_path(:uid_lookup, child_type, child_uid)
              unless child.nil?
                ems_children[child_type] ||= []
                ems_children[child_type] << child
              end
            end
          end
        end
      end

      def self.link_root_folder(data)
        # Find the folder that does not have a parent folder

        # Since the root folder is almost always called "Datacenters", move that
        #   folder to the head of the list as an optimization
        dcs, folders = data[:folders].partition { |f| f[:name] == "Datacenters" }
        dcs.each { |dc| folders.unshift(dc) }
        data[:folders] = folders

        found = data[:folders].find do |child|
          !data[:folders].any? do |parent|
            children = parent.fetch_path(:ems_children, :folders)
            children && children.any? { |c| c.object_id == child.object_id }
          end
        end

        unless found.nil?
          data[:ems_root] = found
        else
          _log.warn "Unable to find a root folder."
        end
      end

      def self.set_hidden_folders(data)
        return if data[:ems_root].nil?

        # Mark the root folder as hidden
        data[:ems_root][:hidden] = true

        # Mark all child folders of each Datacenter as hidden
        # e.g.: "vm", "host", "datastore"
        data[:folders].select { |f| f[:type] == "Datacenter" }.each do |dc|
          dc_children = dc.fetch_path(:ems_children, :folders)
          dc_children.to_miq_a.each do |f|
            f[:hidden] = true
          end
        end
      end

      def self.set_default_rps(data)
        # Update the default RPs and their names to reflect their parent relationships
        parent_classes = {:clusters => 'EmsCluster', :hosts => 'Host'}

        [:clusters, :hosts].each do |parent_type|
          data[parent_type].each do |parent|
            rps = parent.fetch_path(:ems_children, :resource_pools)
            next if rps.blank?

            rps.each do |rp|
              rp[:is_default] = true
              rp[:name] = "Default for #{Dictionary.gettext(parent_classes[parent_type], :type => :model, :notfound => :titleize)} #{parent[:name]}"
            end
          end
        end

        data[:resource_pools].each { |rp| rp[:is_default] = false unless rp[:is_default] }
      end

      #
      # Helper methods for EMS inventory parsing methods
      #

      def self.get_mor_type(mor)
        mor =~ /^([^-]+)-/ ? $1 : nil
      end

      def self.get_mors(inv, key)
        # Take care of case where a single or no element is a String
        return [] unless inv.kind_of?(Hash)
        d = inv[key]
        d = d['ManagedObjectReference'] if d.kind_of?(Hash)
        d.to_miq_a
      end

      VC_MOR_FILTERS = [
        [:host_res,    'domain'],
        [:cluster,     'domain'],
        [:dc,          'datacenter'],
        [:folder,      'group'],
        [:rp,          'resgroup'],
        [:storage,     'datastore'],
        [:storage_pod, 'group'],
        [:host,        'host'],
        [:vm,          'vm']
      ]

      def self.inv_target_by_mor(mor, inv)
        target_type = target = nil
        mor_type = get_mor_type(mor)

        VC_MOR_FILTERS.each do |type, mor_filter|
          next unless mor_type.nil? || mor_type == mor_filter
          target = inv[target_type = type][mor]
          break unless target.nil?
        end

        target_type = nil if target.nil?
        return target_type, target
      end


      #
      # Datastore File Inventory Parsing
      #

      def self.datastore_file_inv_to_hashes(inv, vm_ids_by_path)
        return [] if inv.nil?

        result = inv.collect do |data|
          name = data['fullPath']
          is_dir = data['fileType'] == 'FileFolderInfo'
          vm_id = vm_ids_by_path[is_dir ? name : File.dirname(name)]

          new_result = {
            :name      => name,
            :size      => data['fileSize'],
            :base_name => data['path'],
            :ext_name  => File.extname(data['path'])[1..-1].to_s.downcase,
            :mtime     => data['modification'],
            :rsc_type  => is_dir ? 'dir' : 'file'
          }
          new_result[:vm_or_template_id] = vm_id unless vm_id.nil?

          new_result
        end

        result
      end

      #
      # Other
      #

      def self.host_inv_to_firewall_rules_hashes(inv)
        inv = inv.fetch_path('config', 'firewall', 'ruleset')

        result = []
        return result if inv.nil?

        inv.to_miq_a.each do |data|
          # Collect Rule Set values
          current_rule_set = {:group => data['key'], :enabled => data['enabled'], :required => data['required']}

          # Process each Firewall Rule
          data['rule'].each do |rule|
            rule_string = rule['endPort'].nil? ? rule['port'].to_s : "#{rule['port']}-#{rule['endPort']}"
            rule_string << " (#{rule['protocol']}-#{rule['direction']})"
            result << {
              :name          => "#{data['key']} #{rule_string}",
              :display_name  => "#{data['label']} #{rule_string}",
              :host_protocol => rule['protocol'],
              :direction     => rule['direction'].chomp('bound'),  # Turn inbound/outbound to just in/out
              :port          => rule['port'],
              :end_port      => rule['endPort'],
            }.merge(current_rule_set)
          end
        end
        result
      end

      def self.host_inv_to_advanced_settings_hashes(inv)
        inv = inv['config']

        result = []
        return result if inv.nil?

        settings = inv['option'].to_miq_a.index_by { |o| o['key'] }
        details = inv['optionDef'].to_miq_a.index_by { |o| o['key'] }

        settings.each do |key, setting|
          detail = details[key]

          # TODO: change the 255 length 'String' columns, truncated below, to text
          # A vmware string type was confirmed to allow up to 9932 bytes
          result << {
            :name          => key,
            :value         => setting['value'].to_s,
            :display_name  => detail.nil? ? nil : truncate_value(detail['label']),
            :description   => detail.nil? ? nil : truncate_value(detail['summary']),
            :default_value => detail.nil? ? nil : truncate_value(detail.fetch_path('optionType', 'defaultValue')),
            :min           => detail.nil? ? nil : truncate_value(detail.fetch_path('optionType', 'min')),
            :max           => detail.nil? ? nil : truncate_value(detail.fetch_path('optionType', 'max')),
            :read_only     => detail.nil? ? nil : detail.fetch_path('optionType', 'valueIsReadonly')
          }
        end
        result
      end

      def self.truncate_value(val)
        return val[0, 255] if val.kind_of?(String)
      end
    end
  end
end
