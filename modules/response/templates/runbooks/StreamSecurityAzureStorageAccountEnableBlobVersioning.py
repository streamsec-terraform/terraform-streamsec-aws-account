#!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.storage import StorageManagementClient

def parse_storage_account_id(storage_account_id):
    match = re.match(
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft\.Storage/storageAccounts/(?P<account>[^/]+)",
        storage_account_id
    )
    if not match:
        raise ValueError(f"Invalid storage account ID: {storage_account_id}")
    return match.group("sub"), match.group("rg"), match.group("account")

def enable_blob_versioning(storage_account_id: str, uami_client_id: str):
    subscription_id, resource_group, account_name = parse_storage_account_id(storage_account_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)
    client = StorageManagementClient(credential, subscription_id)

    try:
        print(f"Enabling blob versioning for account: {account_name}")
        result = client.blob_services.set_service_properties(
            resource_group_name=resource_group,
            account_name=account_name,
            parameters={
                "is_versioning_enabled": True
            },
            blob_services_name="default"
        )
        print(f"Blob versioning enabled on Storage Account: {account_name}")
    except Exception as e:
        raise Exception(f"Failed to enable blob versioning: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: enable_blob_versioning.py <storage_account_id> <uami_client_id>")
        sys.exit(1)

    storage_account_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: Storage Account ID: {storage_account_id}, UAMI Client ID: {uami_client_id}")
    enable_blob_versioning(storage_account_id, uami_client_id)
