variable "prefix" {
  description = "Prefix for the names of the created resources. The Cosmos DB account name must be globally unique."
  type        = string
  default     = "example-cosmos"
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "West Europe"
}
