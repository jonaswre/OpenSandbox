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

package runtime

import (
	"errors"
	"io"
	"os"
	"sync"
	"sync/atomic"

	"github.com/alibaba/opensandbox/execd/pkg/log"
	"github.com/google/uuid"
)

// PTYSession is the public interface for an interactive PTY/pipe session.
// The concrete implementation (*ptySession) is unexported; callers outside
// this package must use this interface.
type PTYSession interface {
	LockWS() bool
	UnlockWS()
	IsRunning() bool
	IsPTY() bool
	ExitCode() int
	Done() <-chan struct{}
	StartPTY() error
	StartPipe() error
	WriteStdin(p []byte) (int, error)
	AttachOutput() (io.Reader, io.Reader, func())
	AttachOutputWithSnapshot(since int64) (io.Reader, io.Reader, func(), []byte, int64)
	SendSignal(name string)
	ResizePTY(cols, rows uint16) error
}

// NewPTYSessionID returns a new unique session ID.
func NewPTYSessionID() string {
	return uuid.New().String()
}

// ptySessionBase holds fields and methods shared between Linux and Windows ptySession.
type ptySessionBase struct {
	id  string
	cwd string

	mu      sync.Mutex
	closing bool

	lastExitCode int
	doneCh       chan struct{}

	stdin io.WriteCloser

	replay *replayBuffer

	// WS exclusive lock: only one WebSocket client at a time.
	wsConnected atomic.Bool

	// Output broadcast (guards stdoutW / stderrW).
	outMu   sync.Mutex
	stdoutW *io.PipeWriter
	stderrW *io.PipeWriter
}

// newPTYSessionBase returns an initialised ptySessionBase.
func newPTYSessionBase(id, cwd string) ptySessionBase {
	return ptySessionBase{
		id:           id,
		cwd:          cwd,
		replay:       newReplayBuffer(),
		lastExitCode: -1,
	}
}

// LockWS attempts to acquire the exclusive WebSocket connection lock.
// Returns true on success, false if another client is already connected.
func (s *ptySessionBase) LockWS() bool {
	return s.wsConnected.CompareAndSwap(false, true)
}

// UnlockWS releases the WebSocket connection lock.
func (s *ptySessionBase) UnlockWS() {
	s.wsConnected.Store(false)
}

// ExitCode returns the exit code of the last process, or -1 if it has not exited yet.
func (s *ptySessionBase) ExitCode() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastExitCode
}

// Done returns a channel that is closed when the process exits.
// Returns nil if the process has not been started yet.
func (s *ptySessionBase) Done() <-chan struct{} {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.doneCh
}

// ReplayBuffer returns the session's replay buffer (thread-safe).
func (s *ptySessionBase) ReplayBuffer() *replayBuffer {
	return s.replay
}

// WriteStdin writes p to the process stdin (PTY master or pipe write-end).
func (s *ptySessionBase) WriteStdin(p []byte) (int, error) {
	s.mu.Lock()
	w := s.stdin
	s.mu.Unlock()
	if w == nil {
		return 0, errors.New("session not started")
	}
	return w.Write(p)
}

// writeAndFanout writes chunk to the replay buffer and delivers it to the
// active per-connection pipe, atomically under outMu.
//
// Holding outMu across both operations closes the window where bytes written
// to replay after ReadFrom but before AttachOutput would be silently dropped.
// Lock order is always outMu → replay.mu (both paths), so no deadlock is possible.
func (s *ptySessionBase) writeAndFanout(chunk []byte, isStdout bool) {
	s.outMu.Lock()
	s.replay.write(chunk) // acquires replay.mu inside (outMu → replay.mu)
	var w *io.PipeWriter
	if isStdout {
		w = s.stdoutW
	} else {
		w = s.stderrW
	}
	s.outMu.Unlock()

	if w != nil {
		if _, err := w.Write(chunk); err != nil {
			// Pipe was closed (client detached) — ignore.
			log.Warning("pty fanout write: %v", err)
		}
	}
}

// broadcastPipe reads from a pipe (stdout or stderr) and fans out to replay + active WS client.
func (s *ptySessionBase) broadcastPipe(r *os.File, isStdout bool) {
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			s.writeAndFanout(buf[:n], isStdout)
		}
		if err != nil {
			break
		}
	}
	_ = r.Close()
}
