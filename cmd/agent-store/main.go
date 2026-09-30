package main

import (
	"bufio"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	_ "modernc.org/sqlite"
)

const defaultProcesses = "claude,codex,aider,cursor,opencode,pi"

type agentSession struct {
	TTY         string `json:"-"`
	PaneID      string `json:"pane_id"`
	SessionID   string `json:"session_id"`
	WindowID    string `json:"window_id"`
	SessionName string `json:"session_name"`
	WindowName  string `json:"window_name"`
	PaneIndex   int    `json:"pane_index"`
	State       string `json:"state"`
	Agent       string `json:"agent"`
	Path        string `json:"path"`
	Title       string `json:"title"`
	Description string `json:"description"`
}

type request struct {
	Op          string `json:"op"`
	PaneID      string `json:"pane_id,omitempty"`
	Agent       string `json:"agent,omitempty"`
	State       string `json:"state,omitempty"`
	Description string `json:"description,omitempty"`
	SessionID   string `json:"session_id,omitempty"`
}

type response struct {
	Rows  []agentSession `json:"rows,omitempty"`
	Error string         `json:"error,omitempty"`
}

type paths struct {
	socket string
	db     string
	log    string
}

func main() {
	if len(os.Args) < 2 {
		fatal("usage: agent-store <serve|sync|event|list|stop>")
	}

	switch os.Args[1] {
	case "serve":
		if err := serve(); err != nil {
			fatal(err.Error())
		}
	case "sync":
		mustCall(request{Op: "sync"})
	case "event":
		eventCommand(os.Args[2:])
	case "list":
		listCommand(os.Args[2:])
	case "stop":
		stopCommand()
	default:
		fatal("unknown command: " + os.Args[1])
	}
}

func eventCommand(args []string) {
	flags := flag.NewFlagSet("event", flag.ExitOnError)
	paneID := flags.String("pane", "", "tmux pane ID")
	agent := flags.String("agent", "", "agent name")
	state := flags.String("state", "", "agent state")
	description := flags.String("description", "", "session description")
	_ = flags.Parse(args)
	if *paneID == "" || *agent == "" || *state == "" {
		fatal("event requires --pane, --agent, and --state")
	}
	mustCall(request{Op: "event", PaneID: *paneID, Agent: *agent, State: *state, Description: *description})
}

func listCommand(args []string) {
	flags := flag.NewFlagSet("list", flag.ExitOnError)
	sessionID := flags.String("session", "", "tmux session ID")
	_ = flags.Parse(args)
	result := mustCall(request{Op: "list", SessionID: *sessionID})
	writer := bufio.NewWriter(os.Stdout)
	for _, row := range result.Rows {
		fmt.Fprintf(writer, "%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\n",
			clean(row.PaneID), clean(row.SessionID), clean(row.WindowID), clean(row.SessionName),
			clean(row.WindowName), row.PaneIndex, clean(row.State), clean(row.Agent), clean(row.Path),
			clean(row.Title), clean(row.Description))
	}
	_ = writer.Flush()
}

func stopCommand() {
	conn, err := net.DialTimeout("unix", storePaths().socket, 100*time.Millisecond)
	if err != nil {
		return
	}
	defer conn.Close()
	_ = json.NewEncoder(conn).Encode(request{Op: "stop"})
}

func mustCall(req request) response {
	result, err := call(req)
	if err != nil {
		fatal(err.Error())
	}
	if result.Error != "" {
		fatal(result.Error)
	}
	return result
}

