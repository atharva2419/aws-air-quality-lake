# -----------------------------------------------------------------------------
# variables.tf
#
# Input variables are the knobs of this configuration. Set them in
# terraform.tfvars (see terraform.tfvars.example), with -var on the command
# line, or via TF_VAR_<name> environment variables. Variables without a
# default are required; Terraform prompts for them if they're missing.
# -----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Short prefix used in resource names. Keep it lowercase with no spaces, since S3 bucket names require that."
  type        = string
  default     = "aqlake"
}

variable "alert_email" {
  description = "Email address that receives SNS alerts. AWS sends a confirmation email you must click."
  type        = string
  # No default: you must supply this.
}

variable "aqi_alert_threshold" {
  description = "An alert email is sent when a city's US AQI rises above this value (100 is the top of the 'moderate' band)."
  type        = number
  default     = 100
}

variable "cities" {
  description = "Cities to collect air quality for. Open-Meteo is queried by coordinates; the name is only a label stored with the data."
  type = list(object({
    name      = string
    latitude  = number
    longitude = number
  }))
  default = [
    { name = "New York", latitude = 40.7128, longitude = -74.0060 },
    { name = "Los Angeles", latitude = 34.0522, longitude = -118.2437 },
    { name = "San Francisco", latitude = 37.7749, longitude = -122.4194 },
    { name = "Phoenix", latitude = 33.4484, longitude = -112.0740 },
    { name = "Miami", latitude = 25.7617, longitude = -80.1918 },
    { name = "Chicago", latitude = 41.8781, longitude = -87.6298 },
    { name = "Seattle", latitude = 47.6062, longitude = -122.3321 },
    { name = "Houston", latitude = 29.7604, longitude = -95.3698 },
    { name = "Washington DC", latitude = 38.9072, longitude = -77.0369 },
    { name = "Atlanta", latitude = 33.7490, longitude = -84.3880 },
  ]
}
