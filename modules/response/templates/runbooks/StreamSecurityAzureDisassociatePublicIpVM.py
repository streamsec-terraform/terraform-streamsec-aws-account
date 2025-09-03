#!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient

def parse_vm_id(vm_id):
    pattern = (
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
        r"providers/Microsoft.Compute/virtualMachines/(?P<vm>[^/]+)"
    )
    match = re.match(pattern, vm_id)
    if not match:
        raise ValueError(f"Invalid VM resource ID format: {vm_id}")
    return match.group("sub"), match.group("rg"), match.group("vm")

def disassociate_all_public_ips(vm_id: str, uami_client_id: str):
    subscription_id, resource_group, vm_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)

    compute_client = ComputeManagementClient(credential, subscription_id)
    network_client = NetworkManagementClient(credential, subscription_id)

    print(f"Retrieving VM '{vm_name}' in resource group '{resource_group}'...")
    vm = compute_client.virtual_machines.get(resource_group, vm_name)

    updated_nics = []

    for nic_ref in vm.network_profile.network_interfaces:
        nic_id = nic_ref.id
        match = re.match(
            r"/subscriptions/[^/]+/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft.Network/networkInterfaces/(?P<name>[^/]+)",
            nic_id
        )
        if not match:
            print(f"Skipping unrecognized NIC ID format: {nic_id}")
            continue

        nic_rg, nic_name = match.group("rg"), match.group("name")
        nic = network_client.network_interfaces.get(nic_rg, nic_name)
        try:
            modified = False
            for ip_config in nic.ip_configurations:
                if ip_config.public_ip_address:
                    print(f"Disassociating public IP from NIC '{nic_name}'...")
                    ip_config.public_ip_address = None
                    modified = True

            if modified:
                network_client.network_interfaces.begin_create_or_update(nic_rg, nic_name, nic).result()
                updated_nics.append(nic_name)
        except Exception as e:
            raise Exception(f"Failed to disassociate public IP from NIC '{nic_name}': {e}")

    if updated_nics:
        print(f"Public IPs disassociated from NICs: {', '.join(updated_nics)}")
    else:
        print("No NICs had public IPs associated.")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: disassociate_public_ip.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Starting runbook with VM ID: {vm_id} and UAMI Client ID: {uami_client_id}")
    disassociate_all_public_ips(vm_id, uami_client_id)