func call(req request) (response, error) {
	p := storePaths()
	conn, err := net.DialTimeout("unix", p.socket, 100*time.Millisecond)
	if err != nil {
		if err := startDaemon(p); err != nil {
			return response{}, err
		}
		for attempt := 0; attempt < 100; attempt++ {
			conn, err = net.DialTimeout("unix", p.socket, 100*time.Millisecond)
			if err == nil {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
	}
	if err != nil {
		return response{}, fmt.Errorf("connect to agent store: %w", err)
	}
	defer conn.Close()
	if err := json.NewEncoder(conn).Encode(req); err != nil {
		return response{}, err
	}
	var result response
	if err := json.NewDecoder(conn).Decode(&result); err != nil {
		return response{}, err
	}
	return result, nil
}

func startDaemon(p paths) error {
	if err := os.MkdirAll(filepath.Dir(p.socket), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.db), 0o700); err != nil {
		return err
	}
	_ = os.Remove(p.socket)
	logFile, err := os.OpenFile(p.log, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	command := exec.Command(os.Args[0], "serve")
	command.Env = os.Environ()
	command.Stdin = nil
	command.Stdout = logFile
	command.Stderr = logFile
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := command.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	_ = command.Process.Release()
	_ = logFile.Close()
	return nil
}

func serve() error {
	p := storePaths()
	if err := os.MkdirAll(filepath.Dir(p.socket), 0o700); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p.db), 0o700); err != nil {
		return err
	}
	listener, err := net.Listen("unix", p.socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(p.socket)

	db, err := openDatabase(p.db)
	if err != nil {
		return err
	}
	defer db.Close()

	for {
		conn, err := listener.Accept()
		if err != nil {
			return err
		}
		stop := handleConnection(db, conn)
		_ = conn.Close()
		if stop {
			return nil
		}
	}
}

func handleConnection(db *sql.DB, conn net.Conn) bool {
	var req request
	result := response{}
	if err := json.NewDecoder(conn).Decode(&req); err != nil {
		result.Error = err.Error()
		_ = json.NewEncoder(conn).Encode(result)
		return false
	}

	var err error
	switch req.Op {
	case "sync":
		err = syncSessions(db)
	case "event":
		err = applyEvent(db, req)
	case "list":
		result.Rows, err = listSessions(db, req.SessionID)
	case "stop":
		_ = json.NewEncoder(conn).Encode(result)
		return true
	default:
		err = errors.New("unknown operation: " + req.Op)
	}
	if err != nil {
		result.Error = err.Error()
	}
	_ = json.NewEncoder(conn).Encode(result)
	return false
}

func openDatabase(path string) (*sql.DB, error) {
	dsn := (&url.URL{Scheme: "file", Path: path}).String() + "?_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	_, err = db.Exec(`
		CREATE TABLE IF NOT EXISTS agent_sessions (
			pane_id TEXT PRIMARY KEY,
			session_id TEXT NOT NULL,
			window_id TEXT NOT NULL,
			session_name TEXT NOT NULL,
			window_name TEXT NOT NULL,
			pane_index INTEGER NOT NULL,
			state TEXT NOT NULL,
			agent TEXT NOT NULL,
			path TEXT NOT NULL,
			title TEXT NOT NULL,
			description TEXT NOT NULL,
			updated_at INTEGER NOT NULL
		)
	`)
	if err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

func applyEvent(db *sql.DB, req request) error {
	if req.State == "off" {
		_, err := db.Exec("DELETE FROM agent_sessions WHERE pane_id = ?", req.PaneID)
		return err
	}
	if req.State != "running" && req.State != "needs-input" && req.State != "done" && req.State != "idle" {
		return errors.New("invalid state: " + req.State)
	}
	row, err := paneMetadata(req.PaneID)
	if err != nil {
		return err
	}
	row.Agent = req.Agent
	row.State = req.State
	row.Description = req.Description
	if row.Description == "" {
		_ = db.QueryRow("SELECT description FROM agent_sessions WHERE pane_id = ?", req.PaneID).Scan(&row.Description)
	}
	return upsert(db, row)
}

func paneMetadata(paneID string) (agentSession, error) {
	const separator = "\x1f"
	format := strings.Join([]string{
		"#{pane_id}", "#{session_id}", "#{window_id}", "#{session_name}", "#{window_name}",
		"#{pane_index}", "#{pane_current_path}", "#{pane_title}",
	}, separator)
	output, err := commandOutput("tmux", "display-message", "-p", "-t", paneID, format)
	if err != nil {
		return agentSession{}, err
	}
	fields := strings.Split(strings.TrimSuffix(output, "\n"), separator)
	if len(fields) != 8 {
		return agentSession{}, errors.New("invalid tmux pane metadata")
	}
	index, _ := strconv.Atoi(fields[5])
	return agentSession{
		PaneID: fields[0], SessionID: fields[1], WindowID: fields[2], SessionName: fields[3],
		WindowName: fields[4], PaneIndex: index, Path: fields[6], Title: fields[7],
	}, nil
}

func syncSessions(db *sql.DB) error {
	panes, err := tmuxPanes()
	if err != nil {
		return err
	}
	environment, err := commandOutput("tmux", "show-environment", "-g")
	if err != nil {
		return err
	}
	hookAgents, hookStates, descriptions, activeAgents := parseEnvironment(environment)
	existing, err := existingSessions(db)
	if err != nil {
		return err
	}
	detected, err := detectedAgents()
	if err != nil {
		return err
	}
	fallback := configuredSet("@agent-indicator-panel-discovery-agents", "aider,cursor,pi")

	rows := make([]agentSession, 0, len(panes))
	for _, pane := range panes {
		detectedAgent := detected[filepath.Base(pane.TTY)]
		if detectedAgent == "" {
			continue
		}

		agent := ""
		if hookAgents[pane.PaneID] == detectedAgent {
			agent = detectedAgent
		} else if activeAgents[pane.PaneID] == detectedAgent {
			agent = detectedAgent
		} else if existing[pane.PaneID].Agent == detectedAgent {
			agent = detectedAgent
		} else if fallback[detectedAgent] {
			agent = detectedAgent
		}
		if agent == "" {
			continue
		}

		pane.Agent = agent
		pane.State = "idle"
		if hookAgents[pane.PaneID] == agent && validState(hookStates[pane.PaneID]) {
			pane.State = hookStates[pane.PaneID]
		}
		if hookAgents[pane.PaneID] == agent {
			pane.Description = descriptions[pane.PaneID]
		} else if existing[pane.PaneID].Agent == agent {
			pane.Description = existing[pane.PaneID].Description
		}
		rows = append(rows, pane)
	}

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.Exec("DELETE FROM agent_sessions"); err != nil {
		return err
	}
	for _, row := range rows {
		if err := upsertExecutor(tx, row); err != nil {
			return err
		}
	}
	return tx.Commit()
}

func tmuxPanes() ([]agentSession, error) {
	const separator = "\x1f"
	format := strings.Join([]string{
		"#{pane_id}", "#{pane_tty}", "#{session_id}", "#{session_name}", "#{window_id}",
		"#{window_name}", "#{pane_index}", "#{pane_current_path}", "#{pane_title}",
	}, separator)
	output, err := commandOutput("tmux", "list-panes", "-a", "-F", format)
	if err != nil {
		return nil, err
	}
	var rows []agentSession
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		fields := strings.Split(line, separator)
		if len(fields) != 9 {
			continue
		}
		index, _ := strconv.Atoi(fields[6])
		rows = append(rows, agentSession{
			PaneID: fields[0], TTY: fields[1], SessionID: fields[2], SessionName: fields[3],
			WindowID: fields[4], WindowName: fields[5], PaneIndex: index, Path: fields[7],
			Title: fields[8],
		})
	}
	return rows, nil
}

func detectedAgents() (map[string]string, error) {
	processes := configuredValue("@agent-indicator-processes", defaultProcesses)
	dir := os.Getenv("TMUX_AGENT_INDICATOR_DIR")
	if dir == "" {
		dir = filepath.Clean(filepath.Join(filepath.Dir(os.Args[0]), ".."))
	}
	output, err := commandOutput("bash", filepath.Join(dir, "scripts", "process-detection.sh"), "--snapshot", processes)
	if err != nil {
		return nil, err
	}
	result := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(output), "\n") {
		fields := strings.SplitN(line, "\t", 2)
		if len(fields) == 2 {
			result[fields[0]] = fields[1]
		}
	}
	return result, nil
}

func parseEnvironment(output string) (map[string]string, map[string]string, map[string]string, map[string]string) {
	agents := map[string]string{}
	states := map[string]string{}
	descriptions := map[string]string{}
	active := map[string]string{}
	for _, line := range strings.Split(output, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch {
		case strings.HasPrefix(key, "TMUX_AGENT_PANE_") && strings.HasSuffix(key, "_AGENT"):
			agents[strings.TrimSuffix(strings.TrimPrefix(key, "TMUX_AGENT_PANE_"), "_AGENT")] = value
		case strings.HasPrefix(key, "TMUX_AGENT_PANE_") && strings.HasSuffix(key, "_STATE"):
			states[strings.TrimSuffix(strings.TrimPrefix(key, "TMUX_AGENT_PANE_"), "_STATE")] = value
		case strings.HasPrefix(key, "TMUX_AGENT_PANE_") && strings.HasSuffix(key, "_DESCRIPTION"):
			descriptions[strings.TrimSuffix(strings.TrimPrefix(key, "TMUX_AGENT_PANE_"), "_DESCRIPTION")] = value
		case strings.HasPrefix(key, "TMUX_AGENT_ACTIVE_PANE_"):
			active[value] = strings.TrimPrefix(key, "TMUX_AGENT_ACTIVE_PANE_")
		}
	}
	return agents, states, descriptions, active
}

func existingSessions(db *sql.DB) (map[string]agentSession, error) {
	rows, err := listSessions(db, "")
	if err != nil {
		return nil, err
	}
	result := make(map[string]agentSession, len(rows))
	for _, row := range rows {
		result[row.PaneID] = row
	}
	return result, nil
}

func listSessions(db *sql.DB, sessionID string) ([]agentSession, error) {
	query := `SELECT pane_id, session_id, window_id, session_name, window_name, pane_index,
		state, agent, path, title, description FROM agent_sessions`
	args := []any{}
	if sessionID != "" {
		query += " WHERE session_id = ?"
		args = append(args, sessionID)
	}
	query += " ORDER BY session_name, window_name, path, pane_index, pane_id"
	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var result []agentSession
	for rows.Next() {
		var row agentSession
		if err := rows.Scan(&row.PaneID, &row.SessionID, &row.WindowID, &row.SessionName, &row.WindowName,
			&row.PaneIndex, &row.State, &row.Agent, &row.Path, &row.Title, &row.Description); err != nil {
			return nil, err
		}
		result = append(result, row)
	}
	return result, rows.Err()
}

type sqlExecutor interface {
	Exec(query string, args ...any) (sql.Result, error)
}

func upsert(db *sql.DB, row agentSession) error {
	return upsertExecutor(db, row)
}

func upsertExecutor(executor sqlExecutor, row agentSession) error {
	_, err := executor.Exec(`
		INSERT INTO agent_sessions (
			pane_id, session_id, window_id, session_name, window_name, pane_index,
			state, agent, path, title, description, updated_at
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(pane_id) DO UPDATE SET
			session_id=excluded.session_id, window_id=excluded.window_id,
			session_name=excluded.session_name, window_name=excluded.window_name,
			pane_index=excluded.pane_index, state=excluded.state, agent=excluded.agent,
			path=excluded.path, title=excluded.title, description=excluded.description,
			updated_at=excluded.updated_at
	`, row.PaneID, row.SessionID, row.WindowID, row.SessionName, row.WindowName, row.PaneIndex,
		row.State, row.Agent, row.Path, row.Title, row.Description, time.Now().UnixMilli())
	return err
}

func configuredValue(option, fallback string) string {
	output, err := commandOutput("tmux", "show-option", "-gqv", option)
	if err != nil || strings.TrimSpace(output) == "" {
		return fallback
	}
	return strings.TrimSpace(output)
}

func configuredSet(option, fallback string) map[string]bool {
	result := map[string]bool{}
	for _, value := range strings.Split(configuredValue(option, fallback), ",") {
		value = strings.TrimSpace(value)
		if value != "" {
			result[value] = true
		}
	}
	return result
}

func validState(state string) bool {
	return state == "running" || state == "needs-input" || state == "done" || state == "idle"
}

func commandOutput(name string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	command.Env = os.Environ()
	output, err := command.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return "", fmt.Errorf("%s: %s", name, strings.TrimSpace(string(exitErr.Stderr)))
		}
		return "", err
	}
	return string(output), nil
}

func storePaths() paths {
	if root := os.Getenv("TMUX_AGENT_STORE_DIR"); root != "" {
		return paths{socket: filepath.Join(root, "store.sock"), db: filepath.Join(root, "store.db"), log: filepath.Join(root, "store.log")}
	}
	tmuxSocket := strings.SplitN(os.Getenv("TMUX"), ",", 2)[0]
	if tmuxSocket == "" {
		tmuxSocket = "default"
	}
	sum := sha256.Sum256([]byte(tmuxSocket))
	key := hex.EncodeToString(sum[:8])
	stateRoot := os.Getenv("XDG_STATE_HOME")
	if stateRoot == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			stateRoot = os.TempDir()
		} else {
			stateRoot = filepath.Join(home, ".local", "state")
		}
	}
	stateRoot = filepath.Join(stateRoot, "tmux-agent-indicator")
	runtimeRoot := filepath.Join(os.TempDir(), "tmux-agent-indicator-"+strconv.Itoa(os.Getuid()))
	return paths{
		socket: filepath.Join(runtimeRoot, key+".sock"),
		db:     filepath.Join(stateRoot, key+".db"),
		log:    filepath.Join(stateRoot, key+".log"),
	}
}

func clean(value string) string {
	return strings.Map(func(r rune) rune {
		if r == '\t' || r == '\n' || r == '\r' || r == 0 {
			return ' '
		}
		return r
	}, value)
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
