package main

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

func TestAncestorTTY(t *testing.T) {
	processes := map[int]process{10: {parent: 20, name: "sh"}, 20: {parent: 30, name: "codex", tty: "??"}, 30: {name: "codex", tty: "ttys001"}}
	if got := ancestorTTY(processes, 10); got != "" {
		t.Fatalf("climbed past daemon: %q", got)
	}
	processes[20] = process{name: "codex", tty: "ttys002"}
	if got := ancestorTTY(processes, 10); got != "ttys002" {
		t.Fatalf("embedded client tty: %q", got)
	}
}

func TestUniqueThreadID(t *testing.T) {
	id := "019a1234-1234-7234-8234-123456789abc"
	title := "codex | " + id[:29] + "..."
	if got := uniqueThreadID(title, []string{id}); got != id {
		t.Fatal(got)
	}
	if got := uniqueThreadID(title+" ◐", []string{id}); got != id {
		t.Fatal(got)
	}
	if got := uniqueThreadID(title, []string{id, id[:29] + "0000000"}); got != "" {
		t.Fatal("accepted colliding prefix")
	}
	if got := uniqueThreadID("other application", []string{id}); got != "" {
		t.Fatal(got)
	}
}

func TestDaemonRouting(t *testing.T) {
	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux unavailable")
	}
	dir, err := os.MkdirTemp("/tmp", "codex-hook-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("TMPDIR", dir)
	t.Setenv("CODEX_HOME", filepath.Join(dir, "home"))
	socket := filepath.Join(dir, "tmux")
	tmux := func(args ...string) string {
		t.Helper()
		out, err := exec.Command("tmux", append([]string{"-S", socket}, args...)...).CombinedOutput()
		if err != nil {
			t.Fatalf("tmux %v: %s (%v)", args, out, err)
		}
		return strings.TrimSpace(string(out))
	}
	first := tmux("-f", "/dev/null", "new-session", "-d", "-x", "100", "-y", "30", "-P", "-F", "#{pane_id}")
	t.Cleanup(func() { exec.Command("tmux", "-S", socket, "kill-server").Run() })
	second := tmux("split-window", "-d", "-P", "-F", "#{pane_id}")
	t.Setenv("TMUX", socket+",0,0")
	t.Setenv("TMUX_PANE", first)
	if err := registerSocket(socket); err != nil {
		t.Fatal(err)
	}
	id := "019a1234-1234-7234-8234-123456789abc"
	title := "codex | " + id[:29] + "..."
	tmux("select-pane", "-t", second, "-T", title)
	firstTTY := filepath.Base(tmux("display-message", "-p", "-t", first, "#{pane_tty}"))
	secondTTY := filepath.Base(tmux("display-message", "-p", "-t", second, "#{pane_tty}"))
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0700)
	fixture := filepath.Join(dir, "processes")
	t.Setenv("PS_FIXTURE", fixture)
	os.WriteFile(filepath.Join(bin, "ps"), []byte("#!/bin/sh\ncat \"$PS_FIXTURE\"\n"), 0700)
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	live := fmt.Sprintf("100001 1 %s codex\n100002 1 %s codex\n", firstTTY, secondTTY)
	os.WriteFile(fixture, []byte(live), 0600)
	capture := filepath.Join(dir, "capture")
	t.Setenv("CAPTURE", capture)
	script := filepath.Join(dir, "capture.sh")
	os.WriteFile(script, []byte("#!/bin/sh\nprintf '%s\\n' \"$TMUX_PANE\" \"$TMUX\" \"$*\" > \"$CAPTURE\"\ncat >> \"$CAPTURE\"\n"), 0700)

	var inventoryMu sync.Mutex
	ids := []string{id}
	session := "root-session"
	startDaemon(t, daemonSocket(), func(method string, params map[string]json.RawMessage) any {
		switch method {
		case "initialize":
			return map[string]any{}
		case "thread/loaded/list":
			inventoryMu.Lock()
			defer inventoryMu.Unlock()
			if string(params["cursor"]) == "null" {
				return map[string]any{"data": []string{}, "nextCursor": "page2"}
			}
			return map[string]any{"data": append([]string{}, ids...), "nextCursor": nil}
		case "thread/read":
			if string(params["includeTurns"]) != "false" {
				t.Error("requested turns")
			}
			return map[string]any{"thread": map[string]any{"id": id, "sessionId": session}}
		default:
			t.Errorf("unexpected API mutation: %s", method)
			return nil
		}
	})
	run := func(state, event, hookSession string, want bool) {
		t.Helper()
		os.Remove(capture)
		payload := fmt.Sprintf(`{"session_id":%q,"hook_event_name":%q,"prompt":"hello"}`, hookSession, event)
		if err := runHook(state, strings.NewReader(payload), script); err != nil {
			t.Fatal(err)
		}
		out, err := os.ReadFile(capture)
		if !want {
			if err == nil {
				t.Fatalf("unexpected routing: %s", out)
			}
			return
		}
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasPrefix(string(out), second+"\n"+socket+",0,0\n") || !strings.Contains(string(out), payload) {
			t.Fatalf("wrong destination/payload: %s", out)
		}
		if state == "running" && !strings.Contains(string(out), "--description-from-stdin") {
			t.Fatal("lost prompt description")
		}
	}
	for state, event := range map[string]string{"running": "UserPromptSubmit", "needs-input": "PermissionRequest", "done": "Stop"} {
		run(state, event, session, true)
	}
	run("done", "SubagentStop", session, false)
	run("done", "Stop", "foreign-session", false)
	inventoryMu.Lock()
	ids = append(ids, id[:29]+"0000000")
	inventoryMu.Unlock()
	run("done", "Stop", session, false)
	inventoryMu.Lock()
	ids = []string{id}
	inventoryMu.Unlock()
	tmux("select-pane", "-t", first, "-T", title)
	run("done", "Stop", session, false)
	tmux("select-pane", "-t", first, "-T", "shell")
	os.WriteFile(fixture, []byte(fmt.Sprintf("100001 1 %s codex\n", firstTTY)), 0600)
	run("done", "Stop", session, false)
	os.WriteFile(fixture, []byte(live), 0600)
	t.Setenv("CODEX_HOME", filepath.Join(dir, "unavailable"))
	os.Remove(capture)
	if err := runHook("done", strings.NewReader(`{"session_id":"root-session","hook_event_name":"Stop"}`), script); err == nil {
		t.Fatal("expected connection failure")
	}
	if _, err := os.Stat(capture); err == nil {
		t.Fatal("fell back to inherited pane")
	}
	// An embedded client can still route by its own TTY without a daemon API.
	os.WriteFile(fixture, []byte(live+fmt.Sprintf("%d 1 %s codex\n", os.Getppid(), secondTTY)), 0600)
	run("done", "Stop", session, true)
}

func startDaemon(t *testing.T, socket string, respond func(string, map[string]json.RawMessage) any) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(socket), 0700); err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		ctx := context.Background()
		for {
			var req struct {
				ID     int                        `json:"id"`
				Method string                     `json:"method"`
				Params map[string]json.RawMessage `json:"params"`
			}
			if err := wsjson.Read(ctx, conn, &req); err != nil {
				return
			}
			if req.Method == "initialized" {
				continue
			}
			result := respond(req.Method, req.Params)
			if err := wsjson.Write(ctx, conn, map[string]any{"method": "thread/status/changed", "params": map[string]any{}}); err != nil {
				return
			}
			if err := wsjson.Write(ctx, conn, map[string]any{"id": req.ID, "result": result}); err != nil {
				return
			}
		}
	})}
	go server.Serve(listener)
	t.Cleanup(func() { server.Close() })
}
