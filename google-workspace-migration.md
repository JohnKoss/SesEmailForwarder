# Moving clearbyte.com mail from Google Workspace to Amazon SES

Google Workspace was used only to receive mail for info@clearbyte.com and
john@clearbyte.com and pass it to kossjohn@gmail.com. Amazon SES now does
that job in the same AWS account (658914799523) that already sends the
website's contact-form mail, so the Workspace subscription is no longer
needed.

Change made on 2026-11-08, commit `5779537` in this repository.

## How mail flows now

Receiving:

1. A sender's server looks up the clearbyte.com MX record and finds
   `inbound-smtp.us-east-1.amazonaws.com`.
2. SES matches the recipient against the receipt rule `clearbyte_com_forward`
   in the active rule set `email.clearbyte.io`. Only info@clearbyte.com and
   john@clearbyte.com are listed. Mail to any other clearbyte.com address
   matches no rule and is bounced.
3. The rule saves the raw message to the S3 bucket `mail.clearbyte.io`
   (us-east-2), with the SES message id as the object key.
4. The rule then invokes the Lambda function `ses_email_forwarder`
   asynchronously.
5. The function reads the message back from S3, rewrites its address headers
   and sends it to kossjohn@gmail.com with `SendRawEmail`.

Sending (replies as info@ or john@):

1. Gmail's "Send mail as" sends through the SES SMTP endpoint
   `email-smtp.us-east-1.amazonaws.com`, port 587, TLS, with IAM SMTP
   credentials.
2. SES signs the message with the clearbyte.com DKIM key and uses
   `mail.clearbyte.com` as the MAIL FROM domain, so SPF, DKIM and DMARC all
   align with the From address.

## What was already in place

These existed before the change and were reused:

| Item | Where it is managed |
| --- | --- |
| SES identity `clearbyte.com`, verified, with Easy DKIM (three `_domainkey` CNAME records) | `www.clearbyte.com` terraform |
| Custom MAIL FROM `mail.clearbyte.com` (MX to `feedback-smtp.us-east-1.amazonaws.com`, SPF TXT) | `www.clearbyte.com` terraform |
| SES production access (sends to any address, 50,000 a day) | AWS account setting |
| Receipt rule set `email.clearbyte.io`, active, with rule `email_clearbyte_io_student_labs` | made by hand in the console |
| S3 bucket `mail.clearbyte.io` with a policy allowing SES to write | made by hand in the console |
| Lambda `ses_email_forwarder` and its IAM role | this repository |

The clearbyte.io rule receives nothing, because clearbyte.io has no MX record.

## Changes in this repository

### main.tf

- `FORWARD_TO` changed from john@clearbyte.com to kossjohn@gmail.com.
  john@clearbyte.com is now one of the forwarded addresses, so leaving it as
  the destination would have sent its mail back into the same rule.
- New resource `aws_ses_receipt_rule.clearbyte_com` (rule
  `clearbyte_com_forward`):
  - recipients: info@clearbyte.com, john@clearbyte.com
  - scan enabled, TLS optional
  - action 1: save to S3 bucket `mail.clearbyte.io`, no key prefix (the
    forwarder reads each message by its message id)
  - action 2: invoke `ses_email_forwarder`, invocation type `Event`
  - added to the existing rule set by name, because only one receipt rule set
    can be active in a region
- New resource `aws_route53_record.clearbyte_com_mx`: clearbyte.com MX
  `10 inbound-smtp.us-east-1.amazonaws.com`, TTL 300.
  - `allow_overwrite = true` takes over the Google MX records, which were
    made by hand.
  - It depends on the receipt rule, so no mail reaches SES before the rule
    exists.

### main.go

- **From address.** The forwarded message is now sent from the clearbyte.com
  address it arrived at (the first SES receipt recipient), under the original
  sender's display name, or the sender's address when there is no name.
  Before, the From was copied from the message's `To` header. Mail that
  reaches info@ by Cc or Bcc has another domain's address there, and SES
  refuses to send as an address it has not verified, so that mail was lost.
- **Spam and viruses.** A message whose SES spam or virus verdict is `FAIL`
  is kept in S3 but not forwarded. Forwarded mail is signed by clearbyte.com,
  so spam passed on to Gmail would count against the domain.
- **Headers dropped.** `Sender`, `Message-Id` and `DKIM-Signature` are no
  longer copied. SES writes its own Message-Id and DKIM signature, and the
  original signature does not verify once From and To are rewritten.
- **Reply-To** is unchanged: the original Reply-To, or the original From when
  there is none, so a reply goes to the person who wrote.

The same commit includes earlier uncommitted changes: the dependency update in
`go.mod` and `go.sum`, the 10 second Lambda timeout and the
"All mails processed successfully" log line.

### Checks run

- The Lambda builds for linux/amd64 and `terraform validate` passes.
- Three unit tests of the new logic passed in a scratch copy: the From
  address, the headers that are dropped (in `net/mail` canonical form) and the
  spam skip.
