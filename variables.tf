variable "resource_group_name" {
  description = "Name of the resource group that holds the whole environment."
  type        = string
}

variable "location" {
  description = "Azure region of the environment and of the Cosmos DB write region."
  type        = string
}

variable "cosmosdb_account_name" {
  description = "Name of the single Cosmos DB account. Must be globally unique, 3-44 characters, lowercase letters, numbers and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$", var.cosmosdb_account_name))
    error_message = "`cosmosdb_account_name` must be 3-44 characters of lowercase letters, numbers and hyphens, and may not start or end with a hyphen."
  }
}

variable "databases" {
  description = <<-EOT
    MongoDB databases created in the account. All of them live in the same account.

    * `name`           - Database name.
    * `throughput`     - Provisioned throughput in RU/s. Conflicts with `max_throughput`. Leave both unset for a database without dedicated throughput.
    * `max_throughput` - Maximum autoscale throughput in RU/s. Conflicts with `throughput`.
    * `create_user`    - Create a dedicated user for this database. Set to false for databases reached through Entra ID identities only.
    * `username`       - Username of the database owner. Defaults to the database name.
    * `password`       - Password of the database owner. A strong random password is generated when unset.
    * `role_names`     - Mongo roles granted to the user on this database only. Defaults to `dbOwner`, which is full ownership of that single database.
  EOT

  type = list(object({
    name           = string
    throughput     = optional(number)
    max_throughput = optional(number)
    create_user    = optional(bool, true)
    username       = optional(string)
    password       = optional(string)
    role_names     = optional(list(string), ["dbOwner"])
  }))
  default = []

  validation {
    condition     = length(distinct([for db in var.databases : db.name])) == length(var.databases)
    error_message = "Every entry in `databases` must have a unique `name`."
  }

  validation {
    condition     = alltrue([for db in var.databases : db.throughput == null || db.max_throughput == null])
    error_message = "`throughput` and `max_throughput` are mutually exclusive, set at most one of them per database."
  }

  validation {
    condition     = alltrue([for db in var.databases : length(db.role_names) > 0])
    error_message = "`role_names` must contain at least one Mongo role."
  }
}

variable "entra_id_identities" {
  description = <<-EOT
    User assigned managed identities created for this environment and granted access to the
    Cosmos DB account. They authenticate with their own Entra ID token instead of a database
    password. Attach them to whatever runs the workload, for example a Container App, an AKS
    pod through workload identity, or a VM.

    * `name`                 - Name of the managed identity.
    * `role_definition_name` - Azure built-in role to assign. Defaults to `Cosmos DB Account Reader Role`,
                               which grants the read-only keys. Use `DocumentDB Account Contributor`
                               when the identity also needs to write.
  EOT

  type = list(object({
    name                 = string
    role_definition_name = optional(string, "Cosmos DB Account Reader Role")
  }))
  default = []

  validation {
    condition     = length(distinct([for i in var.entra_id_identities : i.name])) == length(var.entra_id_identities)
    error_message = "Every entry in `entra_id_identities` must have a unique `name`."
  }
}

variable "entra_id_access" {
  description = <<-EOT
    Entra ID principals that already exist and are granted access to the Cosmos DB account.
    Use this for identities owned elsewhere, groups of operators, and service principals of
    other teams.

    * `principal_id`         - Object ID of the identity, service principal, group or user.
    * `role_definition_name` - Azure built-in role to assign.
    * `principal_type`       - `User`, `Group` or `ServicePrincipal`. Set it for freshly created
                               identities to avoid replication errors during apply.
  EOT

  type = list(object({
    principal_id         = string
    role_definition_name = optional(string, "Cosmos DB Account Reader Role")
    principal_type       = optional(string)
  }))
  default = []

  validation {
    condition = length(distinct([
      for a in var.entra_id_access : "${a.principal_id}|${a.role_definition_name}"
    ])) == length(var.entra_id_access)
    error_message = "Every entry in `entra_id_access` must have a unique combination of `principal_id` and `role_definition_name`."
  }
}

variable "mongo_rbac_enabled" {
  description = "Enable the `EnableMongoRoleBasedAccessControl` capability. Required for per-database users."
  type        = bool
  default     = true
}

variable "mongo_server_version" {
  description = "MongoDB server version exposed by the account."
  type        = string
  default     = "7.0"
}

variable "additional_capabilities" {
  description = "Extra Cosmos DB capabilities to enable, for example `EnableMongoRetryableWrites`. `EnableMongo` is always enabled."
  type        = list(string)
  default     = []
}

