# cosmosdb-terraform

Terraform for Azure Cosmos DB with the MongoDB API. Cosmos DB offers that API on
two deployment models that are separate services with separate resource types,
separate authentication and separate Terraform resources, so each one gets its
own root module here.

| Folder | Deployment model | Authentication |
| --- | --- | --- |
| [`ru`](ru) | Cosmos DB for MongoDB, RU model | Username and password, kept in a Key Vault |

Every folder is a root module of its own: `cd` into it, `terraform init` there,
and keep its state separate from the other one. `prototype.tfvars` in each
folder holds the values of that variant's prototype environment.
