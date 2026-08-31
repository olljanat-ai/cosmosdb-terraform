# cosmosdb-terraform

Terraform configuration for a single Azure Cosmos DB account with the MongoDB
API and the test databases that live in it. Everything is in the root module,
one flat folder, with `prototype.tfvars` holding the values of the prototype
environment.

```
main.tf            resource group, Cosmos DB account, databases, users, identities, Key Vault
variables.tf       inputs
outputs.tf         connection strings, identity client IDs, secret names, resource IDs
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
`-reporting` with read-only access to the account, and a Key Vault holding the
generated passwords.

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

## Key Vault

Every generated password, and the connection string built from it, is written
into a Key Vault created next to the account, so that an application reads its
credentials from the vault instead of from a Terraform output:

```shell
az keyvault secret show --vault-name "$(terraform output -raw key_vault_name)" \
  --name orders-connection-string --query value -o tsv
```

Two secrets per database that has a user of its own, named after the database:

| Secret                       | Contents                                     |
| ---------------------------- | -------------------------------------------- |
| `<database>-password`        | Password of that database's owner            |
| `<database>-connection-string` | Full MongoDB connection string for that database |

Passwords supplied through `databases[*].password` are written too, so the vault
is the one place to look either way. Set `key_vault_enabled = false` to skip the
vault entirely, and `key_vault_store_account_connection_string = true` to add the
account level connection string as `cosmosdb-primary-connection-string`.

The vault uses Azure RBAC rather than access policies. Terraform writes the
secrets over the data plane, so the identity running the apply needs a role on
the vault itself: `key_vault_grant_deployer_access` assigns it `Key Vault Secrets
Officer`, and the apply then waits `key_vault_rbac_propagation_delay` for that
assignment to reach the data plane before writing the first secret. Turn the
grant off when that identity already holds the role higher up in the hierarchy.

Principals in `key_vault_secrets_access` get `Key Vault Secrets User`, which is
read access to the values. **That role is scoped to the vault, not to a single
secret**, so anyone listed there reads every database password in it. The
per-database isolation the Mongo RBAC users give you ends at the vault boundary;
grant this the way you would grant the account keys. It is also why the account
level connection string is not stored by default.

Destroying the vault leaves it soft deleted for
`key_vault_soft_delete_retention_days`, and the name stays reserved for that
long. With `key_vault_purge_protection_enabled = true` it cannot be purged early
at all, and the setting cannot be turned off again once enabled.

## Secrets in state

Generated passwords and the account keys are stored in the Terraform state, the
Key Vault does not change that. Use an encrypted remote backend, or hand
passwords in through `databases[*].password` from a secret store you already
trust.

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
| `key_vault_enabled` | Create a Key Vault and write the secrets into it | `bool` | `true` |
| `key_vault_name` | Name of the Key Vault, globally unique | `string` | `null`, derived from the account name |
| `key_vault_sku_name` | SKU of the Key Vault | `string` | `"standard"` |
| `key_vault_soft_delete_retention_days` | Days a deleted vault or secret stays recoverable | `number` | `7` |
| `key_vault_purge_protection_enabled` | Enable purge protection, cannot be undone | `bool` | `false` |
| `key_vault_public_network_access_enabled` | Allow public network access to the vault | `bool` | `true` |
| `key_vault_grant_deployer_access` | Assign `Key Vault Secrets Officer` to the identity running Terraform | `bool` | `true` |
| `key_vault_rbac_propagation_delay` | Wait after that assignment before writing secrets | `string` | `"60s"` |
| `key_vault_secrets_access` | Principals granted read access to the secret values | `list(object)` | `[]` |
| `key_vault_store_account_connection_string` | Also store the account level connection string | `bool` | `false` |
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
| `key_vault_id` | Resource ID of the Key Vault |
| `key_vault_name` | Name of the Key Vault |
| `key_vault_uri` | URI of the Key Vault |
| `key_vault_secret_names` | Password and connection string secret name per database |
| `primary_mongodb_connection_string` | Account level connection string, sensitive |

## Requirements

Terraform >= 1.3, `hashicorp/azurerm` >= 5.0, `hashicorp/random` >= 3.5,
`hashicorp/time` >= 0.9.

The azurerm floor is 5.0 because the Key Vault is configured with
`rbac_authorization_enabled`, which replaced `enable_rbac_authorization` in that
major version.
