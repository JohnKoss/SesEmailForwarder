package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"net/mail"
	"os"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/ses"
	"github.com/aws/aws-sdk-go-v2/service/ses/types"
	"github.com/aws/aws-sdk-go/aws"
)

var (
	sesClient *ses.Client
	s3Client  *s3.Client
)

func init() {
	cfgSes, err := config.LoadDefaultConfig(context.Background(), config.WithRegion("us-east-1"))
	if err != nil {
		log.Fatalf("AWS LoadDefault failed (ses): %s", err)
	}

	sesClient = ses.NewFromConfig(cfgSes)

	cfgS3, err := config.LoadDefaultConfig(context.Background(), config.WithRegion("us-east-2"))
	if err != nil {
		log.Fatalf("AWS LoadDefault failed (s3): %s", err)
	}

	s3Client = s3.NewFromConfig(cfgS3)
}

// Handler processes incoming SES events
func Handler(ctx context.Context, event events.SimpleEmailEvent) error {

	log.Printf("Processing mail event:%+v ", event)

	for _, sesMail := range event.Records {

		log.Printf("Processing mail from %s", sesMail.SES.Mail.Source)
		log.Printf("Processing mail to %s", sesMail.SES.Mail.Destination)

		// Mail SES's scan marked as spam or a virus is kept in S3 but not
		// forwarded: forwarded mail is signed by clearbyte.com, so Gmail would
		// hold the spam against the domain.
		receipt := sesMail.SES.Receipt
		if receipt.SpamVerdict.Status == "FAIL" || receipt.VirusVerdict.Status == "FAIL" {
			log.Printf("Not forwarding %s: spam %s, virus %s", sesMail.SES.Mail.MessageID, receipt.SpamVerdict.Status, receipt.VirusVerdict.Status)
			continue
		}

		if err := forwardMail(&sesMail); err != nil {
			return err
		}
	}
	
	log.Printf("All mails processed successfully")
	return nil
}

// forwardMail forwards the mail to the address specified in the FORWARD_TO environment variable
func forwardMail(original *events.SimpleEmailRecord) error {

	log.Printf("Forwarding mail %+v", original)

	// get original message from S3
	s3Mail, err := getFromS3(original)
	if err != nil {
		return err
	}
	defer s3Mail.Close()

	// parse the original message
	parsedMail, err := mail.ReadMessage(s3Mail)
	if err != nil {
		log.Panicln("Error reading message from S3: ", err)
		return fmt.Errorf("ReadMessage failed: %s", err)
	}

	// parse forwarder FROM and TO addresses
	addrTo, err := mail.ParseAddress(os.Getenv("FORWARD_TO"))
	if err != nil {
		log.Panicln("Error parsing FORWARD_TO address: ", err)
		return fmt.Errorf("ParseAddress failed for FORWARD_TO: %s", err)
	}

	// parse original From and add it to the FORWARD_FROM address
	orgFrom, _ := mail.ParseAddress(parsedMail.Header.Get("From"))
	if orgFrom == nil {
		orgFrom = &mail.Address{}
	}
	// Sent from the clearbyte.com address the mail arrived at, which SES may
	// send as, under the original sender's name.
	if len(original.SES.Receipt.Recipients) == 0 {
		return fmt.Errorf("no receipt recipient for %s", original.SES.Mail.MessageID)
	}
	addrFrom := forwardFrom(orgFrom, original.SES.Receipt.Recipients[0])

	// compose new message in buffer
	newMail := new(bytes.Buffer)

	// add all original headers except address headers
	for h := range parsedMail.Header {
		if skipHeader(h) {
			continue
		}
		fmt.Fprintf(newMail, "%s: %s\r\n", h, parsedMail.Header.Get(h))
	}

	log.Printf("From: %s", addrFrom.String())

	// set from and to
	fmt.Fprintf(newMail, "From: %s\r\n", addrFrom.String())
	fmt.Fprintf(newMail, "To: %s\r\n", addrTo.String())

	// reply-to is the original sender or original reply-to
	rt := parsedMail.Header.Get("Reply-To")
	if rt == "" {
		rt = parsedMail.Header.Get("From")
	}
	fmt.Fprintf(newMail, "Reply-To: %s\r\n", rt)

	// set body
	newMail.WriteString("\r\n")
	_, err = newMail.ReadFrom(parsedMail.Body)
	if err != nil {
		log.Panicln("Error reading mail body: ", err)
		return fmt.Errorf("reading mail body failed: %s", err)
	}

	// send mail
	rawMail := &ses.SendRawEmailInput{
		RawMessage: &types.RawMessage{
			Data: newMail.Bytes(),
		},
	}

	_, err = sesClient.SendRawEmail(context.Background(), rawMail)
	if err != nil {
		log.Panicln("Error sending mail: ", err)
		return fmt.Errorf("SES SendRawEmail failed: %s", err)
	}

	log.Printf("SUCCESS!!! Mail forwarded successfully:%v", newMail.String())
	return nil
}

// forwardFrom is the From of the forwarded mail: the receiving clearbyte.com
// address, named after the original sender. The To header cannot be used: mail
// that arrives by Cc or Bcc has another domain's address there, and SES refuses
// to send as an address it has not verified.
func forwardFrom(orgFrom *mail.Address, recipient string) *mail.Address {
	name := orgFrom.Name
	if name == "" {
		name = orgFrom.Address
	}
	return &mail.Address{Name: name, Address: recipient}
}

// skipHeader returns true if the header should be skipped. The keys are in
// net/mail's canonical form. SES writes its own Message-Id and DKIM signature;
// the original signature no longer verifies once From and To are rewritten.
func skipHeader(h string) bool {
	switch h {
	case "To", "Cc", "Bcc", "From", "Reply-To", "Return-Path", "Sender", "Message-Id", "Dkim-Signature":
		return true
	}
	return false
}

// getFromS3 retrieves the original mail from S3
func getFromS3(original *events.SimpleEmailRecord) (io.ReadCloser, error) {

	log.Printf("Getting mail from S3: %+v", original)

	bucket := os.Getenv("S3_BUCKET")

	log.Printf("Getting mail from S3 bucket %s", bucket)
	log.Printf("Getting mail from S3 key %s", original.SES.Mail.MessageID)

	obj, err := s3Client.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(original.SES.Mail.MessageID),
	})
	if err != nil {
		log.Panicln("Error getting mail from S3: ", err)
		return nil, fmt.Errorf("S3 GetObject failed: %s", err)
	}

	log.Printf("Got mail from S3: %+v", obj)

	return obj.Body, nil
}

// /////////////////////////////////////////////////////
//
// /////////////////////////////////////////////////////
func main() {

	lambda.Start(Handler)
}
