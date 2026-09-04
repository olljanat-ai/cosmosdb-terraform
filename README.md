# cosmosdb-terraform

Terraform for Azure Cosmos DB. The service offers more than one API, and the
MongoDB API offers more than one deployment model; they are separate services
with separate resource types, endpoints, authentication and Terraform
resources. So each one is a root module of its own here.

| Folder | API and model | Authentication | Databases and access |
| --- | --- | --- | --- |
| [`nosql`](nosql) | NoSQL, `databaseAccounts` | Microsoft Entra ID only | Many, each with an identity of its own |
| [`vcore`](vcore) | MongoDB vCore, `mongoClusters` | Microsoft Entra ID only | Many, one access boundary for all |
| [`ru`](ru) | MongoDB RU, `databaseAccounts` | Username and password | One, in a Key Vault |

**Start with [`nosql`](nosql)** unless something already speaks MongoDB. Key
based authentication is off, every database gets a managed identity that reaches
that database and nothing else in the account, and there is no secret anywhere
to store or rotate.

**[`vcore`](vcore)** is the MongoDB API without a password: the cluster accepts
Microsoft Entra ID tokens only, and a workload authenticates with its own
managed identity over `MONGODB-OIDC`. Its limit is that access is cluster wide —
a registered principal is an administrator of the whole cluster — so several
databases in one cluster share one trust boundary.

**[`ru`](ru)** is the MongoDB RU model, which has no Entra ID authentication on
the data plane at all: the engine accepts `SCRAM-SHA-256` and nothing else. It
creates one database with a password and keeps the password in a Key Vault. An
identity can read the password out of the vault, which is as close to workload
identity as that model gets. Its access model has the most ways to go wrong, so
it carries a [troubleshooting guide](ru/TROUBLESHOOTING.md).

Both Entra ID variants come from [Azure Verified Modules][avm].

## Multiple databases

The three differ in what "another database" costs, and the difference is
authorization rather than cost:

* **`nosql`** — a database is a Terraform resource, and a data plane role
  assignment is scoped to `/dbs/<name>`. Adding a database adds an identity and
  a scope, and the databases cannot read each other. This is the one to use when
  several databases have to stay apart.
* **`vcore`** — the cluster holds as many databases as a client cares to create,
  and Terraform creates none of them. There is no per database role: every
  registered principal is `root` on the whole cluster, so isolation means
  another cluster.
* **`ru`** — the account holds many databases and a user is scoped to one of
  them, so isolation exists, but it is a username and a password rather than an
  identity. The configuration creates a single database.

## Usage

Every folder is a root module: `cd` into it, run `terraform init` there, and
keep its state separate from the others.

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

cd nosql   # or vcore, or ru
terraform init
terraform apply -var-file=prototype.tfvars
```

`prototype.tfvars` in each folder holds the values of that variant's prototype
environment, and another environment is another `.tfvars` file next to it.
Every variant names a resource that becomes part of a public DNS name, so change
that name before the first apply.

[avm]: https://azure.github.io/Azure-Verified-Modules/
