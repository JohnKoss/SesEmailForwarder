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

  role = aws_iam_role.ses_email_forwarder.arn

  environment {
    variables = {
      S3_BUCKET    = "mail.clearbyte.io"
      FORWARD_TO   = "john@clearbyte.com"
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