- `main_test.go` was not run. It reads from the live bucket and sends real
  mail, and it imports `main` as a package, which Go does not allow, so it
  does not compile.

## DNS before and after

| Record | Before | After |
| --- | --- | --- |
| clearbyte.com MX | Google: `aspmx.l.google.com` (1), `alt1` and `alt2` (5), `alt3` (10); TTL 60 | `inbound-smtp.us-east-1.amazonaws.com` (10); TTL 300 |

Nothing else in the clearbyte.com zone changed. The domain is registered with
Amazon Registrar (auto-renew on) and its DNS is in Route 53, so neither
depends on Google.

## Gmail setup for replying as info@ and john@

1. **SES SMTP credentials.** In the SES console (US East, N. Virginia), open
   **SMTP settings** and choose **Create IAM credentials** under
   **IAM SMTP credentials**. Do not use the Mail Manager credentials: their
   password rotates through Secrets Manager, which breaks the password Gmail
   stores, and Mail Manager processing is charged. The SMTP password is shown
   once. The credentials work only in us-east-1.
2. **Add each address in Gmail.** Go to **Settings → Accounts and Import →
   Send mail as → Add another email address**, with **Treat as an alias**
   checked. Then fill in:
   - SMTP server: `email-smtp.us-east-1.amazonaws.com` (Gmail fills in
     `smtp.gmail.com`, which fails with "Authentication error")
   - Port: 587
   - Username and password: the SES SMTP credentials
   - Secured connection using TLS
3. **Confirm.** Gmail mails a confirmation link to each address, and the
   forwarder passes it on. If it cannot be found in Gmail, search
   `in:anywhere subject:"Gmail Confirmation"`. Gmail can file these in Spam,
   because they arrive from a clearbyte.com address but say they are from the
   Gmail Team. A copy is also in the `mail.clearbyte.io` bucket. Use the first
   link in the message, which confirms the request. The second link cancels it.
4. **Choose the address when replying.** The **From** line appears only once
   an address is verified. Click the recipient line of a reply, or use
   **Pop out reply**, then pick the address. Gmail does not pick it
   automatically, because the forwarder rewrites `To` to kossjohn@gmail.com.

## Removing Google Workspace

Before deleting:

- Export the info@ and john@ mailboxes and any Drive or Calendar data with
  **Data Export** in the Admin console or with Google Takeout. Canceling the
  subscription deletes the data, and it cannot be restored.
- Save the invoices and receipts. They cannot be reached after deletion.
- Move any site that uses **Sign in with Google** as john@clearbyte.com to a
  password or another account.

Steps, in admin.google.com as the super administrator:

1. **Menu → Billing → Subscriptions.** Click the Google Workspace
   subscription, then **Cancel Subscription**. Pick a reason, then click
   **Continue**, **Continue to cancel**, the confirmation box, your email
   address and **Cancel My Subscription**. A Cloud Identity Free subscription
   cannot be canceled and does not need to be.
2. **Menu → Account → Account settings → Account management.** Click
   **Delete Account**, check the confirmation box and click **Delete Account**
   again.

After deletion, all clearbyte.com users and groups in Google are deleted, the
admin account cannot sign in to Google services, and Google frees the domain
within 24 hours. Mail to info@ and john@ and sending as them are unaffected,
since neither uses Google any more.

Source: Google Workspace Help, "Delete your organization's Google Account"
(https://support.google.com/a/answer/9468554).

## Checking and troubleshooting

- **Was a message received?** Each one is an object in `mail.clearbyte.io`,
  newest by `LastModified`.
- **Was it forwarded?** The log group `/aws/lambda/ses_email_forwarder` (kept
  for 1 day) has a `Processing mail from` / `Processing mail to` pair and a
  `SUCCESS!!!` line for each message, or `Not forwarding` for spam and
  viruses.
- **Did Gmail accept it?** The account-level CloudWatch metrics in namespace
  `AWS/SES` (`Send`, `Delivery`, `Bounce`, `Reject`) count each send. A
  `Delivery` means Gmail's server accepted the message. If it is not in the
  inbox, look in Spam or for a Gmail filter.
- **Was the Gmail address suppressed?** `aws sesv2 list-suppressed-destinations`
  lists addresses SES no longer sends to after a hard bounce.
- **Rolling back to Google** (only while the Workspace account still exists):
  set the clearbyte.com MX record back to the four Google servers listed
  above. Do not destroy the terraform record instead: that removes the MX
  record entirely, and mail to clearbyte.com would have nowhere to go.

## Open items

- The forwarder writes the whole forwarded message to its CloudWatch log after
  each send, so every received email is copied into the log for 1 day. Logging
  only the sender and recipient is a one-line change.
- Keeping the original `To` header (instead of replacing it with
  kossjohn@gmail.com) would let Gmail's "Reply from the same address the
  message was sent to" setting pick info@ or john@ automatically.
- The S3 bucket keeps a copy of every received message. Its lifecycle
  configuration decides how long.
- `main_test.go` does not compile and calls live AWS. It needs rewriting as a
  test with no AWS calls.
