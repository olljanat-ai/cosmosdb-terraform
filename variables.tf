variable "resource_group_name" {
  description = "Name of the resource group that holds the whole environment."
  type        = string
}

variable "location" {
  description = "Azure region of the environment and of the Cosmos DB write region."
  type        = string
}

variable "cosmosdb_account_name" {
  description = "Name of the Cosmos DB account. Must be globally unique, 3-44 characters, lowercase letters, numbers and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,42}[a-z0-9]$", var.cosmosdb_account_name))
    error_message = "`cosmosdb_account_name` must be 3-44 characters of lowercase letters, numbers and hyphens, and may not start or end with a hyphen."
  }
}

variable "database_name" {
  description = "Name of the MongoDB database created in the account."
  type        = string
}

variable "database_throughput" {
  description = "Provisioned throughput of the database in RU/s. Conflicts with `database_max_throughput`. Leave both unset for a database without dedicated throughput."
  type        = number
  default     = null
}

variable "database_max_throughput" {
  description = "Maximum autoscale throughput of the database in RU/s. Conflicts with `database_throughput`."
  type        = number
  default     = null

  validation {
    condition     = var.database_max_throughput == null || var.database_throughput == null
    error_message = "`database_throughput` and `database_max_throughput` are mutually exclusive, set at most one of them."
  }
}

variable "database_username" {
  description = "Username of the database owner. Defaults to the database name."
  type        = string
  default     = null
}

variable "database_password" {
  description = "Password of the database owner. A strong random password is generated when unset."
  type        = string
  default     = null
  sensitive   = true
}

variable "database_role_names" {
  description = "Mongo roles granted to the user on this database only. `dbOwner` is full ownership of it. Accepts the built-in roles `read`, `readWrite`, `dbAdmin` and `dbOwner`, and any custom role that exists in the database."
  type        = list(string)
  default     = ["dbOwner"]

  validation {
    condition     = length(var.database_role_names) > 0
    error_message = "`database_role_names` must contain at least one Mongo role."
  }
}

variable "mongo_server_version" {
  description = "MongoDB server version exposed by the account."
  type        = string
  default     = "7.0"
}

variable "additional_capabilities" {
  description = "Extra Cosmos DB capabilities to enable, for example `EnableMongoRetryableWrites`. `EnableMongo` and `EnableMongoRoleBasedAccessControl` are always enabled."
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
  description = "Create a Key Vault and write the database password and connection string into it."
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

variable "key_vault_reader_principal_ids" {
  description = "Object IDs of Entra ID principals granted `Key Vault Secrets User` on the vault, which is read access to the secret values. This is where the managed identity of a workload goes, so that it fetches the database password from the vault rather than carrying it in its configuration."
  type        = list(string)
  default     = []

  validation {
    condition     = length(distinct(var.key_vault_reader_principal_ids)) == length(var.key_vault_reader_principal_ids)
    error_message = "`key_vault_reader_principal_ids` must not contain duplicates."
  }
}

variable "key_vault_store_account_connection_string" {
  description = "Also write the account level MongoDB connection string into the vault. It carries the account key and bypasses the database user, and everyone with read access to the vault reads it."
  type        = bool
  default     = false
}
