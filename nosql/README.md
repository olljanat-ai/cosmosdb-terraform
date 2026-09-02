# Cosmos DB for NoSQL, one identity per database

Terraform configuration for one Azure Cosmos DB account with the **NoSQL API**,
holding **several databases**, where each database has a **managed identity of
its own**. Key based authentication is off, so the account has no credential to
hand out: an identity is granted data access to one database, over Microsoft
Entra ID, and reaches nothing else in the account.

The account, its databases and its containers come from the [Azure Verified
Module][avm] for `Microsoft.DocumentDB/databaseAccounts`. The identities and the
data plane role assignments are next to it, because the module does not cover
those — see [Azure Verified Modules](#azure-verified-modules).

```
main.tf            resource group, account module, per database identities and role assignments
variables.tf       inputs
outputs.tf         endpoint, identities, database scopes
versions.tf        Terraform and provider constraints
prototype.tfvars   the prototype environment
```

The other variants are [`../vcore`](../vcore), the MongoDB API with Entra ID
only, and [`../ru`](../ru), the MongoDB API with a username and password. See
[Choosing between the three](#choosing-between-the-three).

## Usage

Everything below runs in this folder, not in the repository root.

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

cd nosql
terraform init
terraform plan -var-file=prototype.tfvars
terraform apply -var-file=prototype.tfvars
```

`account_name` becomes a public DNS name, so change it in `prototype.tfvars`
before the first apply. `databases` may not be empty: an account with no
database is one nothing can use, and it is also the condition under which the
module underneath applies `local_authentication_disabled`.

Another environment is another `.tfvars` file next to this one, applied into its
own workspace or state.

## What gets created

* One resource group.
* One Cosmos DB account, NoSQL API, key based authentication disabled, public
  network access off.
* One database per entry in `databases`, with its containers.
* One user assigned managed identity per database, unless that database sets
  `identity = { enabled = false }`.
* One data plane role assignment per identity, `Cosmos DB Built-in Data
  Contributor` scoped to that identity's own database.
* Further data plane role assignments for the principals listed per database,
  and for the account wide principals, when there are any.
* Federated identity credentials for the identities that declare them.
* One private endpoint, when `private_endpoint_subnet_id` is set.
* One diagnostic setting, when `log_analytics_workspace_id` is set.

## Authentication

**Microsoft Entra ID, and nothing else.** The account is created with
`local_authentication_disabled = true`, which takes the account keys out of
service: the primary and secondary keys, the read only keys and the connection
strings built from them all stop working, and the resource manager can no longer
hand them to anyone. A client presents an Entra ID token instead, and the SDK
takes a credential rather than a key:

```python
from azure.cosmos import CosmosClient
from azure.identity import DefaultAzureCredential

credential = DefaultAzureCredential(managed_identity_client_id="<client-id>")

container = (
    CosmosClient("<endpoint>", credential)
    .get_database_client("orders")
    .get_container_client("orders")
)

container.upsert_item({"id": "1", "customerId": "c1", "total": 42})
```

`<client-id>` is the `client_id` of the identity created for that database, from
the `database_identities` output, and `<endpoint>` is the `endpoint` output.
Neither one is a secret: the identity proves itself, the endpoint only says
where to go.

### Why there is no Key Vault

The RU model variant keeps a Key Vault because it has a password to keep. Here
there is no key and no password, so there is nothing to store, nothing to
rotate, and no vault to run. That is the same reason [`../vcore`](../vcore) has
no vault, arrived at from the other end: vCore removes the password by speaking
`MONGODB-OIDC`, this removes it by turning key based authentication off.

## Authorization

Cosmos DB has two role systems, and this configuration uses the second one:

* **Azure role assignments** are the control plane. They manage the account —
  create databases, read the configuration, and, through `listKeys`, read the
  account keys. Terraform uses this plane, and the module exposes it as
  `role_assignments`, which this configuration does not use.
* **Data plane role assignments** are the documents. They are a Cosmos DB
  specific resource, `sqlRoleAssignments` on the account, and they are the only
  thing that grants access to the data itself.

A data plane assignment is scoped by path, and that is what makes an identity
specific to one database:

```
<account resource id>                        every database in the account
<account resource id>/dbs/orders             one database and everything in it
<account resource id>/dbs/orders/colls/x     one container
```

Each database gets `Cosmos DB Built-in Data Contributor` — read, write, query
and change feed, on containers and items — at its own `/dbs/<name>` scope, and
nothing wider. The `database_scopes` output prints the scope of each database.

The identity of the `orders` database therefore reads and writes `orders`,
cannot see a document in `billing`, and cannot list the databases of the account
at all: the metadata action the SDK needs is granted at the database scope, which
covers reading that database and listing its containers, not enumerating the
account. Point the client straight at its own database, as the example above
does, rather than discovering databases at runtime.

Two things the data plane roles deliberately do not grant:

* **Creating or deleting a database or a container.** That is a control plane
  operation, which is why Terraform still does it and why a compromised workload
  identity cannot restructure the account.
* **Changing throughput.** The metadata action does not cover it.

Beyond the identity of each database:

* `contributor_principal_ids` and `reader_principal_ids` per database — another
  workload's identity, or the group that operates that one database.
* `account_contributor_principal_ids` and `account_reader_principal_ids` —
  account wide, every database. Empty by default, because access that stops at
  one database is the point of this configuration. A reporting identity that
  reads everything, or a migration job that spans databases, goes here and is
  worth an argument in review.

The object ID of a principal is not its client ID:

```shell
az identity show --resource-group <rg> --name <identity> --query principalId -o tsv
az ad group show --group <name> --query id -o tsv
```

## Workload identity

A managed identity becomes a *workload* identity when something outside Azure
can prove it is that identity. `federated_credentials` is that trust: an OIDC
issuer and the subject it asserts, so a Kubernetes service account or a pipeline
exchanges its own token for one of the identity, with no secret in between.

```hcl
databases = {
  orders = {
    identity = {
      federated_credentials = {
        aks = {
          issuer  = "https://<region>.oic.prod-aks.azure.com/<tenant>/<uuid>/"
          subject = "system:serviceaccount:orders:orders-api"
        }
      }
    }
  }
}
```

The issuer of an AKS cluster comes from the cluster:

```shell
az aks show -g <rg> -n <cluster> --query oidcIssuerProfile.issuerUrl -o tsv
```

The pod then runs under the service account named in `subject`, annotated with
the `client_id` of that database's identity, and `DefaultAzureCredential` picks
the federated token up on its own. A GitHub Actions workflow uses the same
mechanism with `https://token.actions.githubusercontent.com` as the issuer and
`repo:<owner>/<repo>:ref:refs/heads/main` as the subject.

Leave `federated_credentials` out and the identity is still a plain managed
identity, which is what an Azure resource — a container app, a function, a
virtual machine — attaches directly.

## Multiple databases

Adding a database is adding an entry to `databases`. It gets its own identity,
its own role assignment and its own scope, and nothing about the other databases
changes:

```hcl
databases = {
  orders = {
    max_throughput = 1000
    containers = {
      orders = { partition_key_paths = ["/customerId"] }
    }
  }

  billing = {
    throughput = 400
    containers = {
      invoices = { partition_key_paths = ["/customerId"] }
    }
  }
}
```

Throughput is per database (`throughput` or `max_throughput`) or per container,
not both at once for the same object, and switching a database between
provisioned and autoscale after it exists is not something Terraform can do in
place — the module documents that as a destroy and recreate.

This is the variant to reach for when several databases have to stay apart. The
MongoDB variants cannot do it: `../ru` scopes a user to a database but has no
identity to give it, and `../vcore` has identities but no scope below the whole
cluster.

## Networking

Public network access is off. The account is reached over a private endpoint,
created by setting `private_endpoint_subnet_id`, with a
`privatelink.documents.azure.com` private DNS zone in `private_dns_zone_ids` so
the account name resolves to the private address. A multi region account
publishes one private address per region behind the same endpoint, and the zone
group registers them.

A prototype without a virtual network can turn `public_network_access_enabled`
on instead and list the addresses it is reached from in `ip_range_filter`. Rules
without public access on are rejected here rather than silently ignored, and an
account with neither is warned about.

## Secrets in state

There is no key and no password to leak: they are disabled on the account, and
nothing here writes one into an output. The state holds resource IDs, the object
and client IDs of the identities, and the shape of the environment — identifiers
rather than credentials, but still worth an encrypted remote backend.

Turning `local_authentication_disabled` off again is not exposed as an input.
Doing it by hand re-enables keys that this configuration never had a use for.

## Azure Verified Modules

The account comes from
[`Azure/avm-res-documentdb-databaseaccount/azurerm`][avm] version `0.10.0`,
pinned so that an upgrade of the module is a decision rather than a surprise. It
creates the account, the SQL databases, the containers, the private endpoint and
the diagnostic setting, and it defaults `local_authentication_disabled` to
true — it applies that setting only when the account has at least one SQL
database, which is why `databases` may not be empty.

What it does not do is the data plane: it has no
`azurerm_cosmosdb_sql_role_definition` or `azurerm_cosmosdb_sql_role_assignment`
in it, and its `role_assignments` input is Azure role assignments, the control
plane. Granting an identity access to the documents in one database is therefore
this configuration's own work, in `main.tf`, and it is the part worth reading.

The module also carries customer managed keys, analytical storage, locks,
virtual network rules, Gremlin and MongoDB databases and more. Reaching any of
it is a matter of adding the input to `module "cosmosdb"`.

`terraform plan` prints one deprecation warning from inside the module, about
`local_authentication_disabled` on `azurerm_cosmosdb_account`: the provider is
renaming it to `local_authentication_enabled`. It comes from the module's own
code, so it stays until the module is updated, and it is also why the azurerm
major version here is pinned to 4.

## Choosing between the three

| | [`../ru`](../ru) | [`../vcore`](../vcore) | this folder |
| --- | --- | --- | --- |
| API | MongoDB | MongoDB | NoSQL |
| Resource type | `databaseAccounts` | `mongoClusters` | `databaseAccounts` |
| Authentication | Username and password | Entra ID (`MONGODB-OIDC`) | Entra ID (token) |
| Secret to manage | Password, in a Key Vault | None | None |
| Databases | One, by Terraform | Many, by the client | Many, by Terraform |
| Access scope | Per database, no identity | Whole cluster | Per database, per identity |
| Identity per database | No | No | Yes |

An existing MongoDB application picks one of the MongoDB variants. Everything
else, and anything that needs several databases kept apart, belongs here.

## Sources

* [Connect using role-based access control and Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control)
  — data plane role assignments, the scope formats quoted above, and disabling
  key based authentication.
* [Data plane security reference](https://learn.microsoft.com/en-us/azure/cosmos-db/reference-data-plane-security)
  — the built-in role IDs `...0001` and `...0002`, the actions they include, and
  what the metadata action allows at account, database and container scope.
* [`Azure/avm-res-documentdb-databaseaccount/azurerm`][avm] — the Azure Verified
  Module the account comes from.
* [Microsoft Entra Workload ID](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview)
  and [Azure AD Workload Identity on AKS](https://learn.microsoft.com/en-us/azure/aks/workload-identity-overview)
  — the federated credential mechanism.

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `resource_group_name` | Resource group holding the environment | `string` | required |
| `location` | Azure region and write region | `string` | required |
| `account_name` | Account name, globally unique | `string` | required |
| `databases` | The databases, their containers, their identities and their principals | `map(object)` | required, at least one |
| `account_contributor_principal_ids` | Principals reading and writing every database | `list(string)` | `[]` |
| `account_reader_principal_ids` | Principals reading every database | `list(string)` | `[]` |
| `consistency_level` | Consistency level of the account | `string` | `"Session"` |
| `max_interval_in_seconds` | Staleness window, `BoundedStaleness` only | `number` | `null` |
| `max_staleness_prefix` | Stale requests tolerated, `BoundedStaleness` only | `number` | `null` |
| `secondary_locations` | Regions to replicate to, in failover order | `list(string)` | `[]` |
| `zone_redundant` | Zone redundancy in every region | `bool` | `false` |
| `automatic_failover_enabled` | Service managed failover | `bool` | `null`, true when replicated |
| `public_network_access_enabled` | Allow public network access | `bool` | `false` |
| `ip_range_filter` | Allowed client IPs, needs public access | `list(string)` | `[]` |
| `private_endpoint_subnet_id` | Subnet of the private endpoint | `string` | `null` |
| `private_dns_zone_ids` | Private DNS zones of the private endpoint | `list(string)` | `[]` |
| `log_analytics_workspace_id` | Workspace receiving diagnostics | `string` | `null` |
| `enable_telemetry` | AVM deployment telemetry | `bool` | `true` |
| `tags` | Tags applied to every resource | `map(string)` | `{}` |

`databases` is keyed by database name:

```hcl
databases = {
  orders = {
    throughput     = null          # RU/s, or
    max_throughput = 1000          # autoscale RU/s, one of the two

    identity = {
      enabled = true               # create an identity for this database
      name    = null               # defaults to id-<account>-<database>
      federated_credentials = {
        aks = {
          issuer   = "https://..."
          subject  = "system:serviceaccount:orders:orders-api"
          audience = ["api://AzureADTokenExchange"]
        }
      }
    }

    contributor_principal_ids = []  # object IDs, this database only
    reader_principal_ids      = []

    containers = {
      orders = {
        partition_key_paths   = ["/customerId"]
        partition_key_version = 2
        throughput            = null
        max_throughput        = null
        default_ttl           = null
        unique_key_paths      = [["/externalId"]]
      }
    }
  }
}
```

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_name` | Name of the resource group |
| `account_id` | Resource ID of the account |
| `account_name` | Name of the account |
| `endpoint` | Endpoint of the account, carries no credential |
| `database_names` | Names of the databases created |
| `database_identities` | Per database identity: name, client ID, principal ID, resource ID, tenant ID |
| `database_scopes` | The data plane scope of each database |
| `local_authentication_disabled` | Whether key based authentication is off, always true here |

## Requirements

Terraform >= 1.9 and < 2.0, `hashicorp/azurerm` ~> 4.0, and through the module
`azure/modtm` ~> 0.3, `hashicorp/random` ~> 3.6 and `hashicorp/time` ~> 0.12.

The azurerm major version is pinned to 4 because that is what the Azure Verified
Module accepts, the same reason [`../vcore`](../vcore) is, and unlike
[`../ru`](../ru), which is on azurerm 5.

[avm]: https://registry.terraform.io/modules/Azure/avm-res-documentdb-databaseaccount/azurerm/0.10.0
