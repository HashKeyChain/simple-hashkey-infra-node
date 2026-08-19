// fbwatch 订阅对外暴露的 flashblocks WebSocket，验证外部 op-reth 能否靠它工作。
//
// 和 verify/wscheck 的区别：wscheck 写死了 ws://127.0.0.1:port/，只能在 pod 内查本地
// 端口有没有在广播；fbwatch 打任意 ws/wss URL，用来查经过 ingress 暴露出去的那个入口。
// 两者不合并，是为了不动 verify/ 下那套已经跑通的本地脚本。
//
// 为什么不能用 curl 代替：curl 能完成 HTTP Upgrade 拿到 101，也能看到有字节在推，但它
// 交给你的是连续字节流，没有 WebSocket 报文边界。而 ws-proxy 开了 --enable-compression，
// 每个报文是独立的 brotli 流，必须先按 RFC 6455 切帧才能逐条解压。切片序号、每块切片数、
// 到达时序这些信息都在报文里，拿不到边界就都拿不到。
//
// 延迟只报「时间差」，不报「相对某个绝对时刻的滞后」。因为 flashblock 里的
// base.timestamp 是所属块的时间戳，而块从 T-block_time 就开始构建、到 T 才落地，
// 基准点取 T 还是 T-block_time 是含糊的，算出来的滞后能差一整个出块周期，没有意义。
// 相邻切片间隔、单块切片跨度这些只做本机时刻相减，不受时钟对齐和这个含糊性影响。
//
// 输出是每行一个 key=value，给调用方 eval：
//
//	ok=1 status=101 bytes=57342 slices=53 blocks=5 …
//	ok=0 status=0 error=connect          （失败细节写到 stderr）
//
// key 起得啰嗦是故意的：eval 会直接覆盖同名变量，避免撞上调用脚本里的变量。
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"time"

	"github.com/andybalholm/brotli"
	"github.com/gorilla/websocket"
)

func main() {
	url := flag.String("url", "", "flashblocks WebSocket URL，如 wss://host/ws")
	timeout := flag.Int("timeout", 10, "观测窗口秒数，0 表示一直收到 Ctrl-C")
	verbose := flag.Bool("v", false, "结束时把每个块的切片明细打到 stderr")
	stream := flag.Bool("stream", false, "每收到一片就打一行摘要，用来在终端上盯实时流")
	flag.Parse()

	if *url == "" {
		fmt.Fprintln(os.Stderr, "缺 -url")
		emit("ok", 0)
		emit("status", 0)
		emit("error", "no_url")
		return
	}

	d := websocket.Dialer{HandshakeTimeout: 10 * time.Second}
	conn, resp, err := d.Dial(*url, nil)
	if err != nil {
		// 拿到 HTTP 响应说明 TCP 通了、是握手阶段被拒（比如 ingress 没转发 Upgrade 头，
		// 会回 200/404 而不是 101）；没有响应就是连接本身没建起来。这两种排查方向完全不同。
		status, reason := 0, "connect"
		if resp != nil {
			status, reason = resp.StatusCode, "handshake"
		}
		fmt.Fprintf(os.Stderr, "连接 %s 失败: %v\n", *url, err)
		emit("ok", 0)
		emit("status", status)
		emit("error", reason)
		return
	}
	defer conn.Close()

	if *stream {
		fmt.Fprintf(os.Stderr, "已连上 %s（HTTP %d），Ctrl-C 停止\n", *url, resp.StatusCode)
	}
	st := observe(conn, time.Duration(*timeout)*time.Second, *verbose, *stream)

	emit("ok", 1)
	emit("status", resp.StatusCode)
	emit("bytes", st.bytes)
	emit("slices", st.slices)
	emit("decode_fail", st.decodeFail)
	emit("blocks", st.blocks())
	emit("block_low", st.low)
	emit("block_high", st.high)
	// checked_blocks 是切片完整性和单块跨度实际检查了几个块，给「0 个不连续」当分母。
	// 它比 blocks 少 2：窗口两端的块天然残缺，被排除了。
	emit("checked_blocks", len(st.middleBlocks()))
	emit("incomplete_blocks", st.incomplete(*verbose))
	emit("max_gap_ms", ms(st.maxGap))
	emit("p50_gap_ms", ms(percentile(st.gaps, 0.5)))
	emit("max_block_span_ms", ms(st.maxBlockSpan(*verbose)))
}

