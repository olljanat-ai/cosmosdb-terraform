# Prototype environment.
#
#   cd vcore
#   terraform init
#   terraform apply -var-file=prototype.tfvars
#
# `cluster_name` is part of a public DNS name and has to be globally unique, so
# change it before the first apply.

resource_group_name = "rg-cosmosdb-vcore-prototype"
location            = "swedencentral"
cluster_name        = "cosmosdb-mongo-vcore-prototype"

# Everyone who may reach the data. There is no password to hand out, so this
# list is the access control of the cluster: the object ID of the managed
# identity of the workload, and the object ID of whoever operates it.
#
# For a managed identity this is the object ID of the identity itself, which is
# not its client ID:
#
#   az identity show --resource-group <rg> --name <identity> --query principalId -o tsv
#
# For a person:
#
#   az ad user show --id <upn> --query id -o tsv
#
# At least one entry is required, and the apply fails while the map is empty. A
# cluster nobody can authenticate to is not a useful cluster.
entra_administrators = {
  # workload = {
  #   object_id      = "00000000-0000-0000-0000-000000000000"
  #   principal_type = "servicePrincipal"
  # }
  # operator = {
  #   object_id      = "00000000-0000-0000-0000-000000000000"
  #   principal_type = "user"
  # }
}

# The smallest paid tier. Entra ID authentication is not offered on the free
# tier, so there is a floor here.
compute_tier    = "M10"
storage_size_gb = 32

# A prototype single node cluster. Use `SameZone` or `ZoneRedundantPreferred`
# for anything that is not a prototype.
high_availability_mode = "Disabled"

# Reached over a private endpoint in an existing subnet. Without either this or
# `public_network_access_enabled`, the apply warns that nothing can reach the
# cluster.
#
# private_endpoint_subnet_id = "/subscriptions/.../subnets/private-endpoints"
# private_dns_zone_ids       = ["/subscriptions/.../privateDnsZones/privatelink.mongocluster.cosmos.azure.com"]

# The other way in, for a prototype without a virtual network. Both of these
# together, or neither.
#
# public_network_access_enabled = true
# firewall_rules = [
#   {
#     name     = "office"
#     start_ip = "203.0.113.0"
#     end_ip   = "203.0.113.255"
#   },
# ]

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}
