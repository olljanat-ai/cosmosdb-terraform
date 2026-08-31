# cosmosdb-terraform

Minimal Terraform module that creates an Azure Cosmos DB account with the
MongoDB API, the databases you list, and access to them.

Two ways to grant that access, and they can be combined:

* **A user per database.** Each database gets its own Mongo RBAC user that
  inherits the built-in `dbOwner` role in that database only. The user owns its
  own database completely and cannot reach any of the others.
* **Microsoft Entra ID identities.** Managed identities, service principals,
  groups or users are granted an Azure role on the account, so they authenticate
  with their own token and no password is stored anywhere. See the
  [limitations](#entra-id-access) below.

## Usage

```hcl
module "cosmosdb" {
  source = "github.com/olljanat-ai/cosmosdb-terraform"

  name                = "contoso-mongo"
  resource_group_name = azurerm_resource_group.example.name
  location            = azurerm_resource_group.example.location

  databases = [
    { name = "orders", throughput = 400 },
    { name = "invoices", max_throughput = 1000 },
  ]
}
```

`terraform output -json database_users` then returns the username, password and
ready made connection string of each database.

## Examples

* [`examples/password-authentication`](examples/password-authentication) - a
  user per database, isolated from each other.
* [`examples/entra-id-authentication`](examples/entra-id-authentication) - no
  database passwords at all, two managed identities with different access
  levels.

## Databases and their users

`databases` is a list, but the resources are keyed by database name, so
reordering the list does not recreate anything.

```hcl
databases = [
  {
    name           = "orders"
    throughput     = 400            # or max_throughput for autoscale
    username       = "orders-app"   # defaults to the database name
    password       = null           # generated when unset
    role_names     = ["dbOwner"]    # full ownership of this database
  },
]
```

`role_names` accepts the Mongo built-in roles `read`, `readWrite`, `dbAdmin` and
`dbOwner`, and any custom role that exists in the same database. It defaults to
`dbOwner`, and because a Cosmos DB user definition is scoped to a single
database, that ownership does not extend past it.

Per-database users need the `EnableMongoRoleBasedAccessControl` capability,
which the module enables by default.

Generated passwords live in the Terraform state. Use an encrypted remote
backend, or pass passwords in from a secret store through
`databases[*].password`.

## Entra ID access

```hcl
entra_id_access = [
  {
    principal_id         = azurerm_user_assigned_identity.app.principal_id
    role_definition_name = "DocumentDB Account Contributor"
    principal_type       = "ServicePrincipal"
  },
]
```

Azure Cosmos DB for MongoDB on the RU model has no data plane Entra ID
authentication: the engine accepts `SCRAM-SHA-256` credentials only, and
`MONGODB-OIDC` is not offered. Entra ID access therefore works on the control
plane. The principal proves who it is to Azure, reads the account connection
string with its own token, and connects with that. Nothing needs a stored
password, and removing the role assignment removes the access.

The trade-off is granularity. An Azure role assignment is scoped to the account,
so it reaches every database in it, and the read-write keys come from `listKeys`
which only `DocumentDB Account Contributor` holds. Use the per-database users
when you need isolation between databases, and Entra ID when you need to avoid
passwords. Setting both gives applications their own database user and operators
their identity.

Data plane Entra ID authentication for MongoDB exists on the vCore deployment
model, which is a different service without Mongo RBAC user definitions, and is
out of scope for this module.

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `name` | Cosmos DB account name, globally unique | `string` | required |
| `resource_group_name` | Resource group of the account | `string` | required |
| `location` | Azure region of the write region | `string` | required |
| `databases` | Databases to create, see above | `list(object)` | `[]` |
| `create_database_users` | Create a user per database | `bool` | `true` |
| `entra_id_access` | Entra ID principals to grant access to | `list(object)` | `[]` |
| `mongo_rbac_enabled` | Enable the Mongo RBAC capability | `bool` | `true` |
| `mongo_server_version` | MongoDB server version | `string` | `"7.0"` |
| `additional_capabilities` | Extra Cosmos DB capabilities | `list(string)` | `[]` |
| `consistency_level` | Consistency level of the account | `string` | `"Session"` |
| `max_interval_in_seconds` | Staleness window, `BoundedStaleness` only | `number` | `null` |
| `max_staleness_prefix` | Stale requests tolerated, `BoundedStaleness` only | `number` | `null` |
| `secondary_locations` | Regions to replicate to, in failover order | `list(string)` | `[]` |
| `zone_redundant` | Zone redundancy in every region | `bool` | `false` |
| `automatic_failover_enabled` | Enable automatic failover | `bool` | `null`, true when replicated |
| `public_network_access_enabled` | Allow public network access | `bool` | `true` |
| `ip_range_filter` | Allowed client IPs or CIDR ranges | `list(string)` | `[]` |
| `tags` | Tags applied to the account | `map(string)` | `{}` |

## Outputs

| Name | Description |
| --- | --- |
| `id` | Resource ID of the account |
| `name` | Name of the account |
| `endpoint` | Endpoint of the account |
| `mongodb_host` | MongoDB host name, port 10255, TLS required |
| `database_ids` | Resource ID per database name |
| `database_users` | Username, password and connection string per database, sensitive |
| `primary_mongodb_connection_string` | Account level connection string, sensitive |
| `entra_id_role_assignment_ids` | Role assignment ID per granted principal |

## Requirements

Terraform >= 1.3, `hashicorp/azurerm` >= 4.0, `hashicorp/random` >= 3.5.
