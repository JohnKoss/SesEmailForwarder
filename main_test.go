// https://github.com/aws-samples/lambda-go-samples/blob/master/main_test.go

package main_test

import (
	"context"
	"testing"
	"time"

	"github.com/johnkoss/ses_email_forwarder"

	"github.com/aws/aws-lambda-go/events"
	"github.com/stretchr/testify/assert"
)

func TestHandler(t *testing.T) {
	
	t.Setenv("S3_BUCKET", "mail.clearbyte.io")
	t.Setenv("FORWARD_TO", "john@clearbyte.com")
	
	sesEvent := events.SimpleEmailEvent{
		Records: []events.SimpleEmailRecord{
			{
				SES: events.SimpleEmailService{
					Mail: events.SimpleEmailMessage{
						Timestamp: time.Now(),
						Source:    "",
						MessageID: "041n4ufhc6scginva7u891k30jildtiht5esvs81",
						Destination: []string{
							"",
						},
						HeadersTruncated: false,
						Headers: []events.SimpleEmailHeader{
							{
								Name:  "From",
								Value: "bubba@example.com",
							},
							{
								Name:  "To",
								Value: "ttt@example.com",
							},
							{
								Name:  "Subject",
								Value: "Test",
							},
						},
						CommonHeaders: events.SimpleEmailCommonHeaders{
							ReturnPath: "",
							From:       []string{""},
							Date:       "",
							To:         []string{""},
							MessageID:  "",
							Subject:    "",
						},
					},
				},
			},
		},
	}
	err := main.Handler(context.Background(), sesEvent)
	assert.Nil(t, err)
}
