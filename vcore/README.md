# Cosmos DB for MongoDB, vCore model

Terraform configuration for one Azure Cosmos DB for MongoDB **vCore** cluster
that has **no password**. Microsoft Entra ID is the only authentication mode the
cluster accepts, a workload reaches it with its own managed identity, and there
is no Key Vault here because there is no secret to put in one.

The cluster itself comes from the [Azure Verified Module][avm] for
`Microsoft.DocumentDB/mongoClusters`. What this configuration adds is the
posture: Entra ID only, no public network access, no Data API, and an access
list of principals rather than a credential.

```
main.tf            resource group, cluster module, Entra ID users
variables.tf       inputs
outputs.tf         connection string template, resource IDs
versions.tf        Terraform and provider constraints
prototype.tfvars   the prototype environment
```

The other deployment model of the same API lives in [`../ru`](../ru), where a
username and a password are the only thing on offer, and
[`../nosql`](../nosql) is the NoSQL API, which has Entra ID authentication too
and scopes it per database. See
[Choosing between the two](#choosing-between-the-two).

## Usage

Everything below runs in this folder, not in the repository root.

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

cd vcore
terraform init
terraform plan -var-file=prototype.tfvars
terraform apply -var-file=prototype.tfvars
```

`cluster_name` becomes a public DNS name, so change it in `prototype.tfvars`
before the first apply, and fill in at least one principal in
`entra_administrators`: with password authentication off, a cluster with an
empty access list is a cluster nobody can reach, and the apply refuses it.

Another environment is another `.tfvars` file next to this one, applied into its
own workspace or state.

## What gets created

* One resource group.
* One MongoDB vCore cluster, Entra ID as the only authentication mode, public
  network access off.
* One cluster user per principal in `entra_administrators`.
* One private endpoint, when `private_endpoint_subnet_id` is set.
* One diagnostic setting, when `log_analytics_workspace_id` is set.

No database and no collection. On the vCore model those are not Azure
resources — the cluster is the resource, and a database appears the first time a
client writes into it. This is the visible difference from the RU model
configuration in [`../ru`](../ru), which creates the database itself.

## Authentication

**Microsoft Entra ID, and nothing else.** The cluster is created with
`authConfig.allowedModes = ["MicrosoftEntraID"]`, so `NativeAuth`, the username
and password mechanism, is not among the mechanisms it accepts. A workload
authenticates with its own managed identity, the driver presents the Entra ID
token it gets, and no password exists on either side of the connection.

The connection string is the one in the `connection_string_template` output:

```
mongodb+srv://<client-id>@<cluster>.global.mongocluster.cosmos.azure.com/?tls=true&authMechanism=MONGODB-OIDC&retrywrites=false&maxIdleTimeMS=120000
```

`<client-id>` is the **client ID** of the identity that connects, which is the
one part of the string this configuration cannot fill in: the cluster user is
identified by its *object* ID, several identities share one cluster, and which
of them is connecting is known only in the workload. The driver then fetches the
token itself, through an OIDC callback:

```python
from azure.identity import DefaultAzureCredential
from pymongo import MongoClient
from pymongo.auth_oidc import OIDCCallback, OIDCCallbackContext, OIDCCallbackResult

SCOPE = "https://ossrdbms-aad.database.windows.net/.default"


class AzureIdentityTokenCallback(OIDCCallback):
    def __init__(self, credential):
        self.credential = credential

    def fetch(self, context: OIDCCallbackContext) -> OIDCCallbackResult:
        return OIDCCallbackResult(access_token=self.credential.get_token(SCOPE).token)


credential = DefaultAzureCredential(managed_identity_client_id="<client-id>")

client = MongoClient(
    "mongodb+srv://<cluster>.global.mongocluster.cosmos.azure.com/",
    tls=True,
    retryWrites=False,
    connectTimeoutMS=120000,
    authMechanism="MONGODB-OIDC",
    authMechanismProperties={"OIDC_CALLBACK": AzureIdentityTokenCallback(credential)},
)

client["<database>"].events.insert_one({"hello": "world"})
```

The token is requested for `https://ossrdbms-aad.database.windows.net/.default`,
which is the audience this service accepts, and the driver refreshes it through
the same callback when it expires. A token stays valid until it expires even
after the principal behind it is disabled, so revoking access means deleting the
cluster user, not only the identity.

The exact callback shape belongs to the driver rather than to this
configuration, and the Azure documentation carries a current example for
Python, Node.js and .NET — see [Microsoft Entra ID authentication][entra].

### Why there is no Key Vault

The RU model configuration keeps a Key Vault because it has a password to keep:
the identity of the workload authenticates to the vault, reads the password out
of it, and then connects to MongoDB with that password. The vault removes the
secret from the application configuration, not from the system, and whoever
holds the read role on the vault holds the database password.

Here there is no password to hold. The identity authenticates to the database
directly, so the vault would have nothing to store and would only be one more
resource to run, one more role assignment to review, and one more place a
credential could leak from. That is what "skip the Key Vault" buys, and it is
the reason to prefer this variant.

### Native authentication

The cluster API takes an administrator username and password whether or not
native authentication is allowed, and the Azure Verified Module underneath
requires both, so this configuration generates a password for an account called
`nativeauthdisabled` and puts it nowhere: no output worth reading, no vault, no
secret. While `native_authentication_enabled` is false the credential cannot be
used to connect at all, because the cluster does not offer the mechanism it
belongs to.

Azure documents that **native authentication must be enabled when a cluster is
created**, and that it can be disabled once provisioning is finished. Microsoft's
own template samples create a cluster with Entra ID as the only mode, so the
restriction may no longer hold on the API version used here — but if the first
apply is rejected for that reason, the way through is two applies:

```shell
terraform apply -var-file=prototype.tfvars -var native_authentication_enabled=true
terraform apply -var-file=prototype.tfvars
```

The second apply narrows `allowedModes` back to Entra ID only, which is the
documented way to disable password authentication, and changes nothing else.

Setting `native_authentication_enabled = true` permanently is the one thing in
this configuration that undoes the point of it. The password is then a real
credential, and it lives in the Terraform state and in the
`native_administrator_password` output, with no vault around it.

## Authorization

Every principal in `entra_administrators` is created as a cluster user with the
role `root` on the `admin` database, because that is the only role the cluster
user API accepts: `role` is an enum with one value in it. Finer grained roles
for Entra ID principals — read only, or read and write without user
administration — exist on the data plane and are granted there, not through
Azure Resource Manager, so they are outside what Terraform manages here.

Three further limits come from the service, all of them in the [service
limits][limits]:

* **Entra ID groups are not supported.** A principal is a user, an application
  or a managed identity, one entry each.
* **Entra ID authentication is not offered on the free tier.** `compute_tier`
  has to be a paid tier, `M10` upwards. Diagnostic logging is a paid tier
  feature too, and in-region high availability starts at `M30`.
* **A cluster holds 100 users and roles in total**, which is the ceiling on
  `entra_administrators`.

The object ID of a managed identity is not its client ID, and not the resource
ID of the resource it is attached to:

```shell
az identity show --resource-group <rg> --name <identity> --query principalId -o tsv
az ad user show --id <upn> --query id -o tsv
```

The client ID, which is what goes into the connection string, comes from the
same identity:

```shell
az identity show --resource-group <rg> --name <identity> --query clientId -o tsv
```

## Networking

Public network access is off. The cluster is reached over a private endpoint,
created by setting `private_endpoint_subnet_id`, and it needs a
`privatelink.mongocluster.cosmos.azure.com` private DNS zone in
`private_dns_zone_ids` to resolve the name to the private address. Without the
zone the name of the cluster keeps resolving to its public address, where
nothing answers.

A prototype without a virtual network can turn `public_network_access_enabled`
on instead and list the addresses it is reached from in `firewall_rules`. An
empty rule list with public access on is a cluster nothing can reach, and rules
without public access on are silently ignored by the service, so this
configuration rejects the second combination and warns about the first.

## Secrets in state

There is no database credential to leak here, which is most of the point, but
the generated native administrator password is still written to the Terraform
state. It authenticates nothing while `native_authentication_enabled` is false.
Use an encrypted remote backend anyway — the state also carries the shape of the
environment, and turning native authentication on later turns that password into
a real credential.

## Azure Verified Modules

The cluster comes from [`Azure/avm-res-documentdb-mongocluster/azurerm`][avm]
version `0.3.0`, the Azure Verified Module for
`Microsoft.DocumentDB/mongoClusters`, which wraps the ARM API through the AzAPI
provider. It is pinned to an exact version: an AVM release can move the API
version underneath it, and on this resource type several properties are create
time only, so an unpinned upgrade is how a cluster gets replaced.

Two things about that module shape this configuration:

* `administrator_login` and `administrator_login_password` are required inputs
  and always sent to the API, which is why the account described under [Native
  authentication](#native-authentication) exists at all.
* `users` is where the Entra ID principals go, and its `role` is validated
  against the same one value enum as the API.

The module also carries customer managed key encryption, managed identities,
resource locks, role assignments and more than one private endpoint. None of
that is exposed here, and reaching it is a matter of adding the input to
`module "mongo_cluster"` in `main.tf`.

`enable_telemetry` controls the deployment telemetry the module sends to
Microsoft; see <https://aka.ms/avm/telemetryinfo>.

## Sources

* [Connect using role-based access control and Microsoft Entra ID][entra] — the
  data plane authentication model of this service: `allowedModes`, the cluster
  user resource, the connection string and a driver example per language.
* [Service limits and quotas][limits] — the free tier, group and user count
  limits quoted above.
* [`Microsoft.DocumentDB/mongoClusters`](https://learn.microsoft.com/en-us/azure/templates/microsoft.documentdb/mongoclusters)
  and [`mongoClusters/users`](https://learn.microsoft.com/en-us/azure/templates/microsoft.documentdb/2025-09-01/mongoclusters/users)
  — the ARM schema behind the module, where `role` is an enum with `root` as its
  only value and `principalType` is `servicePrincipal` or `user`.
* [`Azure/avm-res-documentdb-mongocluster/azurerm`][avm] — the Azure Verified
  Module the cluster comes from.
* [Microsoft Entra Workload ID](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-overview)
  — background on the mechanism this variant is built around.

## Choosing between the two

| | [`../ru`](../ru) | this folder |
| --- | --- | --- |
| Resource type | `Microsoft.DocumentDB/databaseAccounts` | `Microsoft.DocumentDB/mongoClusters` |
| Authentication | Username and password only | Microsoft Entra ID only |
| Workload identity | To the Key Vault, not to the database | To the database itself |
| Secret to manage | Password, in a Key Vault | None |
| Database created by Terraform | Yes | No, the client creates it |
| Billing | Request units | Provisioned vCores and storage |

Moving from one to the other is a migration rather than a flag: different
resource type, different endpoint, different credentials.

Access here is cluster wide: every principal registered on the cluster is `root`
over all of its databases, because that is the only role the cluster user API
offers. Several databases that must not read each other therefore need several
clusters — or [`../nosql`](../nosql), where a role assignment is scoped to one
database and each database has an identity of its own.

## Inputs

| Name | Description | Type | Default |
| --- | --- | --- | --- |
| `resource_group_name` | Resource group holding the environment | `string` | required |
| `location` | Azure region | `string` | required |
| `cluster_name` | Cluster name, globally unique | `string` | required |
| `entra_administrators` | Entra ID principals allowed to reach the cluster | `map(object)` | required, at least one |
| `native_authentication_enabled` | Also allow username and password authentication | `bool` | `false` |
| `compute_tier` | Compute tier of the cluster | `string` | `"M30"` |
| `storage_size_gb` | Data disk of every node, in GB | `number` | `32` |
| `storage_type` | `PremiumSSD` or `PremiumSSDv2` | `string` | `null`, service default |
| `shard_count` | Number of shards | `number` | `1` |
| `server_version` | MongoDB server version | `string` | `"7.0"` |
| `high_availability_mode` | `Disabled`, `SameZone` or `ZoneRedundantPreferred` | `string` | `"Disabled"` |
| `public_network_access_enabled` | Allow public network access | `bool` | `false` |
| `firewall_rules` | Allowed public IP ranges, needs public access | `list(object)` | `[]` |
| `private_endpoint_subnet_id` | Subnet of the private endpoint | `string` | `null` |
| `private_dns_zone_ids` | Private DNS zones of the private endpoint | `list(string)` | `[]` |
| `data_api_enabled` | Enable the Mongo Data API | `bool` | `false` |
| `log_analytics_workspace_id` | Workspace receiving diagnostics | `string` | `null` |
| `enable_telemetry` | AVM deployment telemetry | `bool` | `true` |
| `tags` | Tags applied to every resource | `map(string)` | `{}` |

`entra_administrators` is keyed by a name of your choosing, and every value has
an `object_id` and an optional `principal_type`, which is `servicePrincipal` for
a managed identity or an application and `user` for a person:

```hcl
entra_administrators = {
  workload = {
    object_id = "00000000-0000-0000-0000-000000000000"
  }
  operator = {
    object_id      = "00000000-0000-0000-0000-000000000000"
    principal_type = "user"
  }
}
```

## Outputs

| Name | Description |
| --- | --- |
| `resource_group_name` | Name of the resource group |
| `cluster_id` | Resource ID of the cluster |
| `cluster_name` | Name of the cluster |
| `mongodb_host` | Host name of the cluster |
| `connection_string_template` | Connection string with `<client-id>` left to the workload |
| `entra_administrator_object_ids` | Object IDs that were granted access, by name |
| `private_endpoint_ids` | Resource IDs of the private endpoints created |
| `native_authentication_enabled` | Whether password authentication is allowed |
| `native_administrator_username` | Username of the native administrator account |
| `native_administrator_password` | Its password, sensitive, unusable while native authentication is off |

## Requirements

Terraform >= 1.9 and < 2.0, `hashicorp/azurerm` ~> 4.0, `hashicorp/random`
~> 3.5, and through the module `Azure/azapi` ~> 2.4 and `azure/modtm` ~> 0.3.

The azurerm major version is pinned to 4 because that is what the Azure Verified
Module accepts, which is also why this is a separate root module from
[`../ru`](../ru) rather than another file in the same folder: that one is on
azurerm 5.

[avm]: https://registry.terraform.io/modules/Azure/avm-res-documentdb-mongocluster/azurerm/0.3.0
[entra]: https://learn.microsoft.com/en-us/azure/documentdb/how-to-connect-role-based-access-control
[limits]: https://learn.microsoft.com/en-us/azure/documentdb/limitations
