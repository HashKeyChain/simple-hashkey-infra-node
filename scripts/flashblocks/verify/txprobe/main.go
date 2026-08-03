// txprobe measures how quickly a transaction becomes visible as a preconfirmation.
//
// Like wscheck, this exists because a shell cannot do the job. The P4 gate is "visible in
// pending, under one second, before the canonical block", and a shell loop cannot measure
// that honestly: BSD date has no millisecond resolution, and every iteration would fork
// curl twice plus jq, which costs tens of milliseconds of its own and varies from one
// iteration to the next. Against a 1000ms threshold that overhead is part of what gets
// measured. Keeping the clock and the RPC calls in one process measures the chain instead
// of the measuring script.
//
// It sends one already-signed transaction and then polls three things until the canonical
// receipt appears:
//
//	pending block on the flashblocks-aware RPC  -> pre_ms
//	receipt on the flashblocks-aware RPC        -> receipt_ms
//	receipt on the canonical RPC                -> final_ms, status, block
//
// Signing stays in cast; this tool never sees a private key. The raw transaction passed in
// is already signed and about to be broadcast publicly, so it is not a secret.
//
// Output is one key=value pair per line for a shell to consume with `eval`:
//
//	ok=1 txhash=0x… pre_ms=180 receipt_ms=181 final_ms=1400 tx_status=1 tx_block=34712
//	ok=0 error=send                  (details are written to stderr)
//
// Keys are deliberately specific, because eval overwrites same-named variables in the
// caller: plain `status` would be a read-only variable if these lines were ever pasted
// into a zsh prompt while debugging.
//
// A negative pre_ms, receipt_ms or final_ms means that event never happened within the
// budget, which the caller must treat differently from zero.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type config struct {
	sendURL      string
	pendingURL   string
	canonicalURL string
	raw          string
	budget       time.Duration
	interval     time.Duration
}

type result struct {
	txHash    string
	preMS     int64
	receiptMS int64
	finalMS   int64
	status    int64
	block     int64
}

func main() {
	cfg := config{}
	flag.StringVar(&cfg.sendURL, "send-url", "", "RPC that receives eth_sendRawTransaction")
	flag.StringVar(&cfg.pendingURL, "pending-url", "", "flashblocks-aware RPC whose pending block is polled")
	flag.StringVar(&cfg.canonicalURL, "canonical-url", "", "RPC used to observe the canonical receipt")
	flag.StringVar(&cfg.raw, "raw", "", "signed transaction, 0x-prefixed")
	budget := flag.Int("timeout", 30, "seconds to wait for the canonical receipt")
	interval := flag.Int("poll-ms", 50, "polling interval in milliseconds")
	flag.Parse()
	cfg.budget = time.Duration(*budget) * time.Second
	cfg.interval = time.Duration(*interval) * time.Millisecond

	if cfg.sendURL == "" || cfg.pendingURL == "" || cfg.canonicalURL == "" || !strings.HasPrefix(cfg.raw, "0x") {
		fmt.Fprintln(os.Stderr, "txprobe: --send-url, --pending-url, --canonical-url and a 0x-prefixed --raw are all required")
		emit("ok", 0)
		emit("error", "usage")
		return
	}

	res, err := probe(newClient(5*time.Second), cfg)
	if err != nil {
		fmt.Fprintf(os.Stderr, "txprobe: %v\n", err)
		emit("ok", 0)
		emit("error", "send")
		return
	}
	if res.finalMS < 0 {
		fmt.Fprintf(os.Stderr, "txprobe: %s was not included within %s\n", res.txHash, cfg.budget)
	}

	emit("ok", 1)
	emit("txhash", res.txHash)
	emit("pre_ms", res.preMS)
	emit("receipt_ms", res.receiptMS)
	emit("final_ms", res.finalMS)
	emit("tx_status", res.status)
	emit("tx_block", res.block)
}

// Allow only these characters in values. Because a shell evaluates this output, content
// that came off the network must never be able to become executable code.
var safeValue = regexp.MustCompile(`^[0-9A-Za-z_.,:/=+@-]*$`)

func emit(key string, val any) {
	s := fmt.Sprint(val)
	if !safeValue.MatchString(s) {
		s = "unsafe"
	}
	fmt.Printf("%s=%s\n", key, s)
}

