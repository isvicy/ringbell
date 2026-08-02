// Command reports is a tiny LAN service that hosts standalone HTML reports
// at https://reports.ringbell.cc/<slug>. Reports are published with an
// authenticated PUT and served from a plain directory on a PVC.
package main

import (
	"bytes"
	"crypto/subtle"
	"encoding/json"
	"fmt"
	"html"
	"html/template"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var (
	dataDir  = env("DATA_DIR", "/data")
	apiToken = os.Getenv("API_TOKEN")

	slugRe  = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,62}$`)
	titleRe = regexp.MustCompile(`(?is)<title[^>]*>(.*?)</title>`)
)

const maxBody = 10 << 20 // 10 MiB

// Report is one hosted HTML file.
type Report struct {
	Slug    string    `json:"slug"`
	Title   string    `json:"title"`
	Size    int64     `json:"size"`
	ModTime time.Time `json:"modTime"`
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	if apiToken == "" {
		log.Fatal("API_TOKEN must be set")
	}
	if err := os.MkdirAll(dataDir, 0o775); err != nil {
		log.Fatalf("data dir: %v", err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", handleHealthz)
	mux.HandleFunc("GET /{$}", handleIndex)
	mux.HandleFunc("GET /api/reports", handleList)
	mux.HandleFunc("PUT /api/reports/{slug}", withAuth(handlePut))
	mux.HandleFunc("DELETE /api/reports/{slug}", withAuth(handleDelete))
	mux.HandleFunc("GET /{slug}", handleReport)

	addr := ":" + env("PORT", "8080")
	log.Printf("reports: listening on %s, data dir %s", addr, dataDir)
	log.Fatal(http.ListenAndServe(addr, logRequests(mux)))
}

func handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Write([]byte("ok"))
}

func handleIndex(w http.ResponseWriter, _ *http.Request) {
	reports, err := listReports()
	if err != nil {
		http.Error(w, "list failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := indexTmpl.Execute(w, reports); err != nil {
		log.Printf("index template: %v", err)
	}
}

func handleList(w http.ResponseWriter, _ *http.Request) {
	reports, err := listReports()
	if err != nil {
		http.Error(w, "list failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(reports)
}

func handlePut(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	if !slugRe.MatchString(slug) {
		http.Error(w, "invalid slug: must match "+slugRe.String(), http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		http.Error(w, "body too large (max 10 MiB)", http.StatusRequestEntityTooLarge)
		return
	}
	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}
	sniff := body
	if len(sniff) > 4096 {
		sniff = sniff[:4096]
	}
	if !bytes.Contains(bytes.ToLower(sniff), []byte("<html")) {
		http.Error(w, "body does not look like HTML", http.StatusBadRequest)
		return
	}

	final := filepath.Join(dataDir, slug+".html")
	_, statErr := os.Stat(final)
	tmp := filepath.Join(dataDir, fmt.Sprintf(".tmp-%s-%d", slug, time.Now().UnixNano()))
	if err := os.WriteFile(tmp, body, 0o664); err != nil {
		http.Error(w, "write failed", http.StatusInternalServerError)
		return
	}
	if err := os.Rename(tmp, final); err != nil {
		os.Remove(tmp)
		http.Error(w, "store failed", http.StatusInternalServerError)
		return
	}

	info, _ := os.Stat(final)
	status := http.StatusOK
	if os.IsNotExist(statErr) {
		status = http.StatusCreated
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(Report{
		Slug:    slug,
		Title:   readTitle(final, slug),
		Size:    info.Size(),
		ModTime: info.ModTime(),
	})
}

func handleDelete(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	if !slugRe.MatchString(slug) {
		http.Error(w, "invalid slug", http.StatusBadRequest)
		return
	}
	if err := os.Remove(filepath.Join(dataDir, slug+".html")); err != nil {
		if os.IsNotExist(err) {
			http.NotFound(w, r)
			return
		}
		http.Error(w, "delete failed", http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func handleReport(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	// "api" and "healthz" are claimed by more specific routes; anything that
	// lands here with those names (or an invalid slug) is not a report.
	if slug == "api" || slug == "healthz" || !slugRe.MatchString(slug) {
		http.NotFound(w, r)
		return
	}
	path := filepath.Join(dataDir, slug+".html")
	if _, err := os.Stat(path); err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	http.ServeFile(w, r, path)
}

func listReports() ([]Report, error) {
	entries, err := os.ReadDir(dataDir)
	if err != nil {
		return nil, err
	}
	reports := make([]Report, 0, len(entries))
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".html") {
			continue
		}
		slug := strings.TrimSuffix(name, ".html")
		if !slugRe.MatchString(slug) {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		reports = append(reports, Report{
			Slug:    slug,
			Title:   readTitle(filepath.Join(dataDir, name), slug),
			Size:    info.Size(),
			ModTime: info.ModTime(),
		})
	}
	sort.Slice(reports, func(i, j int) bool {
		return reports[i].ModTime.After(reports[j].ModTime)
	})
	return reports, nil
}

// readTitle extracts the <title> from the first 64 KiB of the file,
// falling back to the slug.
func readTitle(path, fallback string) string {
	f, err := os.Open(path)
	if err != nil {
		return fallback
	}
	defer f.Close()
	buf := make([]byte, 64<<10)
	n, _ := f.Read(buf)
	m := titleRe.FindSubmatch(buf[:n])
	if m == nil {
		return fallback
	}
	t := strings.Join(strings.Fields(strings.TrimSpace(html.UnescapeString(string(m[1])))), " ")
	if t == "" {
		return fallback
	}
	return t
}

func withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		h := r.Header.Get("Authorization")
		token := strings.TrimPrefix(h, "Bearer ")
		if token == h || subtle.ConstantTimeCompare([]byte(token), []byte(apiToken)) != 1 {
			w.Header().Set("WWW-Authenticate", `Bearer realm="reports"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func humanSize(n int64) string {
	switch {
	case n < 1024:
		return fmt.Sprintf("%d B", n)
	case n < 1<<20:
		return fmt.Sprintf("%.1f KiB", float64(n)/1024)
	default:
		return fmt.Sprintf("%.1f MiB", float64(n)/(1<<20))
	}
}

var indexTmpl = template.Must(template.New("index").Funcs(template.FuncMap{
	"humanSize": humanSize,
}).Parse(`<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>reports · ringbell</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Segoe UI", sans-serif;
    background: #f8fafc; color: #1e293b; line-height: 1.6;
  }
  main { max-width: 760px; margin: 0 auto; padding: 48px 20px 80px; }
  header { margin-bottom: 28px; }
  h1 { font-size: 26px; font-weight: 800; }
  h1 .dot { color: #6d28d9; }
  .sub { color: #94a3b8; font-size: 14px; margin-top: 2px; }
  ul.list { list-style: none; display: flex; flex-direction: column; gap: 12px; }
  ul.list li {
    background: #fff; border: 1px solid #e2e8f0; border-radius: 12px; padding: 14px 18px;
    transition: border-color .15s, box-shadow .15s;
  }
  ul.list li:hover { border-color: #a78bfa; box-shadow: 0 2px 10px rgba(109,40,217,.08); }
  a.title { color: #1e293b; font-weight: 700; text-decoration: none; font-size: 16px; display: block; }
  a.title:hover { color: #6d28d9; }
  .meta { display: flex; gap: 14px; margin-top: 4px; font-size: 13px; color: #94a3b8; flex-wrap: wrap; }
  .meta .slug { font-family: "SF Mono", Menlo, Consolas, monospace; }
  .empty { color: #64748b; background: #fff; border: 1px dashed #cbd5e1; border-radius: 12px; padding: 28px; text-align: center; }
  .empty code { font-family: "SF Mono", Menlo, Consolas, monospace; background: #f1f5f9; border-radius: 4px; padding: 1px 6px; }
  footer { margin-top: 32px; font-size: 12.5px; color: #cbd5e1; text-align: center; }
</style>
</head>
<body>
<main>
  <header>
    <h1>reports<span class="dot"> · </span>ringbell</h1>
    <p class="sub">{{len .}} 篇报告</p>
  </header>
  {{if .}}
  <ul class="list">
    {{range .}}
    <li>
      <a class="title" href="/{{.Slug}}">{{.Title}}</a>
      <div class="meta">
        <span class="slug">/{{.Slug}}</span>
        <time>{{.ModTime.Format "2006-01-02 15:04"}}</time>
        <span>{{humanSize .Size}}</span>
      </div>
    </li>
    {{end}}
  </ul>
  {{else}}
  <p class="empty">还没有报告 — 用 <code>scripts/publish-report.sh</code> 发布第一篇</p>
  {{end}}
  <footer>reports.ringbell.cc</footer>
</main>
</body>
</html>
`))

type statusWriter struct {
	http.ResponseWriter
	status int
	size   int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

func (w *statusWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(b)
	w.size += n
	return n, err
}

func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r)
		log.Printf("%s %s %d %dB %s", r.Method, r.URL.Path, sw.status, sw.size,
			time.Since(start).Round(time.Microsecond))
	})
}
