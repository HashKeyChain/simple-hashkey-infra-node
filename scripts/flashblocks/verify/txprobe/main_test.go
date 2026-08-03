package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const txHash = "0xaaaa000000000000000000000000000000000000000000000000000000000001"

// rpcStub answers the three methods the probe uses. Each handler receives the number of
// times that method has already been called, which is how a test spells "appears on the
// third poll" without depending on wall-clock timing.
type rpcStub struct {
	calls    map[string]int
	handlers map[string]func(call int) any
}

func newStub() *rpcStub {
	return &rpcStub{calls: map[string]int{}, handlers: map[string]func(int) any{}}
}

func (s *rpcStub) on(method string, fn func(call int) any) *rpcStub {
	s.handlers[method] = fn
	return s
}

func (s *rpcStub) server(t *testing.T) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Method string `json:"method"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Errorf("bad request body: %v", err)
			return
		}
		call := s.calls[req.Method]
		s.calls[req.Method]++

		body := map[string]any{"jsonrpc": "2.0", "id": 1}
		if fn, ok := s.handlers[req.Method]; ok {
			if value := fn(call); value != nil {
				body["result"] = value
			} else {
				body["result"] = nil
			}
		} else {
			body["result"] = nil
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(body)
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func testConfig(send, pending, canonical string) config {
	return config{
		sendURL:      send,
		pendingURL:   pending,
		canonicalURL: canonical,
		raw:          "0xdeadbeef",
		budget:       5 * time.Second,
		interval:     time.Millisecond,
	}
}

func TestProbeSeesPreconfirmationBeforeCanonicalBlock(t *testing.T) {
	pending := newStub().
		on("eth_sendRawTransaction", func(int) any { return txHash }).
		// Visible in pending from the second poll onward.
		on("eth_getBlockByNumber", func(call int) any {
			if call < 1 {
				return map[string]any{"transactions": []string{}}
			}
			return map[string]any{"transactions": []string{txHash}}
		}).
		on("eth_getTransactionReceipt", func(call int) any {
			if call < 1 {
				return nil
			}
			return map[string]any{"status": "0x1", "blockNumber": "0x64"}
		})
	// The canonical side only produces a receipt much later.
	canonical := newStub().
		on("eth_getTransactionReceipt", func(call int) any {
			if call < 5 {
				return nil
			}
			return map[string]any{"status": "0x1", "blockNumber": "0x64"}
		})

	pendingURL := pending.server(t)
	res, err := probe(newClient(time.Second), testConfig(pendingURL, pendingURL, canonical.server(t)))

	if err != nil {
		t.Fatalf("probe returned an error: %v", err)
	}
	if res.txHash != txHash {
		t.Fatalf("txHash = %s, want %s", res.txHash, txHash)
	}
	if res.preMS < 0 {
		t.Fatal("expected the transaction to become visible in pending")
	}
	if res.finalMS < 0 {
		t.Fatal("expected a canonical receipt")
	}
	if res.preMS > res.finalMS {
		t.Fatalf("preconfirmation at %dms must not follow the canonical block at %dms", res.preMS, res.finalMS)
	}
	if res.status != 1 {
		t.Fatalf("status = %d, want 1", res.status)
	}
	if res.block != 100 {
		t.Fatalf("block = %d, want 100", res.block)
	}
}

// A chain that never preconfirms must still report the canonical timings, because
// "included but never preconfirmed" is exactly the failure P4 has to catch.
func TestProbeReportsMissingPreconfirmation(t *testing.T) {
	pending := newStub().
		on("eth_sendRawTransaction", func(int) any { return txHash }).
		on("eth_getBlockByNumber", func(int) any { return map[string]any{"transactions": []string{}} })
	canonical := newStub().
		on("eth_getTransactionReceipt", func(int) any {
			return map[string]any{"status": "0x0", "blockNumber": "0x2a"}
		})

	pendingURL := pending.server(t)
	res, err := probe(newClient(time.Second), testConfig(pendingURL, pendingURL, canonical.server(t)))

	if err != nil {
		t.Fatalf("probe returned an error: %v", err)
	}
	if res.preMS != -1 {
		t.Fatalf("preMS = %d, want -1 when the transaction never appears in pending", res.preMS)
	}
	if res.status != 0 {
		t.Fatalf("status = %d, want 0 for a reverted transaction", res.status)
	}
	if res.block != 42 {
		t.Fatalf("block = %d, want 42", res.block)
	}
}

func TestProbeFailsWhenSubmissionIsRejected(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"nonce too low"}}`))
	}))
	t.Cleanup(srv.Close)

	_, err := probe(newClient(time.Second), testConfig(srv.URL, srv.URL, srv.URL))

	if err == nil {
		t.Fatal("expected an error when the node rejects the transaction")
	}
}

// The transaction never lands, so the probe must return timings rather than blocking.
func TestProbeGivesUpAfterBudget(t *testing.T) {
	stub := newStub().on("eth_sendRawTransaction", func(int) any { return txHash })
	url := stub.server(t)
	cfg := testConfig(url, url, url)
	cfg.budget = 80 * time.Millisecond

	start := time.Now()
	res, err := probe(newClient(time.Second), cfg)

	if err != nil {
		t.Fatalf("probe returned an error: %v", err)
	}
	if res.finalMS != -1 {
		t.Fatalf("finalMS = %d, want -1 when the transaction is never included", res.finalMS)
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("probe took %s, it should have given up after the budget", elapsed)
	}
}

func TestHexToInt(t *testing.T) {
	cases := map[string]int64{"0x0": 0, "0x1": 1, "0x64": 100, "": -1, "0x": -1, "0xzz": -1}
	for input, want := range cases {
		if got := hexToInt(input); got != want {
			t.Errorf("hexToInt(%q) = %d, want %d", input, got, want)
		}
	}
}
