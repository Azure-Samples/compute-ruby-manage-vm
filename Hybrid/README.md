# Manage virtual machines using Ruby
This sample demonstrates how to manage your Azure virtual machines using the Ruby SDK.

**On this page**

- [Run this sample](#run)
- [What is example.rb doing?](#example)
    - [Create a virtual network](#vnet)
    - [Create a public IP address](#ipaddress)
    - [Create a virtual machine](#vm)
    - [Stop the VM](#stop)
    - [Start the VM](#start)
    - [Restart the VM](#restart)
    - [Delete the resources](#delete)
    

<a id="run"></a>
## Run this sample

1. If you don't already have it, [install Ruby and the Ruby DevKit](https://www.ruby-lang.org/en/documentation/installation/).

2. If you don't have bundler, install it.

    ```
    gem install bundler
    ```
    
3. Clone the repository.

    ```
    git clone https://github.com/Azure-Samples/compute-ruby-manage-vm.git
    ```

4. Install the dependencies using bundle.

    ```
    cd compute-ruby-manage-vm\Hybrid
    bundle install
    ```
    
5. Create a [service principal](https://docs.microsoft.com/en-us/azure/azure-stack/azure-stack-create-service-principals) to work against AzureStack. Make sure your service principal has [contributor/owner role](https://docs.microsoft.com/en-us/azure/azure-stack/azure-stack-create-service-principals#assign-role-to-service-principal) on your subscription.

6. Set the following environment variables using the information from the service principle that you created.

    ```
    export AZURE_TENANT_ID={your tenant id}
    export AZURE_CLIENT_ID={your client id}
    export AZURE_CLIENT_SECRET={your client secret}
    export AZURE_SUBSCRIPTION_ID={your subscription id}
    export ARM_ENDPOINT={your AzureStack Resource manager url}`
    ```

    > [AZURE.NOTE] On Windows, use `set` instead of `export`.

7. To authenticate the Service Principal against Azure Stack environment, the endpoints should be defined using ```get_active_directory_settings()```. This method uses the ARM_Endpoint environment variable that was set using the previous step.


    ```ruby
    # Get Authentication endpoints using Arm Metadata Endpoints
    def get_active_directory_settings(armEndpoint)
        settings = MsRestAzure::ActiveDirectoryServiceSettings.new
        response = Net::HTTP.get_response(URI("#{armEndpoint}/metadata/endpoints?api-version=1.0"))
        status_code = response.code
        response_content = response.body
        unless status_code == "200"
            error_model = JSON.load(response_content)
            fail MsRestAzure::AzureOperationError.new("Getting Azure Stack Metadata Endpoints", response, error_model)
        end

        result = JSON.load(response_content)
        settings.authentication_endpoint = result['authentication']['loginEndpoint'] unless result['authentication']['loginEndpoint'].nil?
        settings.token_audience = result['authentication']['audiences'][0] unless result['authentication']['audiences'][0].nil?
        settings
    end
    ```

8. Note that in order to run this sample, Ubuntu 16.04.0-LTS image must be present in AzureStack market place. This can be either [downloaded from Azure](https://docs.microsoft.com/en-us/azure/azure-stack/azure-stack-download-azure-marketplace-item) or [added to Platform Image Repository](https://docs.microsoft.com/en-us/azure/azure-stack/azure-stack-add-vm-image).

9. Run the sample.

    ```
    bundle exec ruby example.rb
    ```

<a id="example"></a>
## What is example.rb doing?

This sample starts by setting up ResourceManagementClient, the resource provider clients, a resource group, and a storage account using your subscription and credentials.

```ruby
  subscription_id = ENV['AZURE_SUBSCRIPTION_ID'] || '11111111-1111-1111-1111-111111111111' # your Azure Subscription Id

  # This parameter is only required for AzureStack or other soverign clouds. Pulic Azure already has these settings by default.
    active_directory_settings = get_active_directory_settings(ENV['ARM_ENDPOINT'])


  provider = MsRestAzure::ApplicationTokenProvider.new(
      ENV['AZURE_TENANT_ID'],
      ENV['AZURE_CLIENT_ID'],
      ENV['AZURE_CLIENT_SECRET'],
      active_directory_settings
      )
  credentials = MsRest::TokenCredentials.new(provider)

  options = {
      credentials: credentials,
      subscription_id: subscription_id,
      active_directory_settings: active_directory_settings,
      base_url: ENV['ARM_ENDPOINT']
  }

  resource_client = Azure::Resources::Profiles::V2017_03_09::Mgmt::Client.new(options)
  network_client = Azure::Network::Profiles::V2017_03_09::Mgmt::Client.new(options)
  storage_client = Azure::Storage::Profiles::V2017_03_09::Mgmt::Client.new(options)
  compute_client = Azure::Compute::Profiles::V2017_03_09::Mgmt::Client.new(options)

resource_group_params = Azure::ARM::Resources::Models::ResourceGroup.new.tap do |rg|
    rg.location = REGION
end

resource_group = resource_client.resource_groups.create_or_update(RESOURCE_GROUP_NAME, resource_group_params)

# Create a Storage Account. Encryption settings are only supported on blobs for AzureStack.
postfix = rand(1000)
storage_account_name = "rubystor#{postfix}"
puts "Creating a standard storage account named #{storage_account_name} in resource group #{GROUP_NAME}"
storage_create_params = StorageModels::StorageAccountCreateParameters.new.tap do |account|
    account.location = REGION
    account.sku = StorageModels::Sku.new.tap do |sku|
        sku.name = StorageModels::SkuName::StandardLRS
        sku.tier = StorageModels::SkuTier::Standard
    end
    account.kind = StorageModels::Kind::Storage  
end
print_item storage_account = storage_client.storage_accounts.create(GROUP_NAME, storage_account_name, storage_create_params)
```

<a id="vnet"></a>
### Create a virtual network

```ruby
puts 'Creating a virtual network for the VM'
vnet_create_params = NetworkModels::VirtualNetwork.new.tap do |vnet|
    vnet.location = REGION
    vnet.address_space = NetworkModels::AddressSpace.new.tap do |addr_space|
        addr_space.address_prefixes = ['10.0.0.0/16']
    end
    vnet.dhcp_options = NetworkModels::DhcpOptions.new.tap do |dhcp|
        dhcp.dns_servers = ['8.8.8.8']
    end
    vnet.subnets = [
        NetworkModels::Subnet.new.tap do |subnet|
            subnet.name = 'rubySampleSubnet'
            subnet.address_prefix = '10.0.0.0/24'
        end
    ]
end
print_item vnet = network_client.virtual_networks.create_or_update(GROUP_NAME, 'sample-ruby-vnet', vnet_create_params)
```

<a id="ipaddress"></a>
### Create a public IP address

```ruby
puts 'Creating a public IP address for the VM'
public_ip_params = NetworkModels::PublicIPAddress.new.tap do |ip|
    ip.location = REGION
    ip.public_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
    ip.dns_settings = NetworkModels::PublicIPAddressDnsSettings.new.tap do |dns|
        dns.domain_name_label = "stack-sample-dns#{postfix}"
    end
end
print_item public_ip = network_client.public_ipaddresses.create_or_update(GROUP_NAME, 'sample-ruby-pubip', public_ip_params)
```

<a id="vm"></a>
### Create a virtual machine

```ruby
print_item nic = network_client.network_interfaces.create_or_update(
    GROUP_NAME,
    "sample-ruby-nic-#{vm_name}",
    NetworkModels::NetworkInterface.new.tap do |interface|
        interface.location = REGION
        interface.ip_configurations = [
            NetworkModels::NetworkInterfaceIPConfiguration.new.tap do |nic_conf|
                nic_conf.name = "sample-ruby-nic-#{vm_name}"
                nic_conf.private_ipallocation_method = NetworkModels::IPAllocationMethod::Dynamic
                nic_conf.subnet = subnet
                nic_conf.public_ipaddress = public_ip
            end
        ]
    end
)
puts 'Creating a Ubuntu 16.04.0-LTS Standard DS2 V2 virtual machine w/ a public IP'
vm_create_params = ComputeModels::VirtualMachine.new.tap do |vm|
    vm.location = location
    vm.os_profile = ComputeModels::OSProfile.new.tap do |os_profile|
        os_profile.computer_name = vm_name
        os_profile.admin_username = 'notAdmin'
        os_profile.admin_password = SecureRandom.uuid
    end
    vm.storage_profile = ComputeModels::StorageProfile.new.tap do |store_profile|
        store_profile.image_reference = ComputeModels::ImageReference.new.tap do |ref|
            ref.publisher = 'canonical'
            ref.offer = 'UbuntuServer'
            ref.sku = '16.04.0-LTS'
            ref.version = 'latest'
        end
        store_profile.os_disk = ComputeModels::OSDisk.new.tap do |os_disk|
            os_disk.name = "sample-os-disk-#{vm_name}"
            os_disk.caching = ComputeModels::CachingTypes::None
            os_disk.create_option = ComputeModels::DiskCreateOptionTypes::FromImage
            os_disk.vhd = ComputeModels::VirtualHardDisk.new.tap do |vhd|
                vhd.uri = "https://#{storage_acct.name}.blob.#{public_ip.dns_settings.fqdn}/rubycontainer/#{vm_name}.vhd"
            end
        end
    end
    vm.hardware_profile = ComputeModels::HardwareProfile.new.tap do |hardware|
        hardware.vm_size = ComputeModels::VirtualMachineSizeTypes::StandardDS2V2
    end
    vm.network_profile = ComputeModels::NetworkProfile.new.tap do |net_profile|
        net_profile.network_interfaces = [
            ComputeModels::NetworkInterfaceReference.new.tap do |ref|
                ref.id = nic.id
                ref.primary = true
            end
        ]
    end
end
ssh_pub_location = File.expand_path('~/.ssh/id_rsa.pub')
if File.exists? ssh_pub_location
    puts "Found SSH public key in #{ssh_pub_location}. Disabling password and enabling SSH authentication."
    key_data = File.read(ssh_pub_location)
    puts "Using public key: #{key_data}"
    vm_create_params.os_profile.linux_configuration = ComputeModels::LinuxConfiguration.new.tap do |linux|
        linux.disable_password_authentication = true
        linux.ssh = ComputeModels::SshConfiguration.new.tap do |ssh_config|
            ssh_config.public_keys = [
                ComputeModels::SshPublicKey.new.tap do |pub_key|
                    pub_key.key_data = key_data
                    pub_key.path = '/home/notAdmin/.ssh/authorized_keys'
                end
            ]
        end
    end
end
print_item vm = compute_client.virtual_machines.create_or_update(GROUP_NAME, "sample-ruby-vm-#{vm_name}", vm_create_params)
    vm
end
```

<a id="stop"></a>
### Stop the VM

```ruby
compute_client.virtual_machines.power_off(GROUP_NAME, vm.name)
```

<a id="start"></a>
### Start the VM

```ruby
compute_client.virtual_machines.start(GROUP_NAME, vm.name)
```

<a id="restart"></a>
### Restart the VM

```ruby
compute_client.virtual_machines.restart(GROUP_NAME, vm.name)
```

<a id="delete"></a>
### Delete the resources

```ruby
resource_client.resource_groups.delete(GROUP_NAME)
```