package main

import (
	"bytes"
	"testing"
)

func TestParseFlashblockInfo(t *testing.T) {
	msg := []byte(`{"index":2,"metadata":{"block_number":12345}}`)

	info, ok := parseFlashblockInfo(msg)

	if !ok {
		t.Fatal("expected valid flashblock info")
	}
	if info.index != 2 {
		t.Fatalf("index = %d, want 2", info.index)
	}
	if info.blockNumber != 12345 {
		t.Fatalf("block number = %d, want 12345", info.blockNumber)
	}
}

func TestVerboseReporterPrintsMessagesAndBlockSummary(t *testing.T) {
	var out bytes.Buffer
	reporter := newVerboseReporter(&out)

	reporter.observe(flashblockInfo{blockNumber: 101, index: 0}, 120)
	reporter.observe(flashblockInfo{blockNumber: 101, index: 1}, 80)
	reporter.observe(flashblockInfo{blockNumber: 102, index: 0}, 100)
	reporter.summary()

	want := "" +
		"flashblock block=101 index=0 bytes=120\n" +
		"flashblock block=101 index=1 bytes=80\n" +
		"flashblock block=102 index=0 bytes=100\n" +
		"flashblock_summary block=101 observed_slices=2 indexes=0,1\n" +
		"flashblock_summary block=102 observed_slices=1 indexes=0\n"
	if out.String() != want {
		t.Fatalf("output:\n%s\nwant:\n%s", out.String(), want)
	}
}
