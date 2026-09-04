# Troubleshooting the RU model

The RU model has one authentication mechanism and one authorization mechanism,
and they fail in ways that look alike from the client. This guide is organised
by symptom.

## A database scoped credential reaches every database

The most common report, and almost always a sign that the connection is not
being evaluated by Mongo RBAC at all.

### What this configuration already guarantees

The scope of a user is not something `main.tf` chooses. The provider derives it
from the database the user is attached to.
`azurerm_cosmosdb_mongo_user_definition` takes the database out of
`cosmos_mongo_database_id` and writes it into every role it sends to Azure, so
`inherited_role_names = ["dbOwner"]` becomes
`{"Role": "dbOwner", "Db": "<that one database>"}` and cannot name another
database.

The built-in roles reinforce this. `listDatabases` is a privilege in Cosmos DB's
Mongo RBAC model, and [none of the four built-in roles grant it][roles] — not
`read`, not `readWrite`, not `dbAdmin`, not `dbOwner`. A user created by this
configuration therefore cannot even enumerate the account.

So a credential that lists or reads other databases is not a mis-scoped user.
It is one of the three things below.

### 1. The capability is missing from the live account

```shell
az cosmosdb show \
  --resource-group "<resource-group>" \
  --name "<account>" \
  --query "capabilities[].name" -o tsv
```

The output must contain `EnableMongoRoleBasedAccessControl`. Without it the
account is not running Mongo RBAC, whatever user definitions exist.

