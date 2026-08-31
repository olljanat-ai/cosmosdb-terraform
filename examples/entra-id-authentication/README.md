# Microsoft Entra ID authentication

Creates a Cosmos DB account with the MongoDB API and two databases, with no
username or password created for them. Access is granted to Microsoft Entra ID
identities instead, so nothing in the deployment holds a database password.

Two identities are created to show both levels:

| Identity     | Azure role                       | Effect                     |
| ------------ | -------------------------------- | -------------------------- |
| `-app`       | `DocumentDB Account Contributor` | read-write account keys    |
| `-reporting` | `Cosmos DB Account Reader Role`  | read-only account keys     |

## Usage

```shell
terraform init
terraform apply -var="prefix=mycompany-dev"
```

Assign the identity to the workload that needs it, for example a Container App,
an AKS pod through workload identity, or a VM. The application then signs in as
itself and asks Azure for the connection string:

```python
from azure.identity import DefaultAzureCredential
from azure.mgmt.cosmosdb import CosmosDBManagementClient
from pymongo import MongoClient

credential = DefaultAzureCredential(managed_identity_client_id="<app_identity_client_id>")
cosmos = CosmosDBManagementClient(credential, "<subscription-id>")

connection_string = cosmos.database_accounts.list_connection_strings(
    "<resource_group_name>", "<account_name>"
).connection_strings[0].connection_string

client = MongoClient(connection_string)
client["orders"].events.insert_one({"hello": "world"})
```

No password is stored anywhere. The identity's Entra ID token is what grants
access, and revoking the role assignment revokes the access.

## How this differs from the password example

Azure Cosmos DB for MongoDB on the RU model has no data plane Entra ID
authentication: `MONGODB-OIDC` is not offered, and the database engine only
accepts `SCRAM-SHA-256` credentials. Entra ID access therefore works one step
up, on the control plane. The principal proves who it is to Azure, Azure hands
it the account connection string, and the driver uses that.

Two consequences are worth knowing before choosing this mode:

* **Access is account wide.** An Azure role assignment is scoped to the Cosmos
  DB account, so an identity that can read the keys reaches every database in
  it. Per-database isolation is what the Mongo RBAC users in the
  [password example](../password-authentication) give you.
* **Read-write means account admin.** The read-write account keys come from
  `listKeys`, which only the `DocumentDB Account Contributor` role holds, and
  that role also manages the account itself. Give it out deliberately.

When you need both, keep `create_database_users = true` and add
`entra_id_access` on top: applications use their own database user, and
operators use their Entra ID identity.

Data plane Entra ID authentication for MongoDB is available on the vCore
deployment model (`azurerm_mongo_cluster`), which is a different service with no
Mongo RBAC user definitions and is out of scope for this module.