// 只允许这些字符。调用方会 eval 这些输出，远端内容绝不能变成可执行代码。
var safeValue = regexp.MustCompile(`^[0-9A-Za-z_.,:/=+@-]*$`)

func emit(key string, val any) {
	s := fmt.Sprint(val)
	if !safeValue.MatchString(s) {
		s = "unsafe"
	}
	fmt.Printf("%s=%s\n", key, s)
}

func ms(d time.Duration) int64 { return d.Milliseconds() }

type slice struct {
	index   uint64
	arrival time.Time
}

type stats struct {
	bytes      int
	slices     int
	decodeFail int
	low, high  uint64
	seen       map[uint64][]slice // 块号 -> 观测到的切片
	gaps       []time.Duration    // 相邻切片到达间隔
	maxGap     time.Duration
}

func (s *stats) blocks() int { return len(s.seen) }

// incomplete 数有多少个块的切片序号不是从 0 起连续的。
// 观测窗口两端的块天然是残缺的（开始时那个块已经播了一半，结束时那个还没播完），
// 所以把首尾两个块号排除掉，否则每次都会报 2 个假阳性。
func (s *stats) incomplete(verbose bool) int {
	bad := 0
	for _, num := range s.middleBlocks() {
		idx := make([]int, 0, len(s.seen[num]))
		for _, sl := range s.seen[num] {
			idx = append(idx, int(sl.index))
		}
		sort.Ints(idx)
		ok := true
		for i, v := range idx {
			if v != i {
				ok = false
				break
			}
		}
		if !ok {
			bad++
			if verbose {
				fmt.Fprintf(os.Stderr, "块 %d 切片序号不连续: %v\n", num, idx)
			}
		} else if verbose {
			fmt.Fprintf(os.Stderr, "块 %d 切片 %d 片，序号 0..%d 连续\n", num, len(idx), len(idx)-1)
		}
	}
	return bad
}

// maxBlockSpan 是完整观测到的块里，首片到末片的最大耗时。
// 这个数应该明显小于出块周期：末片都到了才说明用户能看到这个块的全部内容，
// 如果它接近或超过出块周期，预确认就没有实际提前量了。
func (s *stats) maxBlockSpan(verbose bool) time.Duration {
	var max time.Duration
	for _, num := range s.middleBlocks() {
		sl := s.seen[num]
		first, last := sl[0].arrival, sl[0].arrival
		for _, x := range sl {
			if x.arrival.Before(first) {
				first = x.arrival
			}
			if x.arrival.After(last) {
				last = x.arrival
			}
		}
		if d := last.Sub(first); d > max {
			max = d
		}
		if verbose {
			fmt.Fprintf(os.Stderr, "块 %d 首片到末片 %dms\n", num, ms(last.Sub(first)))
		}
	}
	return max
}

// middleBlocks 返回排除首尾之后的块号，升序。
func (s *stats) middleBlocks() []uint64 {
	nums := make([]uint64, 0, len(s.seen))
	for n := range s.seen {
		nums = append(nums, n)
	}
	sort.Slice(nums, func(i, j int) bool { return nums[i] < nums[j] })
	if len(nums) <= 2 {
		return nil
	}
	return nums[1 : len(nums)-1]
}

// stallTimeout 是 -timeout 0（一直收）时单次读的上限。
// 没有它的话，对端不发也不关连接时进程会无声挂死，看起来像「流很安静」而不是「出问题了」。
const stallTimeout = 30 * time.Second

