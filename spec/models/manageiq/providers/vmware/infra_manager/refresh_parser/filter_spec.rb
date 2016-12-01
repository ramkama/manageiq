describe ManageIQ::Providers::Vmware::InfraManager::RefreshParser::Filter do
  context "filter_vc_data" do
    let(:ems) { FactoryGirl.create(:ems_vmware) }

    before do
      @refresher = ems.refresher.new([ems])
      @refresher.instance_variable_set(:@vc_data, vc_data)
    end

    context "with 1 host and 1 vm" do
      let(:vm)   { FactoryGirl.create(:vm_with_ref) }
      let(:host) { FactoryGirl.create(:host_with_ref) }
      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        inv[:host][host.ems_ref] = { "MOR" => host.ems_ref }
        inv[:vm][vm.ems_ref]     = {
          "MOR"     => vm.ems_ref,
          "summary" => { "runtime" => { "host" => host.ems_ref } }
        }

        inv
      end

      context "targeting the ems" do
        it "returns the full inventory" do
          filtered_data = @refresher.filter_vc_data(ems, ems)
          expect(filtered_data).to eq(vc_data)
        end
      end

      context "targeting a vm" do
        it "returns relevent data" do
          filtered_data = @refresher.filter_vc_data(ems, vm)

          expect(filtered_data[:host].count).to eq(1)
          expect(filtered_data[:host]).to       include(host.ems_ref)

          expect(filtered_data[:vm].count).to   eq(1)
          expect(filtered_data[:vm]).to         include(vm.ems_ref)
        end
      end
    end

    context "with a vm and no host" do
      let(:vm)          { FactoryGirl.create(:vm_with_ref) }
      let(:dc)          { FactoryGirl.create(:datacenter, :ems_ref => "datacenter-1", :name => "dc1") }
      let(:root_folder) { FactoryGirl.create(:ems_folder, :ems_ref => "group-d1",     :name => "Datacenters") }
      let(:vm_folder)   { FactoryGirl.create(:ems_folder, :ems_ref => "group-v3",     :name => "vm") }

      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        inv[:vm][vm.ems_ref] = {
          "MOR"     => vm.ems_ref,
          "summary" => { "runtime" => { "host" => "host-1234" } }
        }

        inv[:dc][dc.ems_ref] = {
          "MOR"    => dc.ems_ref,
          "parent" => root_folder.ems_ref
        }

        inv[:folder][root_folder.ems_ref] = {
          "MOR"         => root_folder.ems_ref,
          "childEntity" => [dc.ems_ref]
        }

        inv[:folder][vm_folder.ems_ref] = {
          "MOR"         => vm_folder.ems_ref,
          "childEntity" => [vm.ems_ref],
          "parent"      => dc.ems_ref
        }

        inv
      end

      context "targeting a vm" do
        # Test to make sure that a targeted refresh of a VM with no host
        # in inventory still returns the root folder
        it "returns the root folder" do
          filtered_data = @refresher.filter_vc_data(ems, vm)

          expect(filtered_data[:folder]).to include(root_folder.ems_ref)
        end
      end
    end

    context "minimal inventory" do
      let(:vm)               { FactoryGirl.create(:vm_with_ref) }
      let(:host1)            { FactoryGirl.create(:host_with_ref) }
      let(:host2)            { FactoryGirl.create(:host_with_ref) }
      let(:storage)          { FactoryGirl.create(:storage_vmware_with_ref) }
      let(:dc)               { FactoryGirl.create(:datacenter, :ems_ref => "datacenter-1", :name => "dc1") }
      let(:root_folder)      { FactoryGirl.create(:ems_folder, :ems_ref => "group-d1",     :name => "Datacenters") }
      let(:vm_folder)        { FactoryGirl.create(:ems_folder, :ems_ref => "group-v3",     :name => "vm") }
      let(:host_folder)      { FactoryGirl.create(:ems_folder, :ems_ref => "group-h4",     :name => "host") }
      let(:datastore_folder) { FactoryGirl.create(:ems_folder, :ems_ref => "group-s5",     :name => "datastore") }
      let(:network_folder)   { FactoryGirl.create(:ems_folder, :ems_ref => "group-n6",     :name => "network") }

      let(:vc_data) do
        inv = Hash.new { |h, k| h[k] = {} }

        inv[:dc][dc.ems_ref]                   = {
          "MOR"    => dc.ems_ref,
          "parent" => root_folder.ems_ref
        }

        inv[:folder][root_folder.ems_ref]      = {
          "MOR"         => root_folder.ems_ref,
          "childEntity" => [dc.ems_ref]
        }

        inv[:folder][vm_folder.ems_ref]        = {
          "MOR"         => vm_folder.ems_ref,
          "childEntity" => [vm.ems_ref],
          "parent"      => dc.ems_ref
        }

        inv[:folder][host_folder.ems_ref]      = {
          "MOR"         => host_folder.ems_ref,
          "childEntity" => [host1.ems_ref, host2.ems_ref],
          "parent"      => dc.ems_ref
        }

        inv[:folder][datastore_folder.ems_ref] = {
          "MOR"         => datastore_folder.ems_ref,
          "childEntity" => [storage.ems_ref],
          "parent"      => dc.ems_ref
        }

        inv[:folder][network_folder.ems_ref]   = {
          "MOR"         => network_folder.ems_ref,
          "childEntity" => [],
          "parent"      => dc.ems_ref
        }

        inv[:host][host1.ems_ref]              = {
          "MOR"    => host1.ems_ref,
          "parent" => host_folder.ems_ref
        }

        inv[:host][host2.ems_ref]              = {
          "MOR"    => host2.ems_ref,
          "parent" => host_folder.ems_ref
        }

        inv[:vm][vm.ems_ref]                   = {
          "MOR"     => vm.ems_ref,
          "summary" => { "runtime" => { "host" => host1.ems_ref } }
        }

        inv[:storage][storage.ems_ref]         = {
          "MOR"    => storage.ems_ref,
          "host"   => [
            {
              "key"       => host1.ems_ref,
              "mountInfo" => {
                "path"       => "/vmfs/volumes/b4db3893-29a32816",
                "accessMode" => "readWrite",
                "mounted"    => "true",
                "accessible" => "true"
              }
            }
          ],
          "parent" => datastore_folder.ems_ref
        }

        inv
      end

      context "targeting the ems" do
        it "returns the full inventory" do
          filtered_data = @refresher.filter_vc_data(ems, ems)
          expect(filtered_data).to eq(vc_data)
        end
      end

      context "targeting a vm" do
        it "returns relevent data" do
          filtered_data = @refresher.filter_vc_data(ems, vm)

          expect(filtered_data[:host].count).to eq(1)
          expect(filtered_data[:host]).to       include(host.ems_ref)

          expect(filtered_data[:vm].count).to   eq(1)
          expect(filtered_data[:vm]).to         include(vm.ems_ref)
        end
      end

      context "targeting a datastore" do
        it "returns the targeted storage" do
          filtered_data = @refresher.filter_vc_data(ems, storage)

          storage_hash = vc_data[:storage][storage.ems_ref]
          expect(filtered_data[:storage]).to eq(storage.ems_ref => storage_hash)
        end

        it "returns only hosts that have the storage mounted" do
          filtered_data = @refresher.filter_vc_data(ems, storage)

          expect(filtered_data[:host].keys).to eq([host1.ems_ref])
        end

        it "returns VMs on that storage" do
          filtered_data = @refresher.filter_vc_data(ems, storage)

          expect(filtered_data[:vm].keys).to eq([vm.ems_ref])
        end
      end
    end
  end
end
