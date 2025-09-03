#!/usr/bin/env python3
import re
import sys
from azure.identity import ManagedIdentityCredential
from azure.mgmt.compute import ComputeManagementClient
from azure.mgmt.network import NetworkManagementClient
from azure.mgmt.network.models import NetworkSecurityGroup, SecurityRule


def parse_vm_id(vm_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Compute/virtualMachines/(?P<vm>[^/]+)")
    match = re.match(pattern, vm_id)
    if not match:
        raise ValueError(f"Invalid VM ID format: {vm_id}")
    return match.group("sub"), match.group("rg"), match.group("vm")

def parse_nic_id(nic_id):
    pattern = (r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/"
               r"providers/Microsoft.Network/networkInterfaces/(?P<nic>[^/]+)")
    match = re.match(pattern, nic_id)
    if not match:
        raise ValueError(f"Invalid NIC ID format: {nic_id}")
    return match.group("rg"), match.group("nic")


def get_isolated_nsg(network_client, resource_group, nsg_name, location):
    nsg_name = f"{nsg_name}-{location.replace(' ', '-')}"
    try:
        nsg = network_client.network_security_groups.get(resource_group, nsg_name)
        if nsg.location.lower() != location.lower():
            raise Exception(f"NSG '{nsg_name}' exists in a different location: {nsg.location}")
        print(f" NSG '{nsg_name}' already exists.")
    except Exception:
        params = NetworkSecurityGroup(location=location)
        poller = network_client.network_security_groups.begin_create_or_update(resource_group, nsg_name, params)
        poller.result()
        print(f" NSG '{nsg_name}' created successfully.")

    deny_inbound = SecurityRule(
        name="StreamDenyAllInbound",
        protocol="*",
        source_address_prefix="*",
        destination_address_prefix="*",
        access="Deny",
        direction="Inbound",
        priority=100,
        source_port_range="*",
        destination_port_range="*")

    deny_outbound = SecurityRule(
        name="StreamDenyAllOutbound",
        protocol="*",
        source_address_prefix="*",
        destination_address_prefix="*",
        access="Deny",
        direction="Outbound",
        priority=101,
        source_port_range="*",
        destination_port_range="*")

    existing_rules = list(network_client.security_rules.list(resource_group, nsg_name))
    for rule in existing_rules:
        network_client.security_rules.begin_delete(resource_group, nsg_name, rule.name).result()

    network_client.security_rules.begin_create_or_update(resource_group, nsg_name, deny_inbound.name,
                                                             deny_inbound).result()

    network_client.security_rules.begin_create_or_update(resource_group, nsg_name, deny_outbound.name,
                                                             deny_outbound).result()

    return network_client.network_security_groups.get(resource_group, nsg_name)


def isolate_vm(vm_id, uami_client_id: str):
    subscription_id, resource_group, vm_name = parse_vm_id(vm_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    compute_client = ComputeManagementClient(credential, subscription_id)
    network_client = NetworkManagementClient(credential, subscription_id)
    vm = compute_client.virtual_machines.get(resource_group, vm_name)
    quarantine_nsg_name = "IsolatedSGStream"

    try:
        for nic_ref in vm.network_profile.network_interfaces:
            nic_id = nic_ref.id
            nic_rg, nic_name = parse_nic_id(nic_id)
            nic = network_client.network_interfaces.get(nic_rg, nic_name)
            location = nic.location
            try:
                print(f" Processing NIC '{nic_name}' in resource group '{nic_rg}' with location '{location}'...")
                quarantine_nsg = get_isolated_nsg(network_client, nic_rg, quarantine_nsg_name, location)
            except Exception as e:
                raise Exception(f"Failed to create or retrieve NSG '{quarantine_nsg_name}': {e}")

            if nic.network_security_group and nic.network_security_group.id.lower() == quarantine_nsg.id.lower():
                print(f" NIC '{nic_name}' is already using quarantine NSG.")
                continue

            nic.network_security_group = quarantine_nsg
            poller = network_client.network_interfaces.begin_create_or_update(nic_rg, nic_name, nic)
            poller.result()
            print(f" NIC '{nic_name}' updated to use '{quarantine_nsg_name}'.")
    except Exception as e:
        raise Exception(f"Failed to update network interfaces for VM '{vm_name}': {e}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python runbook.py <vm_id> <uami_client_id>")
        sys.exit(1)

    vm_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: VM ID: {vm_id}, UAMI Client ID: {uami_client_id}")
    isolate_vm(vm_id, uami_client_id)

