package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDecision(t *testing.T) {
	for _, tc := range []struct {
		name     string
		token    string
		identity agentIdentity
		err      error
		want     int
	}{
		{"gpt41 allowed", "Bearer example", agentIdentity{"kagent", "diag-lecture-gpt41", "uid"}, nil, 204},
		{"gptoss allowed", "Bearer example", agentIdentity{"kagent", "diag-lecture", "uid"}, nil, 204},
		{"third agent denied", "Bearer example", agentIdentity{"kagent", "witness", "uid"}, nil, 403},
		{"different namespace denied", "Bearer example", agentIdentity{"other", "diag-lecture", "uid"}, nil, 403},
		{"incomplete identity denied", "Bearer example", agentIdentity{"kagent", "diag-lecture", ""}, nil, 403},
		{"resolver failure blocks", "Bearer example", agentIdentity{}, errors.New("unavailable"), 503},
		{"missing token rejected", "", agentIdentity{}, nil, 401},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resolved := false
			handler := authorizer(map[string]bool{"kagent/diag-lecture": true, "kagent/diag-lecture-gpt41": true},
				func(_ context.Context, token string) (agentIdentity, error) {
					resolved = true
					if token != "example" {
						t.Fatalf("unexpected resolver token")
					}
					return tc.identity, tc.err
				})
			req := httptest.NewRequest(http.MethodPost, "/check", nil)
			req.Header.Set("Authorization", tc.token)
			req.Header.Set("X-Agent-Name", "diag-lecture")
			res := httptest.NewRecorder()
			handler.ServeHTTP(res, req)
			if res.Code != tc.want || resolved != (tc.token != "") || strings.Contains(res.Body.String(), "example") {
				t.Fatalf("status %d, resolver called %t", res.Code, resolved)
			}
		})
	}
}
