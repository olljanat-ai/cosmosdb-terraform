# cosmosdb-terraform

Terraform for Azure Cosmos DB with the MongoDB API. Cosmos DB offers that API on
two deployment models, and they are separate services: separate resource types,
separate endpoints, separate authentication, separate Terraform resources. So
each one is a root module of its own here.

| Folder | Deployment model | Authentication | Secret to manage |
| --- | --- | --- | --- |
| [`ru`](ru) | Request units, `Microsoft.DocumentDB/databaseAccounts` | Username and password | Password, in a Key Vault |
| [`vcore`](vcore) | vCore, `Microsoft.DocumentDB/mongoClusters` | Microsoft Entra ID only | None |

**Start with [`vcore`](vcore).** It is the variant where a workload
authenticates to the database with its own managed identity: the cluster is
created with Entra ID as the only allowed authentication mode, password
authentication is off, and there is no Key Vault because there is no secret to
put in one. The cluster comes from the [Azure Verified Module][avm] for
`Microsoft.DocumentDB/mongoClusters`.

[`ru`](ru) is there for the RU model, which has no Entra ID authentication on
the data plane at all: the engine accepts `SCRAM-SHA-256` credentials and
nothing else, so that variant creates a database user with a password and keeps
the password in a Key Vault. Its README explains the constraint and what an
identity can still do around it.

Beyond authentication the two differ in what they create — the RU variant
creates the database, on vCore a database appears when a client first writes
into it — and in how they are billed, request units against provisioned vCores
and storage. Moving from one to the other is a migration rather than a flag.

## Usage

Every folder is a root module: `cd` into it, run `terraform init` there, and
keep its state separate from the other one.

```shell
az login
export ARM_SUBSCRIPTION_ID="<subscription-id>"

cd vcore   # or ru
terraform init
terraform apply -var-file=prototype.tfvars
```

`prototype.tfvars` in each folder holds the values of that variant's prototype
environment, and another environment is another `.tfvars` file next to it.
Both variants name a resource that becomes part of a public DNS name, so change
that name before the first apply.

[avm]: https://registry.terraform.io/modules/Azure/avm-res-documentdb-mongocluster/azurerm/0.3.0
