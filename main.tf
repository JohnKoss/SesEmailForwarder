provider "aws" {
  region = "us-east-1"
}

# data "archive_file" "lambda_zip" {
#   type        = "zip"
#   source_file = "main.go"
#   output_path = "main.zip"
# }

locals {
  src_path     = "main.go"
  binary_path  = "bootstrap"
  archive_path = "bootstrap.zip"
}

resource "null_resource" "function_binary" {
 triggers = {
     file1 = "${sha1(file("main.go"))}"
  }
  provisioner "local-exec" {
    command = "go build -mod=readonly -o ${local.binary_path} ${local.src_path}"
    environment = {
      GOOS        = "linux"
      GOARCH      = "amd64"
      CGO_ENABLED = "0"
      GOFLAGS     = "-trimpath"
    }
  }
}

// zip the binary, as we can use only zip files to AWS lambda
data "archive_file" "lambda_zip" {
  depends_on = [null_resource.function_binary]

  type        = "zip"
  source_file = local.binary_path
  output_path = local.archive_path
}

resource "aws_lambda_function" "ses_email_forwarder" {
  function_name = "ses_email_forwarder"
  description   = "Forward SES emails to a different email address"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "bootstrap"
  runtime          = "provided.al2023"
  memory_size      = 128
  timeout          = 10

  role = aws_iam_role.ses_email_forwarder.arn

  environment {
    variables = {
      S3_BUCKET    = "mail.clearbyte.io"
      FORWARD_TO   = "kossjohn@gmail.com"
    }
  }
}

// create log group in cloudwatch to gather logs of our lambda function
resource "aws_cloudwatch_log_group" "log_group" {
  name              = "/aws/lambda/${aws_lambda_function.ses_email_forwarder.function_name}"
  retention_in_days = 1
}

resource "aws_iam_role_policy" "ses_email_forwarder_policy" {
  name = "ses_email_forwarder_policy"
  role = aws_iam_role.ses_email_forwarder.id

  # Terraform's "jsonencode" function converts a
  # Terraform expression result to valid JSON syntax.
  policy = jsonencode({
    "Version" : "2012-10-17",
    "Statement" : [
      {
        "Sid" : "VisualEditor0",
        "Effect" : "Allow",
        "Action" : [
          "logs:CreateLogStream",
          "logs:CreateLogGroup",
          "logs:PutLogEvents"
        ],
        "Resource" : "*"
      },
      {
        "Sid" : "VisualEditor1",
        "Effect" : "Allow",
        "Action" : [
          "s3:GetObject",
          "s3:PutObject",
          "ses:SendRawEmail"
        ],
        "Resource" : [
          "arn:aws:s3:::mail.clearbyte.io/*",
          "arn:aws:ses:us-east-1:658914799523:identity/*"
        ]
      }
    ]
  })
}


resource "aws_iam_role" "ses_email_forwarder" {
  name = "ses_email_forwarder"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_lambda_permission" "allow_cloudwatch" {
  statement_id  = "AllowExecutionFromSES"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ses_email_forwarder.function_name
  principal     = "ses.amazonaws.com"
  #source_arn    = "arn:aws:events:eu-west-1:111122223333:rule/RunDaily"
  #qualifier     = aws_lambda_alias.test_alias.name
}

####### clearbyte.com inbound mail ########
// info@ and john@clearbyte.com are received by SES instead of Google Workspace:
// each message is saved to the mail bucket, then forwarded to FORWARD_TO.
// Mail to any other clearbyte.com address matches no rule and is bounced.

// The rule set is the account's active one, made by hand with its clearbyte.io
// rule. Only one rule set can be active in a region, so the rule is added to it
// by name rather than in a set of its own.
resource "aws_ses_receipt_rule" "clearbyte_com" {
  name          = "clearbyte_com_forward"
  rule_set_name = "email.clearbyte.io"
  recipients    = ["info@clearbyte.com", "john@clearbyte.com"]
  enabled       = true
  scan_enabled  = true
  tls_policy    = "Optional"

  // The forwarder reads each message back by its message id, so no prefix.
  s3_action {
    bucket_name = "mail.clearbyte.io"
    position    = 1
  }

  lambda_action {
    function_arn    = aws_lambda_function.ses_email_forwarder.arn
    invocation_type = "Event"
    position        = 2
  }

  depends_on = [aws_lambda_permission.allow_cloudwatch]
}

data "aws_route53_zone" "clearbyte_com" {
  name = "clearbyte.com"
}

// Replaces the Google Workspace MX records, which were made by hand, so
// allow_overwrite takes the record over. It depends on the rule so mail never
// reaches SES before SES knows what to do with it.
resource "aws_route53_record" "clearbyte_com_mx" {
  zone_id         = data.aws_route53_zone.clearbyte_com.zone_id
  name            = "clearbyte.com"
  type            = "MX"
  ttl             = 300
  records         = ["10 inbound-smtp.us-east-1.amazonaws.com"]
  allow_overwrite = true

  depends_on = [aws_ses_receipt_rule.clearbyte_com]
}