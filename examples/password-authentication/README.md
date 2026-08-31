# Password authentication

Creates a Cosmos DB account with the MongoDB API and three databases, each with
its own user. Every user inherits the built-in `dbOwner` role in its own
database, which is full ownership of that database and no access at all to the
other two.

The module generates a strong random password per user unless you pass one in
the `databases` entry.

## Usage

```shell
terraform init
terraform apply -var="prefix=mycompany-dev"
```

Read a connection string out afterwards:

```shell
terraform output -json database_users | jq -r '.orders.connection_string'
```

The connection string uses `SCRAM-SHA-256` against the user's own database:

```
mongodb://orders:<password>@<account>.mongo.cosmos.azure.com:10255/orders?ssl=true&replicaSet=globaldb&retrywrites=false&maxIdleTimeMS=120000&authMechanism=SCRAM-SHA-256&authSource=orders&appName=@<account>@
```

## Notes

Generated passwords are stored in the Terraform state. Use an encrypted remote
backend, or hand the password in through `databases[*].password` from a secret
store you already trust.

The `primary_mongodb_connection_string` output carries the account key, which
bypasses the per-database users and reaches everything. Treat it as a break
glass credential.
