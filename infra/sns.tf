# -----------------------------------------------------------------------------
# sns.tf
#
# SNS (Simple Notification Service) is pub/sub messaging: publishers send a
# message to a "topic", and every "subscription" on that topic receives it.
# Later, an alerting job will publish here when AQI exceeds the threshold.
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts" # "aqlake-alerts" with the default prefix
}

# Email subscription. After `terraform apply`, AWS emails a confirmation link
# to var.alert_email. The subscription stays "PendingConfirmation" and
# receives nothing until you click it.
resource "aws_sns_topic_subscription" "alert_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
