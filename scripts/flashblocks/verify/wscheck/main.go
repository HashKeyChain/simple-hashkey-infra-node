// wscheck —— 探测 flashblocks 广播流。
//
// verify/ 下的检查基本都是 shell 一条 rg / cast 就能做的事，只有这一项不行：
// 判断一个端口是不是真的在广播 flashblocks，必须完成 WebSocket 的 HTTP Upgrade 握手、
// 校验 Sec-WebSocket-Accept、再按 RFC 6455 的帧格式把数据读出来。shell 做不了，
// 所以单独放这一个 Go 文件。
//
// 为什么不能只看端口通不通：nc -z 只能证明有进程在 listen，
// 而这个流是 enabled 模式下用户侧预确认的唯一数据源 —— rollup-boost 把 builder 造的
// 分片转发到这里，经 flashblocks-websocket-proxy 分发给 op-reth。
// builder 脱链时端口照样开着，但流里一个字节都没有。
//
// 输出 key=value 每行一条，供 shell `eval` 吸收：
//
//	ok=1 status=101 frames=12 bytes=8321 slices=12 covered_blocks=2
//	ok=0 error=connect|handshake     （失败原因详情打在 stderr）
//
// key 起得长是为了不和调用方脚本里的变量撞名 —— eval 会直接覆盖同名变量。
//
// 用标准库手写握手和帧解析，是为了让它零外部依赖：go build 不需要联网。
package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"time"
)

// RFC 6455 规定的固定 GUID，用于校验服务端的 Sec-WebSocket-Accept
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

const (
	opContinuation = 0x0
	opText         = 0x1
	opBinary       = 0x2
	opClose        = 0x8
	opPing         = 0x9
	opPong         = 0xA
)

func main() {
	port := flag.Int("port", 1112, "flashblocks 广播端口")
	timeout := flag.Int("timeout", 6, "等待数据的秒数")
	flag.Parse()

	// 只连本地：这个流没有鉴权，不应该跨主机探测
	addr := fmt.Sprintf("127.0.0.1:%d", *port)
	conn, err := net.DialTimeout("tcp", addr, 3*time.Second)
	if err != nil {
		fmt.Fprintf(os.Stderr, "连接 %s 失败: %v\n", addr, err)
		emit("ok", 0)
		emit("error", "connect")
		return
	}
	defer conn.Close()

	br := bufio.NewReader(conn)
	status, err := handshake(conn, br, addr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "握手失败: %v\n", err)
		emit("ok", 0)
		emit("status", status)
		emit("error", "handshake")
		return
	}

	st := readFlashblocks(conn, br, time.Duration(*timeout)*time.Second)
	emit("ok", 1)
	emit("status", status)
	emit("frames", st.frames)
	emit("bytes", st.bytes)
	emit("slices", st.slices)
	emit("covered_blocks", st.blocks)
}

// 值里只允许这些字符。输出会被 shell eval，不能让远端内容变成可执行代码。
var safeValue = regexp.MustCompile(`^[0-9A-Za-z_.,:/=+@-]*$`)

func emit(key string, val any) {
	s := fmt.Sprint(val)
	if !safeValue.MatchString(s) {
		s = "unsafe"
	}
	fmt.Printf("%s=%s\n", key, s)
}

// handshake 发起 HTTP Upgrade 并校验响应，返回 HTTP 状态码。
func handshake(conn net.Conn, br *bufio.Reader, host string) (int, error) {
	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return 0, err
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])

	req := "GET / HTTP/1.1\r\n" +
		"Host: " + host + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"

	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return 0, err
	}
	if _, err := io.WriteString(conn, req); err != nil {
		return 0, err
	}

	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		return 0, fmt.Errorf("读响应: %w", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusSwitchingProtocols {
		return resp.StatusCode, fmt.Errorf("期望 101，实际 %s", resp.Status)
	}

	// 校验 Accept 头：证明对端真的按 WebSocket 协议应答，而不是碰巧回了个 101
	sum := sha1.Sum([]byte(key + wsGUID))
	want := base64.StdEncoding.EncodeToString(sum[:])
	if got := resp.Header.Get("Sec-WebSocket-Accept"); got != want {
		return resp.StatusCode, fmt.Errorf("Sec-WebSocket-Accept 不匹配: got=%q want=%q", got, want)
	}
	return resp.StatusCode, nil
}

