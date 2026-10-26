package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
)

type hookInput struct {
	SessionID string `json:"session_id"`
	Event     string `json:"hook_event_name"`
}

type process struct {
	parent int
	tty    string
	name   string
}

type pane struct {
	socket string
	id     string
	tty    string
	title  string
}

var titlePattern = regexp.MustCompile(`^codex \| ([0-9a-f-]{29})\.\.\.(?: [^\s|])?$`)

func main() {
	state := flag.String("state", "", "running, needs-input, or done")
	register := flag.String("register-tmux", "", "register a tmux server socket")
	flag.Parse()
	var err error
	if *register != "" {
		err = registerSocket(*register)
	} else {
		executable, pathErr := os.Executable()
		if pathErr != nil {
			err = pathErr
		} else {
			err = runHook(*state, os.Stdin, filepath.Join(filepath.Dir(executable), "..", "scripts", "agent-state.sh"))
		}
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "tmux-agent-indicator:", err)
	}
}

func runHook(state string, input io.Reader, script string) error {
	events := map[string]string{"running": "UserPromptSubmit", "needs-input": "PermissionRequest", "done": "Stop"}
	expected, ok := events[state]
	if !ok {
		return errors.New("invalid Codex hook state")
	}
	payload, err := io.ReadAll(io.LimitReader(input, 4<<20))
	if err != nil {
		return err
	}
	var hook hookInput
	if err := json.Unmarshal(payload, &hook); err != nil {
		return err
	}
	if hook.SessionID == "" || hook.Event != expected {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	processes, err := processSnapshot(ctx)
	if err != nil {
		return err
	}
	panes, err := listPanes(ctx)
	if err != nil {
		return err
	}
	var matches []pane
	if tty := ancestorTTY(processes, os.Getppid()); tty != "" {
		for _, p := range panes {
			if p.tty == tty {
				matches = append(matches, p)
			}
		}
	} else {
		candidates := liveTitlePanes(panes, processes)
		if len(candidates) == 0 {
			return nil
		}
		client, err := connectDaemon(ctx, daemonSocket())
		if err != nil {
			return err
		}
		defer client.conn.CloseNow()
		ids, err := client.loadedThreads(ctx)
		if err != nil {
			return err
		}
		for _, p := range candidates {
			id := uniqueThreadID(p.title, ids)
			if id == "" {
				continue
			}
			var result struct {
				Thread struct {
					ID        string `json:"id"`
					SessionID string `json:"sessionId"`
				} `json:"thread"`
			}
			if err := client.call(ctx, "thread/read", map[string]any{"threadId": id, "includeTurns": false}, &result); err != nil {
				return err
			}
			if result.Thread.ID == id && result.Thread.SessionID == hook.SessionID {
				matches = append(matches, p)
			}
		}
	}
	if len(matches) != 1 {
		return nil
	}
	target := matches[0]
	// Recheck the title and native process after the API round trips.
	current, err := tmuxOutput(ctx, target.socket, "display-message", "-p", "-t", target.id, "#{pane_title}")
	if err != nil || strings.TrimSuffix(current, "\n") != target.title {
		return err
	}
	processes, err = processSnapshot(ctx)
	if err != nil || !codexOnTTY(processes, target.tty) {
		return err
	}
	args := []string{script, "--agent", "codex", "--state", state}
	if state == "running" {
		args = append(args, "--description-from-stdin")
	}
	cmd := exec.Command("bash", args...)
	cmd.Env = targetEnv(os.Environ(), target)
	cmd.Stdin = bytes.NewReader(payload)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func targetEnv(env []string, target pane) []string {
	result := make([]string, 0, len(env)+2)
	for _, entry := range env {
		if !strings.HasPrefix(entry, "TMUX=") && !strings.HasPrefix(entry, "TMUX_PANE=") {
			result = append(result, entry)
		}
	}
	return append(result, "TMUX="+target.socket+",0,0", "TMUX_PANE="+target.id)
}

func registryDir() string {
	return filepath.Join(os.TempDir(), "tmux-agent-indicator-"+strconv.Itoa(os.Getuid()), "servers")
}

func registerSocket(socket string) error {
	if err := os.MkdirAll(registryDir(), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(registryDir(), ".register-")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.WriteString(socket)
	closeErr := file.Close()
	if err := errors.Join(writeErr, closeErr); err != nil {
		return err
	}
	key := sha256.Sum256([]byte(socket))
	return os.Rename(file.Name(), filepath.Join(registryDir(), hex.EncodeToString(key[:8])+".socket"))
}

func listPanes(ctx context.Context) ([]pane, error) {
	sockets := map[string]bool{}
	if value := os.Getenv("TMUX"); value != "" {
		sockets[strings.SplitN(value, ",", 2)[0]] = true
	}
	files, err := filepath.Glob(filepath.Join(registryDir(), "*.socket"))
	if err != nil {
		return nil, err
	}
	for _, file := range files {
		if socket, err := os.ReadFile(file); err == nil {
			sockets[string(socket)] = true
		}
	}
	var panes []pane
	seen := map[string]bool{}
	for socket := range sockets {
		output, err := tmuxOutput(ctx, socket, "list-panes", "-a", "-F", "#{socket_path}\t#{pane_id}\t#{pane_tty}\t#{pane_title}")
		if err != nil {
			continue
		}
		for _, line := range strings.Split(strings.TrimSuffix(output, "\n"), "\n") {
			fields := strings.SplitN(line, "\t", 4)
			if len(fields) == 4 && !seen[fields[0]+"\t"+fields[1]] {
				seen[fields[0]+"\t"+fields[1]] = true
				panes = append(panes, pane{socket: fields[0], id: fields[1], tty: filepath.Base(fields[2]), title: fields[3]})
			}
		}
	}
	return panes, nil
}

func tmuxOutput(ctx context.Context, socket string, args ...string) (string, error) {
	output, err := exec.CommandContext(ctx, "tmux", append([]string{"-S", socket}, args...)...).Output()
	return string(output), err
}

func processSnapshot(ctx context.Context) (map[int]process, error) {
	output, err := exec.CommandContext(ctx, "ps", "-ax", "-o", "pid=", "-o", "ppid=", "-o", "tty=", "-o", "comm=").Output()
	if err != nil {
		return nil, err
	}
	result := map[int]process{}
	for _, line := range strings.Split(string(output), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		pid, _ := strconv.Atoi(fields[0])
		parent, _ := strconv.Atoi(fields[1])
		result[pid] = process{parent: parent, tty: filepath.Base(fields[2]), name: filepath.Base(strings.Join(fields[3:], " "))}
	}
	return result, nil
}

func ancestorTTY(processes map[int]process, pid int) string {
	for pid > 1 {
		p, ok := processes[pid]
		if !ok {
			break
		}
		if p.name == "codex" {
			if p.tty != "?" && p.tty != "??" && p.tty != "-" {
				return p.tty
			}
			return ""
		}
		pid = p.parent
	}
	return ""
}

func codexOnTTY(processes map[int]process, tty string) bool {
	for _, p := range processes {
		if p.name == "codex" && p.tty == tty {
			return true
		}
	}
	return false
}

func liveTitlePanes(panes []pane, processes map[int]process) []pane {
	var result []pane
	for _, p := range panes {
		if titlePattern.MatchString(p.title) && codexOnTTY(processes, p.tty) {
			result = append(result, p)
		}
	}
	return result
}

func uniqueThreadID(title string, ids []string) string {
	match := titlePattern.FindStringSubmatch(title)
	if match == nil {
		return ""
	}
	var result string
	for _, id := range ids {
		if strings.HasPrefix(id, match[1]) {
			if result != "" {
				return ""
			}
			result = id
		}
	}
	return result
}

type daemonClient struct {
	conn *websocket.Conn
	id   int
}

func daemonSocket() string {
	home := os.Getenv("CODEX_HOME")
	if home == "" {
		userHome, _ := os.UserHomeDir()
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "app-server-control", "app-server-control.sock")
}

func connectDaemon(ctx context.Context, socket string) (*daemonClient, error) {
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	conn, _, err := websocket.Dial(ctx, "ws://localhost/rpc", &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}})
	if err != nil {
		return nil, err
	}
	conn.SetReadLimit(8 << 20)
	client := &daemonClient{conn: conn}
	if err := client.call(ctx, "initialize", map[string]any{"clientInfo": map[string]string{"name": "tmux_agent_indicator", "version": "1"}}, nil); err != nil {
		conn.CloseNow()
		return nil, err
	}
	if err := wsjson.Write(ctx, conn, map[string]any{"method": "initialized"}); err != nil {
		conn.CloseNow()
		return nil, err
	}
	return client, nil
}

func (c *daemonClient) call(ctx context.Context, method string, params any, result any) error {
	c.id++
	if err := wsjson.Write(ctx, c.conn, map[string]any{"id": c.id, "method": method, "params": params}); err != nil {
		return err
	}
	for {
		var reply struct {
			ID     int             `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		if err := wsjson.Read(ctx, c.conn, &reply); err != nil {
			return err
		}
		if reply.Method != "" || reply.ID != c.id {
			continue
		}
		if len(reply.Error) != 0 {
			return fmt.Errorf("Codex %s failed", method)
		}
		if result == nil {
			return nil
		}
		return json.Unmarshal(reply.Result, result)
	}
}

func (c *daemonClient) loadedThreads(ctx context.Context) ([]string, error) {
	var ids []string
	var cursor *string
	for {
		var page struct {
			Data       []string `json:"data"`
			NextCursor *string  `json:"nextCursor"`
		}
		if err := c.call(ctx, "thread/loaded/list", map[string]any{"cursor": cursor, "limit": 100}, &page); err != nil {
			return nil, err
		}
		ids = append(ids, page.Data...)
		if page.NextCursor == nil {
			return ids, nil
		}
		cursor = page.NextCursor
	}
}
