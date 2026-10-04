package main

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestPrivateServePreservesOtherPortsAndRefusesConflicts(t *testing.T) {
	for _, tc := range []struct {
		raw            string
		ready, blocked bool
	}{
		{`{}`, false, false},
		{`{"TCP":{"443":{"HTTPS":true}},"Web":{"mac.tail.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8888"}}}}}`, false, false},
		{`{"TCP":{"8443":{"HTTPS":true}},"Web":{"mac.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3777"},"/other":{"Proxy":"http://127.0.0.1:8888"}}}}}`, true, false},
		{`{"TCP":{"8443":{"HTTPS":true}},"Web":{"mac.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8888"}}}}}`, false, true},
		{`{"AllowFunnel":{"mac.tail.ts.net:8443":true}}`, false, true},
		{`{"AllowFunnel":{"mac.tail.ts.net:443":true}}`, false, false},
		{`{"Foreground":{"1":{"TCP":{"8443":{"HTTPS":true}}}}}`, false, true},
		{`bad json`, false, true},
	} {
		ready, err := configured([]byte(tc.raw), "mac.tail.ts.net", "8443")
		if ready != tc.ready || (err != nil) != tc.blocked {
			t.Errorf("%s: ready=%v err=%v", tc.raw, ready, err)
		}
	}
}
func TestOnlyExplicitSetupMutatesAndVerifiesServe(t *testing.T) {
	for _, configure := range []bool{false, true} {
		calls := [][]string{}
		configuredNow := false
		run := func(args ...string) ([]byte, error) {
			calls = append(calls, args)
			switch args[0] {
			case "status":
				return []byte(`{"BackendState":"Running","Self":{"DNSName":"mac.tail.ts.net."}}`), nil
			case "serve":
				if args[1] == "--bg" {
					configuredNow = true
					return nil, nil
				}
				if configuredNow {
					return []byte(`{"TCP":{"8443":{"HTTPS":true}},"Web":{"mac.tail.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3777"}}}}}`), nil
				}
			}
			return []byte(`{}`), nil
		}
		result := inspect(run, "8443", configure)
		if configure {
			if result.State != "ready" || !reflect.DeepEqual(calls[2], []string{"serve", "--bg", "--yes", "--https=8443", target}) || len(calls) != 4 {
				t.Fatal(result, calls)
			}
		} else if len(calls) != 2 || result.State != "setup_required" {
			t.Fatal(result, calls)
		}
	}
}
func TestDisconnectedStateNeverAdvertisesAnOriginOrChangesServe(t *testing.T) {
	for _, tc := range []struct {
		name, raw, state string
		signIn           bool
	}{
		{"signed out", `{"BackendState":"NeedsLogin"}`, "auth_required", true},
		{"disconnected account", `{"BackendState":"Stopped","Self":{"DNSName":"mac.tail.ts.net."}}`, "unavailable", false},
		{"starting", `{"BackendState":"Starting","Self":{"DNSName":"mac.tail.ts.net."}}`, "unavailable", false},
		{"missing identity", `{"BackendState":"Running"}`, "unavailable", false},
		{"unknown state", `{"BackendState":"Unknown"}`, "unavailable", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			result := inspect(func(args ...string) ([]byte, error) {
				calls++
				return []byte(tc.raw), nil
			}, "8443", true)
			encoded, _ := json.Marshal(result)
			if calls != 1 || strings.Contains(string(encoded), "origin") || result.State != tc.state || strings.Contains(result.Error, "sign in") != tc.signIn {
				t.Fatal(result, calls)
			}
		})
	}
}