**Check the account, never the plan.** Microsoft states that ["changing
capabilities using Azure Resource Manager is not available for Azure Cosmos DB
for MongoDB accounts"][capabilities]. Terraform is Azure Resource Manager.
Capabilities land when the account is *created*; adding one to an account that
already exists is not honoured, and a plan that shows the capability being added
can apply without error and leave the account exactly as it was. This is the
usual cause when the configuration is cherry-picked into a module that manages
an existing account rather than creating a new one.

`main.tf` puts the capability in a local rather than a variable for the same
reason:

```hcl
capabilities = distinct(concat(
  ["EnableMongo", "EnableMongoRoleBasedAccessControl"],
  var.additional_capabilities,
))
```

Merging that resource into a module that builds its own `capabilities` list
drops it silently — the user definition hunk applies cleanly and there is no
conflict to notice.

Enable it out of band. The flag replaces the whole set, so name every capability
the account should keep:

```shell
az cosmosdb update \
  --resource-group "<resource-group>" \
  --name "<account>" \
  --capabilities EnableMongo EnableMongoRoleBasedAccessControl
```

The portal has the same switch under **Features** on the account.

**Enabling it is one way.** Microsoft lists `EnableMongoRoleBasedAccessControl`
as not removable, so an account that has it keeps it. It does not disable the
account keys — see [below](#the-account-keys-still-work).

Re-run `terraform apply` afterwards so the user definitions are recreated
against an account that enforces them, and re-check with `az cosmosdb show`.

### 2. The application is holding an account key

Enabling Mongo RBAC does not retire the primary and secondary keys. A key
connects as the account, and an account reaches every database in it, so a
workload that picked up a key sees exactly the symptom above while its scoped
user sits there unused.

Compare what the application has against what the account hands out:

```shell
az cosmosdb keys list \
  --resource-group "<resource-group>" \
  --name "<account>" \
  --type connection-strings \
  --query "connectionStrings[].connectionString" -o tsv
```

If the application's string is in that list, it is a key. The two are easy to
tell apart by eye:

| | Username | Password | `authSource` |
| --- | --- | --- | --- |
| Scoped user | the database user, e.g. `orders` | the generated password | the database name |
| Account key | the account name | a long base64 string ending in `==` | absent, or `admin` |

Two places this configuration can hand out a key. Setting
`key_vault_store_account_connection_string = true` writes
`cosmosdb-primary-connection-string` into the *same* vault as the scoped secret,
so an application reading the wrong secret name gets account-wide access from a
vault that looks correctly locked down. And the
`primary_mongodb_connection_string` output carries a key by definition. Confirm
which secret the workload reads:

```shell
az keyvault secret list --vault-name "<vault>" --query "[].name" -o tsv
```

### 3. `authSource` is wrong

A scoped user authenticates against its own database. If `authSource` names
`admin`, or is missing so the driver defaults to `admin`, authentication is not
happening where the user lives. The string this configuration builds is:

```
mongodb://orders:<password>@<account>.mongo.cosmos.azure.com:10255/orders?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&authMechanism=SCRAM-SHA-256&authSource=orders&appName=@<account>@
```

Both `/orders` and `authSource=orders` are the database name, and
`authMechanism` must be `SCRAM-SHA-256`.

## Checking permissions with other tools

### Azure CLI — what exists

The control plane says what was created. It does not say what is enforced.

```shell
az cosmosdb mongodb user definition list \
  --resource-group "<resource-group>" \
  --account-name "<account>" -o json
```

Each entry carries `databaseName` and a `roles` array. Every `db` in that array
should be the one database:

```json
{
  "id": "<account>/mongodbUserDefinitions/orders.orders",
  "userName": "orders",
  "databaseName": "orders",
  "roles": [{ "db": "orders", "role": "dbOwner" }]
}
```

A `db` naming something else, or a role on `admin`, is over-granted. Passwords
are never returned. Custom roles, if any exist, list separately:

```shell
az cosmosdb mongodb role definition list \
  --resource-group "<resource-group>" \
  --account-name "<account>" -o table
```

The four built-in roles are implicit and do not appear there.

### mongosh — what is enforced

This is the only check that proves anything, because it goes through the data
plane with the real credential.

```shell
mongosh "$(terraform output -raw connection_string)"
```

Cosmos DB does not support the commands that would normally answer "who am I":
[`connectionStatus` is not implemented][commands], and user management commands
such as `db.getUsers()` and `db.createUser()` are not supported either, because
users live in Azure Resource Manager rather than in the database. Probe by
attempting operations instead:

| Probe | Scoped `dbOwner` on `orders` | Account key |
| --- | --- | --- |
| `db.getSiblingDB("orders").events.insertOne({x: 1})` | succeeds | succeeds |
| `db.getSiblingDB("<other database>").events.findOne()` | authorization error | succeeds |
| `show dbs` | authorization error | lists every database |
| `db.getSiblingDB("orders").stats()` | succeeds | succeeds |
| `db.getSiblingDB("<other database>").stats()` | authorization error | succeeds |

The second row is the decisive one; run it against a database the credential has
no business reaching. `show dbs` is the quickest, because `listDatabases` is
granted by no built-in role, so a scoped user seeing output there means RBAC is
not in play.

Note that `stats()` needs `dbStats`, which `dbOwner` and `dbAdmin` have and
`read` and `readWrite` do not. It is a useful way to tell which role a user
actually inherited when `database_role_names` was changed.

### Drivers

The same probe from an application, which also proves the driver is passing
`authSource` through rather than defaulting it:

```python
from pymongo import MongoClient
from pymongo.errors import OperationFailure

client = MongoClient("<connection_string>")
client["<database_name>"].events.insert_one({"hello": "world"})   # expected to work

try:
    client["some-other-database"].events.find_one()
    print("RBAC is NOT being enforced")
except OperationFailure as error:
    print(f"scoped correctly: {error}")
```

MongoDB Compass works too, but it drops `authSource` from some paste formats.
Put it in the string explicitly and connect with the full URI rather than the
field-by-field form.

### The portal Data Explorer is not a check

Data Explorer authenticates with the account keys, so it shows every database in
the account no matter how Mongo RBAC is configured. Seeing other databases there
says nothing about the credential your application holds.

### Diagnostic logs — per request proof

Turn on the `MongoRequests` diagnostic log category for the account and send it
to a Log Analytics workspace. Mongo RBAC adds a `userId` column that names the
user behind each data plane operation, and [that column stays empty when
role-based access control is not enabled][roles]. It is the one signal that
answers the question per request rather than per account:

```kusto
CDBMongoRequests
| where TimeGenerated > ago(1h)
| project TimeGenerated, DatabaseName, CollectionName, OperationName, UserId, ErrorCode
| order by TimeGenerated desc
```

Table and column names depend on the diagnostic setting's destination mode: the
resource-specific mode used above, or Azure diagnostics mode, where the rows
land in `AzureDiagnostics` and the column arrives as `userId_s`. Empty `UserId`
on a request you just made means that request did not go through Mongo RBAC.

## The account keys still work

Nothing above turns the keys off, and this configuration does not either. To
make the scoped user the only way in, disable local authentication on the
account:

```hcl
resource "azurerm_cosmosdb_account" "this" {
  # ...
  local_authentication_enabled = false
}
```

This is deliberately not set here. It breaks the portal Data Explorer, the
`primary_mongodb_connection_string` output, `az cosmosdb keys list` as a way in,
and any tooling that authenticates with a key — so it is a decision about the
whole account rather than a default. Turn it on once every consumer is known to
be using a scoped user, which the diagnostic log query above will tell you.

## Symptom index

| Symptom | Most likely cause |
| --- | --- |
| Credential reaches every database | Capability missing from the live account, or an account key in use |
| `show dbs` returns databases | Same — no built-in role grants `listDatabases` |
| Terraform plan added the capability, nothing changed | Capabilities cannot be changed through Azure Resource Manager on an existing account |
| Authentication fails outright | `authSource` or `authMechanism` wrong, or the password was rotated outside Terraform |
| `db.stats()` denied for a user that should own the database | Role is `read` or `readWrite`, not `dbOwner`; check `database_role_names` |
| Secrets write fails with 403 during apply | Key Vault role assignment has not propagated; raise `key_vault_rbac_propagation_delay` |
| `userId` empty in `MongoRequests` | Mongo RBAC is not enabled on the account |

[roles]: https://learn.microsoft.com/en-us/azure/cosmos-db/mongodb/role-based-access-control
[capabilities]: https://learn.microsoft.com/en-us/azure/cosmos-db/mongodb/how-to-configure-capabilities
[commands]: https://learn.microsoft.com/en-us/azure/cosmos-db/mongodb/feature-support-42
