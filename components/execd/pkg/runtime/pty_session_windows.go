// Copyright 2025 Alibaba Group Holding Ltd.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//go:build windows
// +build windows

package runtime

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"

	"github.com/alibaba/opensandbox/execd/pkg/log"
	"github.com/alibaba/opensandbox/internal/safego"
)

// errConPTYNotSupported is returned by StartPTY on Windows until ConPTY
// integration is completed in Phase 4.
var errConPTYNotSupported = errors.New("ConPTY is not yet supported on Windows (Phase 4 enhancement)")

var errPTYSessionNotSupported = errors.New("pty session is not supported on windows")

// IsPTYSessionSupported reports whether PTY sessions are supported on this
// platform. ConPTY integration is a Phase 4 enhancement; pipe-based sessions
// are available but true PTY allocation is not.
func IsPTYSessionSupported() bool { return false }

// ptySession manages a single pipe-based interactive session on Windows.
//
// True PTY support (ConPTY) is a Phase 4 enhancement. Until then, sessions
// run cmd.exe (or PowerShell) with plain stdin/stdout/stderr pipes, providing
// a functional "dumb terminal" that can execute commands and relay I/O.
//
// Lifecycle:
//  1. Create via CreatePTYSession.
//  2. Call StartPipe() to launch the shell (StartPTY returns an error).
//  3. Zero or more clients call AttachOutput() to receive live output.
//  4. The shell process exits → Done() closes.
type ptySession struct {
	ptySessionBase

	// Process tracking (guarded by mu)
	cmd *exec.Cmd // nil until StartPipe succeeds
}

func newPTYSession(id, cwd string) *ptySession {
	return &ptySession{
		ptySessionBase: newPTYSessionBase(id, cwd),
	}
}

// IsRunning returns true if the shell process is currently alive.
func (s *ptySession) IsRunning() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cmd != nil && s.cmd.ProcessState == nil
}

// IsPTY returns false on Windows because ConPTY is not yet integrated.
// Phase 4 will return true when ConPTY allocation succeeds.
func (s *ptySession) IsPTY() bool { return false }

// StartPTY is not yet implemented on Windows.
// ConPTY integration is planned as a Phase 4 enhancement.
func (s *ptySession) StartPTY() error {
	return errConPTYNotSupported
}

// StartPipe launches cmd.exe with plain stdin/stdout/stderr pipes.
// This provides a functional "dumb terminal" session without ConPTY.
// Must be called with the WS lock held.
func (s *ptySession) StartPipe() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.cmd != nil {
		return errors.New("pty session already started")
	}
	if s.closing {
		return errors.New("pty session is closing")
	}

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return fmt.Errorf("stdin pipe: %w", err)
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		_ = stdinR.Close()
		_ = stdinW.Close()
		return fmt.Errorf("stdout pipe: %w", err)
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		_ = stdinR.Close()
		_ = stdinW.Close()
		_ = stdoutR.Close()
		_ = stdoutW.Close()
		return fmt.Errorf("stderr pipe: %w", err)
	}

	cmd := exec.Command("cmd.exe")
	cmd.Env = os.Environ()
	if s.cwd != "" {
		cmd.Dir = s.cwd
	}
	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW

	if err := cmd.Start(); err != nil {
		_ = stdinR.Close()
		_ = stdinW.Close()
		_ = stdoutR.Close()
		_ = stdoutW.Close()
		_ = stderrR.Close()
		_ = stderrW.Close()
		return fmt.Errorf("cmd.Start: %w", err)
	}

	// Close the child-side ends in the parent — the child has its own copies.
	_ = stdinR.Close()
	_ = stdoutW.Close()
	_ = stderrW.Close()

	s.cmd = cmd
	s.doneCh = make(chan struct{})
	s.stdin = stdinW

	safego.Go(func() { s.broadcastPipe(stdoutR, true) })
	safego.Go(func() { s.broadcastPipe(stderrR, false) })
	safego.Go(func() { s.waitAndExit(cmd, stdinW, stdoutR, stderrR) })

	return nil
}

// waitAndExit waits for the process and updates session state on exit.
func (s *ptySession) waitAndExit(cmd *exec.Cmd, stdinW, stdoutR, stderrR *os.File) {
	_ = cmd.Wait()
	_ = stdinW.Close()

	s.mu.Lock()
	exitCode := 0
	if cmd.ProcessState != nil {
		exitCode = cmd.ProcessState.ExitCode()
	}
	s.lastExitCode = exitCode
	doneCh := s.doneCh
	s.mu.Unlock()

	close(doneCh)
}

