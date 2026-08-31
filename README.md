# cosmosdb-terraform

Terraform configuration for a single Azure Cosmos DB account with the MongoDB
API and the test databases that live in it. Everything is in the root module,
one flat folder, with `prototype.tfvars` holding the values of the prototype
environment.

```
main.tf            resource group, Cosmos DB account, databases, users, identities
variables.tf       inputs
outputs.tf         connection strings, identity client IDs, resource IDs
versions.tf        Terraform and provider constraints
prototype.tfvars   the prototype environment
```

## Usage

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

terraform init
terraform plan -var-file=prototype.tfvars
terraform apply -var-file=prototype.tfvars
```

`cosmosdb_account_name` becomes a public DNS name, so change it in
`prototype.tfvars` before the first apply.

Another environment is another `.tfvars` file next to this one, applied into its
own workspace or state.

## What gets created

One Cosmos DB account, and all databases inside that single account. The
prototype covers three different types of database side by side:

| Database    | Throughput           | Access                                       |
| ----------- | -------------------- | -------------------------------------------- |
| `orders`    | provisioned 400 RU/s | own user, `dbOwner` on `orders` only         |
| `invoices`  | autoscale to 1000 RU/s | own user `invoices-app`, `dbOwner` on `invoices` only |
| `telemetry` | account default      | no user at all, Entra ID identities only     |

Plus two user assigned managed identities, `-app` with read-write access and
`-reporting` with read-only access to the account.

## The two ways in

**A user per database.** Each database with `create_user = true` gets its own
Mongo RBAC user inheriting the built-in `dbOwner` role. A Cosmos DB user
definition is scoped to a single database, so the user owns its own database
completely and cannot reach any of the others in the account. Passwords are
generated unless supplied:

```shell
terraform output -json database_users | jq -r '.orders.connection_string'
```

```
mongodb://orders:<password>@<account>.mongo.cosmos.azure.com:10255/orders?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&authMechanism=SCRAM-SHA-256&authSource=orders&appName=@<account>@
```

**Entra ID identities.** No password exists anywhere. The identity signs in as
itself and asks Azure for the connection string:

```python
from azure.identity import DefaultAzureCredential
from azure.mgmt.cosmosdb import CosmosDBManagementClient
from pymongo import MongoClient

credential = DefaultAzureCredential(managed_identity_client_id="<client_id from entra_id_identities>")
cosmos = CosmosDBManagementClient(credential, "<subscription-id>")

connection_string = cosmos.database_accounts.list_connection_strings(
    "<resource_group_name>", "<cosmosdb_account_name>"
).connection_strings[0].connection_string

MongoClient(connection_string)["telemetry"].events.insert_one({"hello": "world"})
```

Revoking the role assignment revokes the access.

### Why Entra ID access works this way

Azure Cosmos DB for MongoDB on the RU model has no data plane Entra ID
authentication: the engine accepts `SCRAM-SHA-256` credentials only, and
`MONGODB-OIDC` is not offered. Entra ID access therefore works one level up, on
the control plane. The principal proves who it is to Azure, reads the account
connection string with its own token, and the driver uses that.

Two consequences are worth knowing:

* **Access is account wide.** An Azure role assignment is scoped to the account,
  so an identity that can read the keys reaches every database in it.
  Per-database isolation is what the Mongo RBAC users give you.
* **Read-write means account admin.** The read-write keys come from `listKeys`,
  which only `DocumentDB Account Contributor` holds, and that role also manages
  the account itself. Give it out deliberately.

That is why the prototype uses both: `orders` and `invoices` are isolated from
each other behind their own users, and `telemetry` is the database reached
without any password.

Data plane Entra ID authentication for MongoDB is available on the vCore
deployment model, which is a different service with no Mongo RBAC user
definitions and is out of scope here.

## Secrets in state

Generated passwords and the account keys are stored in the Terraform state. Use
an encrypted remote backend, or hand passwords in through
`databases[*].password` from a secret store you already trust.

The `primary_mongodb_connection_string` output carries the account key, which
bypasses the per-database users and reaches everything. Treat it as a break
glass credential.

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `resource_group_name` | Resource group holding the environment | `string` | required |
| `location` | Azure region | `string` | required |
| `cosmosdb_account_name` | Cosmos DB account name, globally unique | `string` | required |
| `databases` | Databases to create, see below | `list(object)` | `[]` |
| `entra_id_identities` | Managed identities to create and grant access to | `list(object)` | `[]` |
| `entra_id_access` | Existing Entra ID principals to grant access to | `list(object)` | `[]` |
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
| `tags` | Tags applied to every resource | `map(string)` | `{}` |

A `databases` entry:

```hcl
{
  name           = "orders"
  throughput     = 400            # or max_throughput for autoscale, not both
  create_user    = true           # false leaves the database to Entra ID identities
  username       = "orders-app"   # defaults to the database name
  password       = null           # generated when unset
  role_names     = ["dbOwner"]    # full ownership of this database
}
```

`role_names` accepts the Mongo built-in roles `read`, `readWrite`, `dbAdmin` and
`dbOwner`, and any custom role that exists in the same database.

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_name` | Name of the resource group |
| `cosmosdb_account_id` | Resource ID of the account |
| `cosmosdb_account_name` | Name of the account |
| `endpoint` | Endpoint of the account |
| `mongodb_host` | MongoDB host name, port 10255, TLS required |
| `database_ids` | Resource ID per database name |
| `database_users` | Username, password and connection string per database, sensitive |
| `entra_id_identities` | Client ID, principal ID and role per created identity |
| `entra_id_role_assignment_ids` | Resource ID per role assignment |
| `primary_mongodb_connection_string` | Account level connection string, sensitive |

## Requirements

Terraform >= 1.3, `hashicorp/azurerm` >= 4.0, `hashicorp/random` >= 3.5.
