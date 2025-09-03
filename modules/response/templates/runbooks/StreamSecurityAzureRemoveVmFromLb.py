#!/usr/bin/env python3
import re
import sys
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient

def parse_vm_id(vm_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Compute/virtualMachines/(?P<vm>[^/]+)")
    match = re.match(pattern, vm_id)
    if not match:
        raise ValueError(f"Invalid VM ID format: {vm_id}")
    return match.group("sub"), match.group("rg"), match.group("vm")

def remove_vm_from_all_load_balancers(vm_id, uami_client_id: str):
    subscription_id, resource_group, vm_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)
    network_client = NetworkManagementClient(credential, subscription_id)
    vm = compute_client.virtual_machines.get(resource_group, vm_name)
    try:
        for nic_ref in vm.network_profile.network_interfaces:
            nic_name = nic_ref.id.split('/')[-1]
            nic = network_client.network_interfaces.get(resource_group, nic_name)

            changed = False
            for ip_config in nic.ip_configurations:
                if ip_config.load_balancer_backend_address_pools:
                    print(f"Removing {len(ip_config.load_balancer_backend_address_pools)} backend pools from NIC '{nic.name}' IP config '{ip_config.name}'")
                    ip_config.load_balancer_backend_address_pools = []
                    changed = True

            if changed:
                print(f"Updating NIC '{nic.name}' to remove all backend pool connections...")
                poller = network_client.network_interfaces.begin_create_or_update(resource_group, nic.name, nic)
                poller.result()
                print(f"NIC '{nic.name}' updated successfully.")
    except Exception as e:
        raise Exception(f"Failed to remove VM '{vm_name}' from load balancer backend pools: {e}")

    print(f"VM '{vm_name}' has been removed from all load balancer backend pools.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: VM ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    remove_vm_from_all_load_balancers(vm_id, uami_client_id)
