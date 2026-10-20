package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
)

// logger prints one line per event to stdout. Tests replace it.
var logger = log.New(os.Stdout, "", log.Ltime)

func logf(format string, args ...any) { logger.Printf(format, args...) }

func setLogOutput(w io.Writer) { logger.SetOutput(w) }

func humanBytes(n uint64) string {
	const unit = 1024
	if n < unit {
		return fmt.Sprintf("%d B", n)
	}
	div, exp := uint64(unit), 0
	for m := n / unit; m >= unit; m /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(n)/float64(div), "KMGTPE"[exp])
}

func mbps(n int64, d time.Duration) float64 {
	s := d.Seconds()
	if s <= 0 {
		return 0
	}
	return float64(n) / 1e6 / s
}

// machineStats are the per-machine totals printed on exit.
type machineStats struct {
	Uploads    int
	Files      int
	Bytes      int64
	Verified   int
	Mismatched int
	Renamed    int
	Rejected   int
	Busy       time.Duration
}

type stats struct {
	mu       sync.Mutex
	machines map[string]*machineStats
}

func newStats() *stats { return &stats{machines: map[string]*machineStats{}} }

func (s *stats) add(machine string, f func(m *machineStats)) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.machines[machine]
	if m == nil {
		m = &machineStats{}
		s.machines[machine] = m
	}
	f(m)
}

func (s *stats) summary() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.machines) == 0 {
		return "no uploads received"
	}
	names := make([]string, 0, len(s.machines))
	for n := range s.machines {
		names = append(names, n)
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString("per-machine totals:\n")
	for _, n := range names {
		m := s.machines[n]
		fmt.Fprintf(&b, "  %-40s %d uploads, %d files, %s, verified %d, mismatched %d, renamed %d, rejected %d, %.1f MB/s\n",
			n, m.Uploads, m.Files, humanBytes(uint64(m.Bytes)), m.Verified, m.Mismatched, m.Renamed, m.Rejected, mbps(m.Bytes, m.Busy))
	}
	return strings.TrimRight(b.String(), "\n")
}