variable "consistency_level" {
  description = "Consistency level of the account. One of `BoundedStaleness`, `ConsistentPrefix`, `Eventual`, `Session` or `Strong`."
  type        = string
  default     = "Session"

  validation {
    condition     = contains(["BoundedStaleness", "ConsistentPrefix", "Eventual", "Session", "Strong"], var.consistency_level)
    error_message = "`consistency_level` must be one of BoundedStaleness, ConsistentPrefix, Eventual, Session or Strong."
  }
}

variable "max_interval_in_seconds" {
  description = "Staleness window in seconds. Only valid when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "max_staleness_prefix" {
  description = "Number of stale requests tolerated. Only valid when `consistency_level` is `BoundedStaleness`."
  type        = number
  default     = null
}

variable "secondary_locations" {
  description = "Additional Azure regions the data is replicated to, in failover priority order."
  type        = list(string)
  default     = []
}

variable "zone_redundant" {
  description = "Enable zone redundancy in every region of the account."
  type        = bool
  default     = false
}

variable "automatic_failover_enabled" {
  description = "Enable automatic failover. Defaults to true when `secondary_locations` is not empty."
  type        = bool
  default     = null
}

variable "public_network_access_enabled" {
  description = "Allow access to the account from public networks."
  type        = bool
  default     = true
}

variable "ip_range_filter" {
  description = "IP addresses or CIDR ranges allowed to reach the account. An empty list allows every client IP."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource in the environment."
  type        = map(string)
  default     = {}
}

variable "key_vault_enabled" {
  description = "Create a Key Vault and write the database passwords and connection strings into it."
  type        = bool
  default     = true
}

variable "key_vault_name" {
  description = "Name of the Key Vault. Must be globally unique, 3-24 characters, letters, digits and single hyphens, starting with a letter. Defaults to `kv-` plus `cosmosdb_account_name`, truncated to fit."
  type        = string
  default     = null

  validation {
    condition = var.key_vault_name == null || (
      can(regex("^[a-zA-Z][a-zA-Z0-9-]{1,22}[a-zA-Z0-9]$", var.key_vault_name)) && !can(regex("--", var.key_vault_name))
    )
    error_message = "`key_vault_name` must be 3-24 characters of letters, digits and single hyphens, and must start with a letter."
  }
}

variable "key_vault_sku_name" {
  description = "SKU of the Key Vault, `standard` or `premium`."
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "premium"], var.key_vault_sku_name)
    error_message = "`key_vault_sku_name` must be either standard or premium."
  }
}

variable "key_vault_soft_delete_retention_days" {
  description = "Days a deleted Key Vault or secret stays recoverable, 7 to 90. The name of a soft deleted vault stays reserved for this long."
  type        = number
  default     = 7

  validation {
    condition     = var.key_vault_soft_delete_retention_days >= 7 && var.key_vault_soft_delete_retention_days <= 90
    error_message = "`key_vault_soft_delete_retention_days` must be between 7 and 90."
  }
}

variable "key_vault_purge_protection_enabled" {
  description = "Enable purge protection. A protected vault and its secrets cannot be purged before the retention period is over, and the setting cannot be turned off again, so `terraform destroy` leaves the name reserved."
  type        = bool
  default     = false
}

variable "key_vault_public_network_access_enabled" {
  description = "Allow access to the Key Vault from public networks. Terraform writes the secrets over the data plane, so it needs a route to the vault when this is false."
  type        = bool
  default     = true
}

variable "key_vault_grant_deployer_access" {
  description = "Assign `Key Vault Secrets Officer` on the vault to the identity running Terraform. Required for writing the secrets, unless that identity already holds the role higher up in the hierarchy."
  type        = bool
  default     = true
}

variable "key_vault_rbac_propagation_delay" {
  description = "How long to wait after creating the deployer role assignment before writing secrets, for the assignment to reach the Key Vault data plane. Only waited through when the assignment is created."
  type        = string
  default     = "60s"
}

variable "key_vault_secrets_access" {
  description = <<-EOT
    Entra ID principals granted `Key Vault Secrets User` on the vault, which is read access
    to the secret values. The role is scoped to the vault and not to a single secret, so a
    principal listed here reads every database password in it.

    * `principal_id`   - Object ID of the identity, service principal, group or user.
    * `principal_type` - `User`, `Group` or `ServicePrincipal`. Set it for freshly created
                         identities to avoid replication errors during apply.
  EOT

  type = list(object({
    principal_id   = string
    principal_type = optional(string)
  }))
  default = []

  validation {
    condition     = length(distinct([for a in var.key_vault_secrets_access : a.principal_id])) == length(var.key_vault_secrets_access)
    error_message = "Every entry in `key_vault_secrets_access` must have a unique `principal_id`."
  }
}

variable "key_vault_store_account_connection_string" {
  description = "Also write the account level MongoDB connection string into the vault. It carries the account key and reaches every database, and everyone with read access to the vault reads it."
  type        = bool
  default     = false
}
