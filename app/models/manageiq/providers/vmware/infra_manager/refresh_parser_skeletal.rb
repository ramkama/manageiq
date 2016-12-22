module ManageIQ::Providers
  module Vmware
    class InfraManager::RefreshParserSkeletal < ManageIQ::Providers::InfraManager::RefreshParser
      def self.parse_updates(ems, updates, options = nil)
        new(ems, options).parse_updates(updates)
      end

      def initialize(ems, _options = nil)
        @ems = ems
      end

      def parse_updates(updates)
        uids = {}
        result = {}

        # Create a hash on ManagedEntity type from a flat updates array
        inv = updates_by_mor_type(updates)

        result[:folders],        uids[:folders]        = folder_inv_to_hashes(inv)
        result[:storages],       uids[:storages]       = storage_inv_to_hashes(inv)
        result[:clusters],       uids[:clusters]       = cluster_inv_to_hashes(inv)
        result[:resource_pools], uids[:resource_pools] = rp_inv_to_hashes(inv)
        result[:hosts],          uids[:hosts]          = host_inv_to_hashes(inv)
        result[:lans],           uids[:lans]           = lan_inv_to_hashes(inv)
        result[:vms],            uids[:vms]            = vm_inv_to_hashes(inv)

        link_ems_metadata(result, uids)

        result
      end

      private

      def folder_inv_to_hashes(inv)
        folder_inv = inv['Folder'] + inv['Datacenter']
        process_collection(folder_inv) { |mor, props| parse_folder(mor, props) }
      end

      def storage_inv_to_hashes(inv)
        storage_inv = inv['Datastore']
        process_collection(storage_inv) { |mor, props| parse_storage(mor, props) }
      end

      def cluster_inv_to_hashes(inv)
        cluster_inv = inv['ComputeResource'] + inv['ClusterComputeResource']
        process_collection(cluster_inv) { |mor, props| parse_cluster(mor, props) }
      end

      def rp_inv_to_hashes(inv)
        rp_inv = inv['ResourcePool']
        process_collection(rp_inv) { |mor, props| parse_rp(mor, props) }
      end

      def host_inv_to_hashes(inv)
        host_inv = inv['HostSystem']
        process_collection(host_inv) { |mor, props| parse_host(mor, props) }
      end

      def lan_inv_to_hashes(inv)
        lan_inv = inv['Network'] + inv['DistributedVirtualPortgroup']
        process_collection(lan_inv) { |mor, props| parse_lan(mor, props) }
      end

      def vm_inv_to_hashes(inv)
        vm_inv = inv['VirtualMachine']
        process_collection(vm_inv) { |mor, props| parse_vm(mor, props) }
      end

      def parse_folder(mor, props)
        type = case mor.vimType
               when 'Datacenter'
                 'Datacenter'
               when 'Folder'
                 'EmsFolder'
               end
        return if type.nil?

        new_result = {
          :type        => type,
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :uid_ems     => mor,
          :name        => props['name'],
          :parent      => props['parent']
        }

        return mor, new_result
      end

      def parse_storage(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :name        => props['name'],
          :location    => props['summary.url'],
          :parent      => props['parent']
        }

        return mor, new_result
      end

      def parse_cluster(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :uid_ems     => mor,
          :name        => props['name'],
          :parent      => props['parent']
        }

        return mor, new_result
      end

      def parse_rp(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :uid_ems     => mor,
          :name        => props['name'],
          :parent      => props['parent'],
          :child_uids  => get_mors(props, "vm")
        }

        return mor, new_result
      end

      def parse_host(mor, props)
        # TODO: check if is an ESX or ESXi host
        type = "ManageIQ::Providers::Vmware::InfraManager::HostEsx"

        new_result = {
          :type        => type,
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          # TODO: get the hostname
          :name        => props['name'],
          :parent      => props['parent']
        }

        return mor, new_result
      end

      def parse_lan(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :name        => props['name'],
          :parent      => props['parent']
        }

        return mor, new_result
      end

      def parse_vm(mor, props)
        template = props['summary.config.template'].to_s.downcase == 'true'
        type     = "ManageIQ::Providers::Vmware::InfraManager::#{template ? 'Template' : 'Vm'}"

        raw_power_state = template ? 'never' : props['summary.runtime.powerState']

        new_result = {
          :type            => type,
          :ems_ref         => mor,
          :ems_ref_obj     => mor,
          :vendor          => 'vmware',
          :name            => props['name'],
          :uid_ems         => props['summary.config.uuid'],
          :template        => template,
          :raw_power_state => raw_power_state,
          :parent          => props['parent']
        }

        return mor, new_result
      end

      def link_parent(type, data, uids)
        parent_uid = data.delete(:parent)
        return if parent_uid.nil?

        parent_type, parent_inv = inv_target_by_mor(parent_uid, uids)
        return if parent_type.nil? || parent_inv.nil?

        parent_inv[:ems_children] ||= {}
        parent_inv[:ems_children][type] ||= []
        parent_inv[:ems_children][type] << data
      end

      def link_children(data, uids)
        child_uids = data.delete(:child_uids)
        return if child_uids.blank?

        data[:ems_children] ||= {}
        child_uids.each do |child_uid|
          child_type, child_inv = inv_target_by_mor(child_uid, uids)
          next if child_type.nil? || child_inv.nil?

          data[:ems_children][child_type] ||= []
          data[:ems_children][child_type] << child_inv
        end
      end

      def link_root_folder(data)
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

      def link_ems_metadata(result, uids)
        result.keys.each do |type|
          result[type].each do |data|
            link_parent(type, data, uids)
            link_children(data, uids)
          end
        end

        link_root_folder(result)
      end

      def updates_by_mor_type(updates)
        result = Hash.new { |h, k| h[k] = [] }

        updates.each do |_kind, mor, props|
          result[mor.vimType] << [mor, props]
        end

        result
      end

      def process_collection(inv)
        result = []
        result_uids = {}

        inv.each do |mor, item|
          uid, new_result = yield(mor, item)
          next if new_result.nil?

          result << new_result
          result_uids[mor] = new_result
        end

        return result, result_uids
      end

      def get_mors(inv, key)
        # Take care of case where a single or no element is a String
        return [] unless inv.kind_of?(Hash)
        d = inv[key]
        d = d['ManagedObjectReference'] if d.kind_of?(Hash)
        d.to_miq_a
      end

      VC_MOR_FILTERS = [
        [:folders,     'Datacenter'],
        [:folders,     'Folder'],
        [:vms,         'VirtualMachine'],
      ]

      def inv_target_by_mor(mor, inv)
        target_type = target = nil
        mor_type = mor.vimType

        VC_MOR_FILTERS.each do |type, mor_filter|
          next unless mor_type.nil? || mor_type == mor_filter
          target = inv[target_type = type][mor]
          break unless target.nil?
        end

        target_type = nil if target.nil?
        return target_type, target
      end
    end
  end
end
