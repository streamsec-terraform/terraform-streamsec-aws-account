#!/usr/bin/env python3

import sys
import re
from azure.identity import ManagedIdentityCredential
from azure.mgmt.sql import SqlManagementClient

def parse_sql_server_id(server_id):
    match = re.match(
        r"/subscriptions/(?P<sub>[^/]+)/resourceGroups/(?P<rg>[^/]+)/providers/Microsoft.Sql/servers/(?P<server>[^/]+)",
        server_id
    )
    if not match:
        raise ValueError(f"Invalid SQL Server ID format: {server_id}")
    return match.group("sub"), match.group("rg"), match.group("server")

def disable_sql_public_access(server_id: str, uami_client_id: str):
    subscription_id, resource_group, server_name = parse_sql_server_id(server_id)
    credential = ManagedIdentityCredential(client_id=uami_client_id)

    client = SqlManagementClient(credential, subscription_id)

    try:
        sql_server = client.servers.get(resource_group, server_name)
        if not sql_server:
            raise Exception(f"server {server_id} not found")
        print(f"Disabling public network access for SQL Server: {server_name}")
        result = client.servers.begin_update(
            resource_group_name=resource_group,
            server_name=server_name,
            parameters={
                "public_network_access": "Disabled"
            }
        ).result()
        print(f"Public network access disabled for SQL Server: {server_name}")
    except Exception as e:
        raise Exception(f"Failed to disable public network access on SQL Server '{server_name}': {e}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: disable_sql_public_access.py <sql_server_id> <uami_client_id>")
        sys.exit(1)

    sql_server_id = sys.argv[1]
    uami_client_id = sys.argv[2]
    print(f"Received Parameters: SQL Server ID: {sql_server_id}, UAMI Client ID: {uami_client_id}")
    disable_sql_public_access(sql_server_id, uami_client_id)