func observe(conn *websocket.Conn, window time.Duration, verbose, stream bool) *stats {
	st := &stats{seen: map[uint64][]slice{}}

	// window 为 0 表示一直收到 Ctrl-C，此时 deadline 留零值当「不限时」的标记。
	var deadline time.Time
	if window > 0 {
		deadline = time.Now().Add(window)
	}

	// 单报文限 16 MiB。正常切片只有几 KiB；不设上限的话，对端声明一个超大长度就能把内存吃光。
	conn.SetReadLimit(16 << 20)

	var prev time.Time
	for deadline.IsZero() || time.Now().Before(deadline) {
		if deadline.IsZero() {
			_ = conn.SetReadDeadline(time.Now().Add(stallTimeout))
		} else {
			_ = conn.SetReadDeadline(deadline)
		}
		_, msg, err := conn.ReadMessage()
		if err != nil {
			if deadline.IsZero() {
				// 不限时模式下读超时是异常：流断了或者卡住了，得说出来。
				fmt.Fprintf(os.Stderr, "读中断（%v 内没有新切片或连接已断）: %v\n", stallTimeout, err)
			}
			break // 限时模式下到点退出，属正常结束。
		}
		now := time.Now()
		st.slices++
		st.bytes += len(msg)

		gap := time.Duration(0)
		if !prev.IsZero() {
			gap = now.Sub(prev)
			st.gaps = append(st.gaps, gap)
			if gap > st.maxGap {
				st.maxGap = gap
			}
		}
		prev = now

		fb, err := decode(msg)
		if err != nil {
			// 解不开不算致命：字节数和切片数仍是有效证据，上游 schema 也可能变。
			st.decodeFail++
			if verbose || stream {
				fmt.Fprintf(os.Stderr, "解析失败: %v\n", err)
			}
			continue
		}
		if stream {
			// index=0 是一个新块的第一片，空一行分隔，这样终端上一屏就是一个块。
			if fb.Index == 0 {
				fmt.Fprintln(os.Stderr)
			}
			fmt.Fprintf(os.Stderr, "%s  块 %d  切片 %-2d  %5d 字节  距上片 %dms\n",
				now.Format("15:04:05.000"), fb.Number, fb.Index, len(msg), ms(gap))
		}
		st.seen[fb.Number] = append(st.seen[fb.Number], slice{index: fb.Index, arrival: now})
		if st.low == 0 || fb.Number < st.low {
			st.low = fb.Number
		}
		if fb.Number > st.high {
			st.high = fb.Number
		}
	}
	return st
}

type flashblock struct {
	Index  uint64
	Number uint64
}

func decode(msg []byte) (flashblock, error) {
	raw, err := maybeDecompress(msg)
	if err != nil {
		return flashblock{}, err
	}
	var p struct {
		Index    *uint64 `json:"index"`
		Metadata struct {
			BlockNumber *uint64 `json:"block_number"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal(raw, &p); err != nil {
		return flashblock{}, err
	}
	if p.Index == nil || p.Metadata.BlockNumber == nil {
		return flashblock{}, fmt.Errorf("报文缺 index 或 metadata.block_number")
	}
	return flashblock{Index: *p.Index, Number: *p.Metadata.BlockNumber}, nil
}

// maybeDecompress 与 reth 的判定保持一致（optimism/flashblocks/src/ws/decoding.rs）：
// 跳过前导空白后以 '{' 开头就是明文 JSON，否则按 brotli 解压。
// 必须照抄这个规则，否则 ws-proxy 那边开关 --enable-compression 时这里会跟着错。
func maybeDecompress(msg []byte) ([]byte, error) {
	for i, b := range msg {
		if b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\v' || b == '\f' {
			continue
		}
		if b == '{' {
			return msg[i:], nil
		}
		break
	}
	return io.ReadAll(brotli.NewReader(bytes.NewReader(msg)))
}

func percentile(ds []time.Duration, q float64) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	s := make([]time.Duration, len(ds))
	copy(s, ds)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	i := int(q * float64(len(s)-1))
	return s[i]
}
