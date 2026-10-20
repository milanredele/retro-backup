package main

import (
	"net"
	"net/http"
	"time"
)

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

type loggingWriter struct {
	http.ResponseWriter
	status int
	n      int64
}

func (l *loggingWriter) WriteHeader(code int) {
	if l.status == 0 {
		l.status = code
	}
	l.ResponseWriter.WriteHeader(code)
}

func (l *loggingWriter) Write(p []byte) (int, error) {
	if l.status == 0 {
		l.status = http.StatusOK
	}
	n, err := l.ResponseWriter.Write(p)
	l.n += int64(n)
	return n, err
}

// Flush keeps http.Flusher working through the wrapper.
func (l *loggingWriter) Flush() {
	if f, ok := l.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// withAccessLog logs one line per request: client, method, path, status,
// request body bytes, response bytes and duration.
func withAccessLog(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		var in *countingReader
		if r.Body != nil {
			in = &countingReader{r: r.Body}
			r.Body = readCloser{in, r.Body}
		}
		lw := &loggingWriter{ResponseWriter: w}
		h.ServeHTTP(lw, r)
		var inN int64
		if in != nil {
			inN = in.n
		}
		if lw.status == 0 {
			lw.status = http.StatusOK
		}
		logf("http %s %s %s -> %d in=%d out=%d %s", clientIP(r), r.Method, r.URL.RequestURI(), lw.status, inN, lw.n, time.Since(start).Round(100*time.Microsecond))
	})
}

type readCloser struct {
	r interface{ Read([]byte) (int, error) }
	c interface{ Close() error }
}

func (rc readCloser) Read(p []byte) (int, error) { return rc.r.Read(p) }
func (rc readCloser) Close() error               { return rc.c.Close() }

// newMux wires the receiver and, when boot is non-nil, /boot/.
func newMux(rc *receiver, boot *bootFiles) http.Handler {
	mux := http.NewServeMux()
	rc.register(mux)
	if boot != nil {
		mux.Handle("/boot/", http.StripPrefix("/boot/", boot))
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		jsonError(w, http.StatusNotFound, "not found")
	})
	return withAccessLog(mux)
}
