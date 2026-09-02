# Prototype environment.
#
#   cd nosql
#   terraform init
#   terraform apply -var-file=prototype.tfvars
#
# `account_name` is part of a public DNS name and has to be globally unique, so
# change it before the first apply.

resource_group_name = "rg-cosmosdb-nosql-prototype"
location            = "swedencentral"
account_name        = "cosmosdb-nosql-prototype"

# Two databases, each with an identity of its own. The identity of `orders`
# reads and writes `orders` and cannot see `billing` at all, and the other way
# around. Add a database here and it gets its own identity too.
databases = {
  orders = {
    max_throughput = 1000

    containers = {
      orders = {
        partition_key_paths = ["/customerId"]
      }
      events = {
        partition_key_paths = ["/orderId"]
        default_ttl         = 2592000
      }
    }

    # How a workload becomes this identity without a secret. The issuer is the
    # OIDC issuer of the cluster:
    #
    #   az aks show -g <rg> -n <cluster> --query oidcIssuerProfile.issuerUrl -o tsv
    #
    # identity = {
    #   federated_credentials = {
    #     aks = {
    #       issuer  = "https://<region>.oic.prod-aks.azure.com/<tenant>/<uuid>/"
    #       subject = "system:serviceaccount:orders:orders-api"
    #     }
    #   }
    # }
  }

  billing = {
    max_throughput = 1000

    containers = {
      invoices = {
        partition_key_paths = ["/customerId"]
      }
    }

    # Someone else's identity or a group, on this database only. Object IDs,
    # not client IDs:
    #
    #   az identity show -g <rg> -n <identity> --query principalId -o tsv
    #   az ad group show --group <name> --query id -o tsv
    #
    # reader_principal_ids = ["00000000-0000-0000-0000-000000000000"]
  }
}

# Account wide data access, which reaches every database. Empty on purpose.
#
# account_reader_principal_ids = ["00000000-0000-0000-0000-000000000000"]

# Reached over a private endpoint in an existing subnet. Without either this or
# `public_network_access_enabled`, the apply warns that nothing can reach the
# account.
#
# private_endpoint_subnet_id = "/subscriptions/.../subnets/private-endpoints"
# private_dns_zone_ids       = ["/subscriptions/.../privateDnsZones/privatelink.documents.azure.com"]

# The other way in, for a prototype without a virtual network. Both of these
# together, or neither.
#
# public_network_access_enabled = true
# ip_range_filter               = ["203.0.113.0/24"]

tags = {
  environment = "prototype"
  managed_by  = "terraform"
}