// AttachOutput creates a fresh per-connection io.Pipe and swaps it into the
// broadcast fanout path. Returns (stdout reader, stderr reader, detach func).
func (s *ptySession) AttachOutput() (io.Reader, io.Reader, func()) {
	stdoutR, stdoutW := io.Pipe()
	stderrR, stderrW := io.Pipe()

	s.outMu.Lock()
	s.stdoutW = stdoutW
	s.stderrW = stderrW
	s.outMu.Unlock()

	detach := func() {
		s.outMu.Lock()
		s.stdoutW = nil
		s.stderrW = nil
		s.outMu.Unlock()
		_ = stdoutW.Close()
		_ = stderrW.Close()
	}
	return stdoutR, stderrR, detach
}

// AttachOutputWithSnapshot atomically snapshots the replay buffer and attaches
// the per-connection output pipe.
func (s *ptySession) AttachOutputWithSnapshot(since int64) (io.Reader, io.Reader, func(), []byte, int64) {
	stdoutR, stdoutW := io.Pipe()
	stderrR, stderrW := io.Pipe()

	s.outMu.Lock()
	snapshotBytes, snapshotOffset := s.replay.ReadFrom(since)
	s.stdoutW = stdoutW
	s.stderrW = stderrW
	s.outMu.Unlock()

	detach := func() {
		s.outMu.Lock()
		s.stdoutW = nil
		s.stderrW = nil
		s.outMu.Unlock()
		_ = stdoutW.Close()
		_ = stderrW.Close()
	}
	return stdoutR, stderrR, detach, snapshotBytes, snapshotOffset
}

// SendSignal sends a signal to the running process.
// On Windows, only SIGKILL semantics (process termination) are available.
// All signal names result in process.Kill().
func (s *ptySession) SendSignal(name string) {
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	if err := cmd.Process.Kill(); err != nil {
		log.Warning("ptySession.SendSignal(%s) kill: %v", name, err)
	}
}

// ResizePTY is a no-op on Windows until ConPTY is integrated (Phase 4).
func (s *ptySession) ResizePTY(_, _ uint16) error { return nil }

// close terminates the session and releases all resources.
// Safe to call multiple times.
func (s *ptySession) close() {
	s.mu.Lock()
	if s.closing {
		s.mu.Unlock()
		return
	}
	s.closing = true
	cmd := s.cmd
	stdin := s.stdin
	s.mu.Unlock()

	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	if stdin != nil {
		_ = stdin.Close()
	}

	s.outMu.Lock()
	stdoutW := s.stdoutW
	stderrW := s.stderrW
	s.stdoutW = nil
	s.stderrW = nil
	s.outMu.Unlock()
	if stdoutW != nil {
		_ = stdoutW.Close()
	}
	if stderrW != nil {
		_ = stderrW.Close()
	}
}

// CreatePTYSession creates a new pipe-based session and stores it in the map.
// Note: IsPTYSessionSupported() returns false because true PTY (ConPTY) is not
// yet integrated. Callers that check IsPTYSessionSupported() will not reach
// this path in normal operation; it is provided for completeness and testing.
func (c *Controller) CreatePTYSession(id, cwd string) (PTYSession, error) {
	if cwd != "" {
		if err := os.MkdirAll(cwd, os.ModePerm); err != nil {
			return nil, fmt.Errorf("error creating PTY session work directory: %w", err)
		}
	}
	s := newPTYSession(id, cwd)
	c.ptySessionMap.Store(id, s)
	log.Info("created pty session %s (pipe mode, ConPTY is Phase 4)", id)
	return s, nil
}

// getPTYSession looks up a PTY session by ID. Returns nil if not found.
func (c *Controller) getPTYSession(id string) *ptySession {
	if v, ok := c.ptySessionMap.Load(id); ok {
		if s, ok := v.(*ptySession); ok {
			return s
		}
	}
	return nil
}

// GetPTYSession looks up a PTY session by ID. Returns nil if not found.
func (c *Controller) GetPTYSession(id string) PTYSession {
	s := c.getPTYSession(id)
	if s == nil {
		return nil
	}
	return s
}

// DeletePTYSession terminates and removes a PTY session.
// Returns ErrContextNotFound if the session does not exist.
func (c *Controller) DeletePTYSession(id string) error {
	s := c.getPTYSession(id)
	if s == nil {
		return ErrContextNotFound
	}
	s.close()
	c.ptySessionMap.Delete(id)
	log.Info("deleted pty session %s", id)
	return nil
}

// GetPTYSessionStatus returns status information for a PTY session.
func (c *Controller) GetPTYSessionStatus(id string) (running bool, outputOffset int64, err error) {
	s := c.getPTYSession(id)
	if s == nil {
		return false, 0, ErrContextNotFound
	}
	return s.IsRunning(), s.replay.Total(), nil
}
