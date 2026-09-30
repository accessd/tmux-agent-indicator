package main

import (
	"path/filepath"
	"testing"
)

func TestSQLitePersistsSessions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "store.db")
	db, err := openDatabase(path)
	if err != nil {
		t.Fatal(err)
	}
	want := agentSession{
		PaneID: "%7", SessionID: "$1", WindowID: "@2", SessionName: "work",
		WindowName: "code", PaneIndex: 3, State: "running", Agent: "codex",
		Path: "/tmp/project", Title: "codex", Description: "Fix store",
	}
	if err := upsert(db, want); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	db, err = openDatabase(path)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	rows, err := listSessions(db, "$1")
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 1 || rows[0].PaneID != want.PaneID || rows[0].Description != want.Description {
		t.Fatalf("unexpected persisted sessions: %#v", rows)
	}
}
