# cosmosdb-terraform

Terraform configuration for one Azure Cosmos DB account with the MongoDB API,
holding **one database** that is reachable in **two ways**: with a username and
password, and with an Azure managed identity. Everything is in the root module,
one flat folder, with `prototype.tfvars` holding the values of the prototype
environment.

```
main.tf            resource group, Cosmos DB account, database, user, managed identity, Key Vault
variables.tf       inputs
outputs.tf         connection string, identity client ID, secret names, resource IDs
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

* One resource group.
* One Cosmos DB account, MongoDB API, with Mongo RBAC enabled.
* One database in it, named by `database_name`.
* One Mongo RBAC user owning that database, with a generated password.
* One user assigned managed identity with access to the account.
* One Key Vault holding the password and the connection string.

## The two ways in

**Username and password.** The Mongo RBAC user inherits the built-in `dbOwner`
role. A Cosmos DB user definition is scoped to a single database, so the user
owns the database and nothing else in the account:

```shell
terraform output -raw connection_string
```

```
mongodb://orders:<password>@<account>.mongo.cosmos.azure.com:10255/orders?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&authMechanism=SCRAM-SHA-256&authSource=orders&appName=@<account>@
```

**Managed identity.** No password in the application's configuration. The
identity signs in as itself and asks Azure for the connection string:

```python
from azure.identity import DefaultAzureCredential
from azure.mgmt.cosmosdb import CosmosDBManagementClient
from pymongo import MongoClient

credential = DefaultAzureCredential(managed_identity_client_id="<managed_identity_client_id>")
cosmos = CosmosDBManagementClient(credential, "<subscription-id>")

connection_string = cosmos.database_accounts.list_connection_strings(
    "<resource_group_name>", "<cosmosdb_account_name>"
).connection_strings[0].connection_string

MongoClient(connection_string)["<database_name>"].events.insert_one({"hello": "world"})
```

The same identity also gets `Key Vault Secrets User` on the vault, so it can
read the database user's connection string instead if you prefer the workload to
connect as that user:

```python
from azure.keyvault.secrets import SecretClient

connection_string = SecretClient("<key_vault_uri>", credential).get_secret(
    "<key_vault_connection_string_secret_name>"
).value
```

Revoking the role assignment revokes the access. Set
`managed_identity_enabled = false` to skip the identity entirely, or
`key_vault_grant_managed_identity_access = false` to keep it off the vault.

### Why managed identity access works this way

Azure Cosmos DB for MongoDB on the RU model has no data plane Entra ID
authentication: the engine accepts `SCRAM-SHA-256` credentials only, and
`MONGODB-OIDC` is not offered. Entra ID access therefore works one level up, on
the control plane. The principal proves who it is to Azure, reads the account
connection string with its own token, and the driver uses that.

Two consequences are worth knowing:

* **Access is account wide.** An Azure role assignment is scoped to the account,
  so an identity that can read the keys reaches every database in it. With one
  database in the account that is the same thing, which is part of why this
  configuration keeps it to one.
* **Read-write means account admin.** The read-write keys come from `listKeys`,
  which only `DocumentDB Account Contributor` holds, and that role also manages
  the account itself. Give it out deliberately, or use
  `managed_identity_role_definition_name = "Cosmos DB Account Reader Role"` for
  read-only access.

Data plane Entra ID authentication for MongoDB is available on the vCore
deployment model, which is a different service with no Mongo RBAC user
definitions and is out of scope here.

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

The managed identity and every principal in `key_vault_reader_principal_ids` get
`Key Vault Secrets User`, which is read access to the values. That role is scoped
to the vault, not to a single secret, so grant it the way you would grant the
database password itself. It is also why the account level connection string is
not stored by default.

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
| `managed_identity_enabled` | Create a managed identity and grant it access | `bool` | `true` |
| `managed_identity_name` | Name of the managed identity | `string` | `null`, derived from the account name |
| `managed_identity_role_definition_name` | Azure role assigned to it on the account | `string` | `"DocumentDB Account Contributor"` |
| `key_vault_enabled` | Create a Key Vault and write the secrets into it | `bool` | `true` |
| `key_vault_name` | Name of the Key Vault, globally unique | `string` | `null`, derived from the account name |
| `key_vault_sku_name` | SKU of the Key Vault | `string` | `"standard"` |
| `key_vault_soft_delete_retention_days` | Days a deleted vault or secret stays recoverable | `number` | `7` |
| `key_vault_purge_protection_enabled` | Enable purge protection, cannot be undone | `bool` | `false` |
| `key_vault_public_network_access_enabled` | Allow public network access to the vault | `bool` | `true` |
| `key_vault_grant_deployer_access` | Assign `Key Vault Secrets Officer` to the identity running Terraform | `bool` | `true` |
| `key_vault_rbac_propagation_delay` | Wait after that assignment before writing secrets | `string` | `"60s"` |
| `key_vault_grant_managed_identity_access` | Let the managed identity read the secrets | `bool` | `true` |
| `key_vault_reader_principal_ids` | Further principals granted read access to the secrets | `list(string)` | `[]` |
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
| `managed_identity_name` | Name of the managed identity |
| `managed_identity_client_id` | Client ID, passed to `DefaultAzureCredential` |
| `managed_identity_principal_id` | Object ID, for role assignments made elsewhere |
| `managed_identity_role_definition_name` | Azure role it holds on the account |
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