type stats struct {
	frames int // 收到的数据帧数（含分片续帧）
	bytes  int // 数据帧载荷总字节
	slices int // 完整的 flashblocks 消息数
	blocks int // index=0 的消息数，即新块起点数
}

// readFlashblocks 在给定时限内持续读帧。
// 载荷解析失败不算错误：上游可能启用压缩或改结构，那时字节数和帧数依然是有效证据。
func readFlashblocks(conn net.Conn, br *bufio.Reader, window time.Duration) stats {
	var st stats
	deadline := time.Now().Add(window)
	_ = conn.SetReadDeadline(deadline)

	var msg []byte // 分片消息的重组缓冲
	for time.Now().Before(deadline) {
		fin, op, payload, err := readFrame(br)
		if err != nil {
			return st // 超时或对端关闭，正常结束观测
		}
		switch op {
		case opPing:
			_ = writeFrame(conn, opPong, payload)
		case opPong:
		case opClose:
			return st
		case opText, opBinary, opContinuation:
			st.frames++
			st.bytes += len(payload)
			msg = append(msg, payload...)
			if !fin {
				continue // 消息被分片了，等续帧凑齐再算一条
			}
			st.slices++
			if flashblockIndex(msg) == 0 {
				st.blocks++
			}
			msg = msg[:0]
		}
	}
	return st
}

// readFrame 读一个 WebSocket 帧，返回 FIN 位、操作码与已解掩码的载荷。
func readFrame(r *bufio.Reader) (bool, byte, []byte, error) {
	var head [2]byte
	if _, err := io.ReadFull(r, head[:]); err != nil {
		return false, 0, nil, err
	}
	fin := head[0]&0x80 != 0
	op := head[0] & 0x0f
	masked := head[1]&0x80 != 0

	length := int64(head[1] & 0x7f)
	switch length {
	case 126:
		var b [2]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return false, 0, nil, err
		}
		length = int64(binary.BigEndian.Uint16(b[:]))
	case 127:
		var b [8]byte
		if _, err := io.ReadFull(r, b[:]); err != nil {
			return false, 0, nil, err
		}
		length = int64(binary.BigEndian.Uint64(b[:]))
	}
	// 单帧上限 16MB：正常的 flashblock 分片只有几 KB，
	// 出现超大长度说明流已错位，继续按它分配内存会直接把内存吃光
	if length < 0 || length > 16<<20 {
		return false, 0, nil, fmt.Errorf("帧长度异常: %d", length)
	}

	var mask [4]byte
	if masked {
		if _, err := io.ReadFull(r, mask[:]); err != nil {
			return false, 0, nil, err
		}
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(r, payload); err != nil {
		return false, 0, nil, err
	}
	if masked {
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
	}
	return fin, op, payload, nil
}

// writeFrame 发一个帧。客户端发出的帧按协议必须掩码。
func writeFrame(w io.Writer, op byte, payload []byte) error {
	var mask [4]byte
	if _, err := rand.Read(mask[:]); err != nil {
		return err
	}
	head := []byte{0x80 | op, 0x80}
	switch n := len(payload); {
	case n < 126:
		head[1] |= byte(n)
	case n < 1<<16:
		head[1] |= 126
		head = binary.BigEndian.AppendUint16(head, uint16(n))
	default:
		head[1] |= 127
		head = binary.BigEndian.AppendUint64(head, uint64(n))
	}
	head = append(head, mask[:]...)
	body := make([]byte, len(payload))
	for i := range payload {
		body[i] = payload[i] ^ mask[i%4]
	}
	_, err := w.Write(append(head, body...))
	return err
}

// flashblockIndex 取分片序号；解析不了时返回 -1。
// index=0 是一个新 L2 块的第一片，据此能数出窗口内覆盖了多少个块。
func flashblockIndex(msg []byte) int {
	var p struct {
		Index *int `json:"index"`
	}
	if json.Unmarshal(msg, &p) != nil || p.Index == nil {
		return -1
	}
	return *p.Index
}