// probe submits the transaction and polls until the canonical receipt arrives or the
// budget runs out. Only a submission failure is an error: everything after that is a
// measurement, and "never showed up" is a result the caller needs to see rather than an
// error that hides the timings collected so far.
func probe(c *client, cfg config) (result, error) {
	res := result{preMS: -1, receiptMS: -1, finalMS: -1, status: -1, block: -1}

	start := time.Now()
	raw, err := c.call(cfg.sendURL, "eth_sendRawTransaction", cfg.raw)
	if err != nil {
		return res, fmt.Errorf("eth_sendRawTransaction: %w", err)
	}
	if err := json.Unmarshal(raw, &res.txHash); err != nil || res.txHash == "" {
		return res, fmt.Errorf("eth_sendRawTransaction returned no transaction hash: %s", truncate(string(raw)))
	}

	elapsed := func() int64 { return time.Since(start).Milliseconds() }
	deadline := start.Add(cfg.budget)
	for time.Now().Before(deadline) {
		if res.preMS < 0 && c.pendingContains(cfg.pendingURL, res.txHash) {
			res.preMS = elapsed()
		}
		if res.receiptMS < 0 {
			if _, ok := c.receipt(cfg.pendingURL, res.txHash); ok {
				res.receiptMS = elapsed()
			}
		}
		if rc, ok := c.receipt(cfg.canonicalURL, res.txHash); ok {
			res.finalMS = elapsed()
			res.status = hexToInt(rc.Status)
			res.block = hexToInt(rc.BlockNumber)
			return res, nil
		}
		time.Sleep(cfg.interval)
	}
	return res, nil
}

type client struct{ http *http.Client }

func newClient(timeout time.Duration) *client {
	return &client{http: &http.Client{Timeout: timeout}}
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return fmt.Sprintf("rpc error %d: %s", e.Code, e.Message) }

func (c *client) call(url, method string, params ...any) (json.RawMessage, error) {
	if params == nil {
		params = []any{}
	}
	body, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": method, "params": params,
	})
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Post(url, "application/json", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var envelope struct {
		Result json.RawMessage `json:"result"`
		Error  *rpcError       `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, fmt.Errorf("HTTP %d: %w", resp.StatusCode, err)
	}
	if envelope.Error != nil {
		return nil, envelope.Error
	}
	return envelope.Result, nil
}

// pendingContains reports whether the pending block already lists the transaction.
// A transport hiccup mid-poll is not fatal: the next iteration asks again, and the answer
// only ever moves from false to true.
func (c *client) pendingContains(url, txHash string) bool {
	raw, err := c.call(url, "eth_getBlockByNumber", "pending", false)
	if err != nil {
		return false
	}
	var block struct {
		Transactions []string `json:"transactions"`
	}
	if json.Unmarshal(raw, &block) != nil {
		return false
	}
	for _, tx := range block.Transactions {
		if strings.EqualFold(tx, txHash) {
			return true
		}
	}
	return false
}

type receipt struct {
	Status      string `json:"status"`
	BlockNumber string `json:"blockNumber"`
}

// receipt returns the receipt once the node has one. A pending receipt from a
// flashblocks-aware node and a canonical receipt look the same here; which one it is
// depends on the URL the caller passed.
func (c *client) receipt(url, txHash string) (receipt, bool) {
	raw, err := c.call(url, "eth_getTransactionReceipt", txHash)
	if err != nil || len(raw) == 0 || string(raw) == "null" {
		return receipt{}, false
	}
	var r receipt
	if json.Unmarshal(raw, &r) != nil || r.BlockNumber == "" {
		return receipt{}, false
	}
	return r, true
}

// hexToInt parses a 0x quantity, returning -1 when the value is missing or malformed so
// that callers can tell "not reported" apart from a genuine zero.
func hexToInt(s string) int64 {
	s = strings.TrimPrefix(s, "0x")
	if s == "" {
		return -1
	}
	n, err := strconv.ParseInt(s, 16, 64)
	if err != nil {
		return -1
	}
	return n
}

func truncate(s string) string {
	if len(s) > 120 {
		return s[:120] + "…"
	}
	return s
}
