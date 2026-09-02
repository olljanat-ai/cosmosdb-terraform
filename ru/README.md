# Cosmos DB for MongoDB, RU model

Terraform configuration for one Azure Cosmos DB account with the MongoDB API on
the **RU model**, holding **one database** reached with a **username and
password**. That is the only authentication this service offers on the data
plane — see [Authentication](#authentication) for why there is no managed
identity or workload identity option here, and [`../vcore`](../vcore) or
[`../nosql`](../nosql) for the variants that have one.

This is a root module in one flat folder, with `prototype.tfvars` holding the
values of the prototype environment.

```
main.tf            resource group, Cosmos DB account, database, user, Key Vault
variables.tf       inputs
outputs.tf         connection string, secret names, resource IDs
versions.tf        Terraform and provider constraints
prototype.tfvars   the prototype environment
```

## Usage

Everything below runs in this folder, not in the repository root.

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

cd ru
terraform init
terraform plan -var-file=prototype.tfvars
terraform apply -var-file=prototype.tfvars
```

`cosmosdb_account_name` becomes a public DNS name, so change it in
`prototype.tfvars` before the first apply.

Another environment is another `.tfvars` file next to this one, applied into its
own workspace or state.

## What gets created

* One resource group.
* One Cosmos DB account, MongoDB API, with Mongo RBAC enabled.
* One database in it, named by `database_name`.
* One Mongo RBAC user owning that database, with a generated password.
* One Key Vault holding the password and the connection string.

## Authentication

**Username and password, and nothing else.** The Mongo RBAC user inherits the
built-in `dbOwner` role. A Cosmos DB user definition is scoped to a single
database, so the user owns the database and nothing else in the account:

```shell
terraform output -raw connection_string
```

```
mongodb://orders:<password>@<account>.mongo.cosmos.azure.com:10255/orders?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&authMechanism=SCRAM-SHA-256&authSource=orders&appName=@<account>@
```

```python
from pymongo import MongoClient

MongoClient("<connection_string>")["<database_name>"].events.insert_one({"hello": "world"})
```

### Why there is no workload identity here

Azure Cosmos DB for MongoDB on the **RU model** — the service this configuration
creates — has no Microsoft Entra ID authentication on the data plane. The engine
accepts `SCRAM-SHA-256` credentials only; `MONGODB-OIDC`, the mechanism a
MongoDB driver would use with an Entra ID token, is not offered. A managed
identity or a federated workload identity therefore has nothing to authenticate
*to* on the database itself, which is why this configuration creates no identity
and grants no Azure role on the account.

Sources:

* [Configure role-based access control - Azure Cosmos DB for MongoDB](https://learn.microsoft.com/en-us/azure/cosmos-db/mongodb/how-to-setup-rbac)
  — the data plane authorization model for this API. Users are created as user
  definitions with a password, and every driver example authenticates with
  `authMechanism=SCRAM-SHA-256`.
* [Connect using role-based access control and Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/cosmos-db/nosql/how-to-connect-role-based-access-control)
  — Entra ID data plane role-based access control in Cosmos DB, documented for
  the **API for NoSQL**. There is no equivalent for the API for MongoDB (RU).
* [Connect using role-based access control and Microsoft Entra ID - Azure DocumentDB](https://learn.microsoft.com/en-us/azure/documentdb/how-to-connect-role-based-access-control)
  — token based authentication for MongoDB on Azure exists, but on the **vCore**
  deployment model, which is a different service with a different resource type
  and no Mongo RBAC user definitions. That is what [`../vcore`](../vcore)
  configures, and moving there is a migration, not a flag.
* [`azurerm_cosmosdb_mongo_user_definition`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/cosmosdb_mongo_user_definition)
  — the Terraform resource used here. `username` and `password` are the only
  credentials it takes.
* [What are managed identities for Azure resources?](https://learn.microsoft.com/en-us/entra/identity/managed-identities-azure-resources/overview)
  and [Microsoft Entra Workload ID](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview)
  — background on the mechanism that does not apply here.

### What an identity can still do

An Entra ID identity has one useful job in this configuration: reading the
password out of the Key Vault. Put the workload's managed identity object ID in
`key_vault_reader_principal_ids` — the object ID of the identity, not its client
ID — and it fetches the connection string at start up instead of carrying a
password in its configuration:

```python
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from pymongo import MongoClient

credential = DefaultAzureCredential(managed_identity_client_id="<client-id>")
connection_string = SecretClient("<key_vault_uri>", credential).get_secret(
    "<key_vault_connection_string_secret_name>"
).value

MongoClient(connection_string)["<database_name>"].events.insert_one({"hello": "world"})
```

The identity authenticates to Key Vault, not to MongoDB. The database still sees
a username and a password, so this removes the secret from the application's
configuration but not from the system: whoever holds the role on the vault holds
the database password.

One further path exists and is deliberately not built here: an identity with
`DocumentDB Account Contributor` on the account can call `listKeys` over the
control plane and read the account key. That key bypasses the database user and
reaches every database in the account, and the role that grants it also
administers the account, so it is account admin rather than database access.

## Key Vault

The password and the connection string built from it are written into a Key
Vault created next to the account, so that an application reads its credentials
from the vault instead of from a Terraform output:

```shell
az keyvault secret show --vault-name "$(terraform output -raw key_vault_name)" \
  --name "$(terraform output -raw key_vault_connection_string_secret_name)" \
  --query value -o tsv
```

Two secrets, named after the database:

| Secret                         | Contents                                |
| ------------------------------ | --------------------------------------- |
| `<database>-password`          | Password of the database owner          |
| `<database>-connection-string` | Full MongoDB connection string          |

A password supplied through `database_password` is written too, so the vault is
the one place to look either way. Set `key_vault_enabled = false` to skip the
vault entirely, and `key_vault_store_account_connection_string = true` to add
the account level connection string as `cosmosdb-primary-connection-string`.

The vault uses Azure RBAC rather than access policies. Terraform writes the
secrets over the data plane, so the identity running the apply needs a role on
the vault itself: `key_vault_grant_deployer_access` assigns it `Key Vault Secrets
Officer`, and the apply then waits `key_vault_rbac_propagation_delay` for that
assignment to reach the data plane before writing the first secret. Turn the
grant off when that identity already holds the role higher up in the hierarchy.

Every principal in `key_vault_reader_principal_ids` gets `Key Vault Secrets
User`, which is read access to the values. That role is scoped to the vault, not
to a single secret, so grant it the way you would grant the database password
itself. It is also why the account level connection string is not stored by
default.

Destroying the vault leaves it soft deleted for
`key_vault_soft_delete_retention_days`, and the name stays reserved for that
long. With `key_vault_purge_protection_enabled = true` it cannot be purged early
at all, and the setting cannot be turned off again once enabled.

## Rotating the password

Key Vault does not rotate a secret for you. A rotation policy exists for keys,
where `azurerm_key_vault_key` takes a `rotation_policy` block, but a secret has
only `expiration_date` and `not_before_date`, and its value changes when
something writes a new version and not before. Rotating this password is
therefore a question of what does the writing. Nothing here rotates it today.
These are the three shapes it would take.

**Terraform drives it.** A `time_rotating` resource feeds the `keepers` of the
generated password, so it is regenerated once the interval is up, and the same
apply updates the Mongo user definition and writes the new secret version:

```hcl
resource "time_rotating" "password" {
  rotation_days = 90
}

resource "random_password" "this" {
  # ...
  keepers = {
    rotated_at = time_rotating.password.rotation_rfc3339
  }
}
```

That is about fifteen lines, no new Azure resources, and the rotation is visible
in the plan before it happens. The catch is that it only fires while applies
keep running, so it needs a scheduled pipeline behind it: a module nobody
applies never rotates.

**Key Vault drives it.** The Azure-native pattern is an `expiration_date` on the
secret, an Event Grid subscription on the vault's `SecretNearExpiry` event, and
a Function App that generates a password, updates the Cosmos DB user definition
over the ARM API and writes the new secret version. It rotates without anyone
running Terraform, and it costs a Function App, a storage account, a plan, the
Event Grid subscription, role assignments for the function's own identity, and
the function code itself. Terraform also stops owning the password, so
`azurerm_cosmosdb_mongo_user_definition` and the secrets need
`lifecycle { ignore_changes = [...] }` on the password and the values, or the
next apply reverts what the function just rotated.

**Neither one is seamless.** Both cut over in a single step, and there is a
single user, so every connection still holding the old password fails from the
moment it changes until the application re-reads the vault and reconnects.
Rotation without that window needs two users taking turns, where the workload
reads whichever secret is current and only the credential it is not using gets
rotated. That is what Azure's own rotation guidance does for services with two
sets of keys, and it doubles the user and secret resources here, so it trades
directly against the one database and one user this module is built around.

## Secrets in state

The generated password and the account keys are stored in the Terraform state,
the Key Vault does not change that. Use an encrypted remote backend, or hand the
password in through `database_password` from a secret store you already trust.

The `primary_mongodb_connection_string` output carries the account key, which
bypasses the database user and reaches everything. Treat it as a break glass
credential.

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `resource_group_name` | Resource group holding the environment | `string` | required |
| `location` | Azure region | `string` | required |
| `cosmosdb_account_name` | Cosmos DB account name, globally unique | `string` | required |
| `database_name` | Name of the database | `string` | required |
| `database_throughput` | Provisioned throughput in RU/s | `number` | `null` |
| `database_max_throughput` | Autoscale maximum in RU/s, conflicts with the above | `number` | `null` |
| `database_username` | Username of the database owner | `string` | `null`, the database name |
| `database_password` | Password of the database owner | `string` | `null`, generated |
| `database_role_names` | Mongo roles granted on this database | `list(string)` | `["dbOwner"]` |
| `key_vault_enabled` | Create a Key Vault and write the secrets into it | `bool` | `true` |
| `key_vault_name` | Name of the Key Vault, globally unique | `string` | `null`, derived from the account name |
| `key_vault_sku_name` | SKU of the Key Vault | `string` | `"standard"` |
| `key_vault_soft_delete_retention_days` | Days a deleted vault or secret stays recoverable | `number` | `7` |
| `key_vault_purge_protection_enabled` | Enable purge protection, cannot be undone | `bool` | `false` |
| `key_vault_public_network_access_enabled` | Allow public network access to the vault | `bool` | `true` |
| `key_vault_grant_deployer_access` | Assign `Key Vault Secrets Officer` to the identity running Terraform | `bool` | `true` |
| `key_vault_rbac_propagation_delay` | Wait after that assignment before writing secrets | `string` | `"60s"` |
| `key_vault_reader_principal_ids` | Principals granted read access to the secrets | `list(string)` | `[]` |
| `key_vault_store_account_connection_string` | Also store the account level connection string | `bool` | `false` |
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

`database_role_names` accepts the Mongo built-in roles `read`, `readWrite`,
`dbAdmin` and `dbOwner`, and any custom role that exists in the same database.

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_name` | Name of the resource group |
| `cosmosdb_account_id` | Resource ID of the account |
| `cosmosdb_account_name` | Name of the account |
| `endpoint` | Endpoint of the account |
| `mongodb_host` | MongoDB host name, port 10255, TLS required |
| `database_name` | Name of the database |
| `database_id` | Resource ID of the database |
| `database_username` | Username of the database owner |
| `database_password` | Password of the database owner, sensitive |
| `connection_string` | MongoDB connection string of the database, sensitive |
| `key_vault_id` | Resource ID of the Key Vault |
| `key_vault_name` | Name of the Key Vault |
| `key_vault_uri` | URI of the Key Vault |
| `key_vault_password_secret_name` | Name of the password secret |
| `key_vault_connection_string_secret_name` | Name of the connection string secret |
| `primary_mongodb_connection_string` | Account level connection string, sensitive |

## Requirements

Terraform >= 1.3, `hashicorp/azurerm` >= 5.0, `hashicorp/random` >= 3.5,
`hashicorp/time` >= 0.9.

The azurerm floor is 5.0 because the Key Vault is configured with
`rbac_authorization_enabled`, which replaced `enable_rbac_authorization` in that
major version.
