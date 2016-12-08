module ManageIQ::Providers
  module Vmware
    module InfraManager::RefreshParserSkeletal
      def self.parse_updates(updates)
        result = {}

        # Create a hash on ManagedEntity type from a flat updates array
        inv = updates_by_mor_type(updates)

        result[:folders]        = folder_inv_to_hashes(inv)
        result[:storages]       = storage_inv_to_hashes(inv)
        result[:clusters]       = cluster_inv_to_hashes(inv)
        result[:resource_pools] = rp_inv_to_hashes(inv)
        result[:hosts]          = host_inv_to_hashes(inv)
        result[:lans]           = lan_inv_to_hashes(inv)
        result[:vms]            = vm_inv_to_hashes(inv)

        result
      end

      def self.folder_inv_to_hashes(inv)
        folder_inv = inv['Folder'] + inv['Datacenter']
        process_collection(folder_inv) { |mor, props| parse_folder(mor, props) }
      end
      private_class_method :folder_inv_to_hashes

      def self.storage_inv_to_hashes(inv)
        storage_inv = inv['Datastore']
        process_collection(storage_inv) { |mor, props| parse_storage(mor, props) }
      end
      private_class_method :storage_inv_to_hashes

      def self.cluster_inv_to_hashes(inv)
        cluster_inv = inv['ComputeResource'] + inv['ClusterComputeResource']
        process_collection(cluster_inv) { |mor, props| parse_cluster(mor, props) }
      end
      private_class_method :cluster_inv_to_hashes

      def self.rp_inv_to_hashes(inv)
        rp_inv = inv['ResourcePool']
        process_collection(rp_inv) { |mor, props| parse_rp(mor, props) }
      end
      private_class_method :rp_inv_to_hashes

      def self.host_inv_to_hashes(inv)
        host_inv = inv['HostSystem']
        process_collection(host_inv) { |mor, props| parse_host(mor, props) }
      end
      private_class_method :host_inv_to_hashes

      def self.lan_inv_to_hashes(inv)
        lan_inv = inv['Network'] + inv['DistributedVirtualPortgroup']
        process_collection(lan_inv) { |mor, props| parse_lan(mor, props) }
      end
      private_class_method :lan_inv_to_hashes

      def self.vm_inv_to_hashes(inv)
        vm_inv = inv['VirtualMachine']
        process_collection(vm_inv) { |mor, props| parse_vm(mor, props) }
      end
      private_class_method :vm_inv_to_hashes

      def self.parse_folder(mor, props)
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
        }

        return mor, new_result
      end
      private_class_method :parse_folder

      def self.parse_storage(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :name        => props['name'],
          :location    => props['summary.url']
        }

        return mor, new_result
      end
      private_class_method :parse_storage

      def self.parse_cluster(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :uid_ems     => mor,
          :name        => props['name']
        }

        return mor, new_result
      end
      private_class_method :parse_cluster

      def self.parse_rp(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :uid_ems     => mor,
          :name        => props['name']
        }

        return mor, new_result
      end
      private_class_method :parse_rp

      def self.parse_host(mor, props)
        # TODO: check if is an ESX or ESXi host
        type = "ManageIQ::Providers::Vmware::InfraManager::HostEsx"

        new_result = {
          :type        => type,
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          # TODO: get the hostname
          :name        => props['name'],
        }

        return mor, new_result
      end
      private_class_method :parse_host

      def self.parse_lan(mor, props)
        new_result = {
          :ems_ref     => mor,
          :ems_ref_obj => mor,
          :name        => props['name'],
        }

        return mor, new_result
      end
      private_class_method :parse_lan

      def self.parse_vm(mor, props)
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
          :raw_power_state => raw_power_state
        }

        return mor, new_result
      end
      private_class_method :parse_vm

      def self.updates_by_mor_type(updates)
        result = Hash.new { |h, k| h[k] = [] }

        updates.each do |_kind, mor, props|
          result[mor.vimType] << [mor, props]
        end

        result
      end
      private_class_method :updates_by_mor_type

      def self.process_collection(inv)
        result = []

        inv.each do |mor, item|
          _uid, new_result = yield(mor, item)
          next if new_result.nil?

          result << new_result
        end

        return result
      end
      private_class_method :process_collection
    end
  end
end
