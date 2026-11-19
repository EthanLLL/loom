package main

import (
	"context"
	"strings"
	"testing"
)

func TestADialErrorDoesNotCarryTheToken(t *testing.T) {
	token := "ln_secret+/=token"
	// Nothing listens on port 1: the dial fails, quoting the address.
	_, err := dial(context.Background(), "http://127.0.0.1:1", token, nil)
	if err == nil {
		t.Fatal("dial succeeded")
	}
	if strings.Contains(err.Error(), "secret") {
		t.Fatalf("error carries the token: %v", err)
	}
	if !strings.Contains(err.Error(), "<token>") {
		t.Fatalf("error no longer says where it dialled: %v", err)
	}
}
