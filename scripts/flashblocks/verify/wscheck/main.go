// wscheck probes the Flashblocks broadcast stream.
//
// Nearly every check under verify/ can be performed with a single rg or cast command
// from a shell. This one cannot: determining whether a port is actually broadcasting
// Flashblocks requires completing the WebSocket HTTP Upgrade handshake and decoding
// frames according to RFC 6455, so it lives in this standalone Go file.
//
// Checking only whether the port is open is insufficient: nc -z proves only that a
// process is listening. In enabled mode, this stream is the sole source of user-facing
// preconfirmations: rollup-boost forwards builder-produced slices here, and
// flashblocks-websocket-proxy distributes them to op-reth. If the builder falls behind
// the chain, the port remains open while the stream contains no data.
//
// Output contains one key=value pair per line for a shell to consume with `eval`:
//
//	ok=1 status=101 bytes=8321 slices=12 covered_blocks=2
//	ok=0 error=connect|handshake     (failure details are written to stderr)
//
// Keys are deliberately descriptive to avoid collisions with variables in the calling
// script, because eval directly overwrites variables with the same names.
//
// gorilla/websocket implements the protocol, including the handshake, masking, fragment
// reassembly, and ping/pong keepalive. Dependencies are vendored, so the `go build`
// performed by lib.sh requires no network access.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

func main() {
	port := flag.Int("port", 1112, "Flashblocks broadcast port")
	timeout := flag.Int("timeout", 6, "seconds to wait for data")
	verbose := flag.Bool("verbose", false, "print each Flashblock and a per-block slice summary")
	flag.Parse()

	// Connect locally only: this stream is unauthenticated and must not be probed
	// across hosts.
	url := fmt.Sprintf("ws://127.0.0.1:%d/", *port)

	dialer := websocket.Dialer{HandshakeTimeout: 5 * time.Second}
	conn, resp, err := dialer.Dial(url, nil)
	if err != nil {
		// An HTTP response proves that TCP connected and the failure occurred during
		// the handshake; otherwise, the connection itself failed.
		status, reason := 0, "connect"
		if resp != nil {
			status, reason = resp.StatusCode, "handshake"
		}
		fmt.Fprintf(os.Stderr, "failed to connect to %s: %v\n", url, err)
		emit("ok", 0)
		emit("status", status)
		emit("error", reason)
		return
	}
	defer conn.Close()

	var reporter *verboseReporter
	if *verbose {
		reporter = newVerboseReporter(os.Stderr)
	}
	st := readFlashblocks(conn, time.Duration(*timeout)*time.Second, reporter)
	if reporter != nil {
		reporter.summary()
	}
	emit("ok", 1)
	emit("status", resp.StatusCode)
	emit("bytes", st.bytes)
	emit("slices", st.slices)
	emit("covered_blocks", st.blocks)
}

// Allow only these characters in values. Because a shell evaluates this output, remote
// content must never become executable code.
var safeValue = regexp.MustCompile(`^[0-9A-Za-z_.,:/=+@-]*$`)

func emit(key string, val any) {
	s := fmt.Sprint(val)
	if !safeValue.MatchString(s) {
		s = "unsafe"
	}
	fmt.Printf("%s=%s\n", key, s)
}

type stats struct {
	bytes  int // total message payload bytes
	slices int // complete Flashblocks messages
	blocks int // messages with index=0, marking the start of a new block
}

// readFlashblocks reads messages continuously during the given time window.
// A payload parsing failure is not an error: the upstream schema may change, while byte
// and message counts remain valid evidence.
func readFlashblocks(conn *websocket.Conn, window time.Duration, reporter *verboseReporter) stats {
	var st stats
	deadline := time.Now().Add(window)

	// Limit each message to 16 MiB. A normal Flashblock slice is only a few KiB; without
	// a limit, a peer could exhaust memory by declaring an excessive message length.
	conn.SetReadLimit(16 << 20)
	_ = conn.SetReadDeadline(deadline)

	for time.Now().Before(deadline) {
		_, msg, err := conn.ReadMessage()
		if err != nil {
			return st // Timeout or peer closure ends the observation normally.
		}
		st.slices++
		st.bytes += len(msg)
		if flashblockIndex(msg) == 0 {
			st.blocks++
		}
		if reporter != nil {
			if info, ok := parseFlashblockInfo(msg); ok {
				reporter.observe(info, len(msg))
			}
		}
	}
	return st
}

type flashblockInfo struct {
	blockNumber uint64
	index       int
}

func parseFlashblockInfo(msg []byte) (flashblockInfo, bool) {
	var p struct {
		Index    *int `json:"index"`
		Metadata struct {
			BlockNumber *uint64 `json:"block_number"`
		} `json:"metadata"`
	}
	if json.Unmarshal(msg, &p) != nil || p.Index == nil || p.Metadata.BlockNumber == nil {
		return flashblockInfo{}, false
	}
	return flashblockInfo{blockNumber: *p.Metadata.BlockNumber, index: *p.Index}, true
}

type verboseReporter struct {
	out     io.Writer
	indexes map[uint64][]int
}

func newVerboseReporter(out io.Writer) *verboseReporter {
	return &verboseReporter{out: out, indexes: make(map[uint64][]int)}
}

func (r *verboseReporter) observe(info flashblockInfo, size int) {
	fmt.Fprintf(r.out, "flashblock block=%d index=%d bytes=%d\n", info.blockNumber, info.index, size)
	r.indexes[info.blockNumber] = append(r.indexes[info.blockNumber], info.index)
}

func (r *verboseReporter) summary() {
	blocks := make([]uint64, 0, len(r.indexes))
	for block := range r.indexes {
		blocks = append(blocks, block)
	}
	sort.Slice(blocks, func(i, j int) bool { return blocks[i] < blocks[j] })

	for _, block := range blocks {
		indexes := r.indexes[block]
		values := make([]string, len(indexes))
		for i, index := range indexes {
			values[i] = strconv.Itoa(index)
		}
		fmt.Fprintf(r.out, "flashblock_summary block=%d observed_slices=%d indexes=%s\n",
			block, len(indexes), strings.Join(values, ","))
	}
}

// flashblockIndex returns the slice index, or -1 if it cannot be parsed.
// index=0 marks the first slice of a new L2 block, allowing the number of blocks covered
// by the observation window to be counted.
func flashblockIndex(msg []byte) int {
	var p struct {
		Index *int `json:"index"`
	}
	if json.Unmarshal(msg, &p) != nil || p.Index == nil {
		return -1
	}
	return *p.Index
}
