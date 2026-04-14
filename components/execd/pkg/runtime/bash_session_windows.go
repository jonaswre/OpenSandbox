// Copyright 2026 Alibaba Group Holding Ltd.
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
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"sync"

	"github.com/google/uuid"

	"github.com/alibaba/opensandbox/execd/pkg/log"
)

const (
	psEnvDumpStartMarker = "__ENV_DUMP_START__"
	psEnvDumpEndMarker   = "__ENV_DUMP_END__"
	psExitMarkerPrefix   = "__EXIT_CODE__:"
	psPwdMarkerPrefix    = "__PWD__:"
)

// powershellSession holds state for a persistent PowerShell session on Windows.
// The struct is stored in bashSessionClientMap under the session ID so it
// shares the sync.Map key pattern with the Linux bashSession.
type powershellSession struct {
	sessionID string
	mu        sync.Mutex
	started   bool
	env       map[string]string
	cwd       string

	// currentProcessPid is the pid of the active run's powershell process.
	// Set after cmd.Start(), cleared when run() returns.
	// Used by close() to kill the active process.
	currentProcessPid int
}

func newPowershellSession(cwd string) *powershellSession {
	env := make(map[string]string)
	for _, kv := range os.Environ() {
		if k, v, ok := splitEnvPair(kv); ok {
			env[k] = v
		}
	}

	return &powershellSession{
		sessionID: uuid.New().String(),
		env:       env,
		cwd:       cwd,
	}
}

func (s *powershellSession) start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return errors.New("session already started")
	}

	s.started = true
	return nil
}

func (s *powershellSession) trackCurrentProcess(pid int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentProcessPid = pid
}

func (s *powershellSession) untrackCurrentProcess() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentProcessPid = 0
}

// lockAndGetState implements sessionState for powershellSession.
func (s *powershellSession) lockAndGetState() (map[string]string, string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.started {
		return nil, "", "", errors.New("session not started")
	}
	return copyEnvMap(s.env), s.cwd, s.sessionID, nil
}

// trackProcess implements sessionState for powershellSession.
func (s *powershellSession) trackProcess(pid int) {
	s.trackCurrentProcess(pid)
}

// untrackProcess implements sessionState for powershellSession.
func (s *powershellSession) untrackProcess() {
	s.untrackCurrentProcess()
}

// updateEnvAndCwd implements sessionState for powershellSession.
func (s *powershellSession) updateEnvAndCwd(env map[string]string, cwd string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(env) > 0 {
		s.env = env
	}
	if cwd != "" {
		s.cwd = cwd
	}
}

func (s *powershellSession) run(ctx context.Context, request *ExecuteCodeRequest) error {
	cfg := sessionRunConfig{
		markers: markerSet{
			envDumpStart: psEnvDumpStartMarker,
			envDumpEnd:   psEnvDumpEndMarker,
			exitPrefix:   psExitMarkerPrefix,
			pwdPrefix:    psPwdMarkerPrefix,
		},
		buildScript: buildWrappedPSScript,
		parseEnv:    parsePSEnvDump,
		buildCmdFromScript: func(ctx context.Context, script string) *exec.Cmd {
			// Use getShell() for consistency with command execution (prefers pwsh over powershell).
			shell := getShell()
			cmd := exec.CommandContext(ctx, shell,
				"-NoProfile",
				"-NonInteractive",
				"-ExecutionPolicy", "Bypass",
				"-Command", "-",
			)
			cmd.Stdin = strings.NewReader(script)
			return cmd
		},
	}
	return runSessionScript(ctx, request, s, cfg)
}

func (s *powershellSession) close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	pid := s.currentProcessPid
	s.currentProcessPid = 0
	s.started = false
	s.env = nil
	s.cwd = ""

	if pid != 0 {
		proc, err := os.FindProcess(pid)
		if err == nil {
			if killErr := proc.Kill(); killErr != nil {
				log.Warning("kill powershell process %d: %v (process may have already exited)", pid, killErr)
			}
		}
	}
	return nil
}

// buildWrappedPSScript constructs a PowerShell script that:
// 1. Sets all persisted environment variables.
// 2. Changes to the target working directory.
// 3. Runs the user's code.
// 4. Emits env-dump, pwd, and exit-code markers for state capture.
func buildWrappedPSScript(command string, env map[string]string, cwd string) string {
	var b strings.Builder

	// Set persisted environment variables.
	for k, v := range env {
		if isValidEnvKey(k) && !psEnvKeysNotPersisted[k] && len(v) <= maxPersistedEnvValueSize {
			b.WriteString(fmt.Sprintf("$env:%s = %s\n", k, psSingleQuote(v)))
		}
	}

	// Change to working directory.
	if cwd != "" {
		b.WriteString(fmt.Sprintf("Set-Location -LiteralPath %s\n", psSingleQuote(cwd)))
	}

	// Run the user's code.
	b.WriteString(command)
	if !strings.HasSuffix(command, "\n") {
		b.WriteString("\n")
	}

	// Capture user exit code via $LASTEXITCODE (external processes) or $? (cmdlets).
	// We store both: prefer $LASTEXITCODE when non-null (set by external executables),
	// otherwise fall back to the boolean $? converted to 0/1.
	b.WriteString("$__user_exit__ = if ($LASTEXITCODE -ne $null) { $LASTEXITCODE } else { if ($?) { 0 } else { 1 } }\n")

	// Emit env dump.
	b.WriteString(fmt.Sprintf("Write-Output \"`n%s\"\n", psEnvDumpStartMarker))
	b.WriteString("Get-ChildItem Env: | ForEach-Object { Write-Output \"$($_.Name)=$($_.Value)\" }\n")
	b.WriteString(fmt.Sprintf("Write-Output \"%s\"\n", psEnvDumpEndMarker))

	// Emit current directory.
	b.WriteString(fmt.Sprintf("Write-Output \"%s$((Get-Location).Path)\"\n", psPwdMarkerPrefix))

	// Emit exit code and exit with it.
	b.WriteString(fmt.Sprintf("Write-Output \"%s$__user_exit__\"\n", psExitMarkerPrefix))
	b.WriteString("exit $__user_exit__\n")

	return b.String()
}

// psEnvKeysNotPersisted are variables not carried across runs on Windows.
var psEnvKeysNotPersisted = map[string]bool{
	"PROMPT": true,
}

// parsePSEnvDump converts "KEY=VALUE" lines emitted by Get-ChildItem Env:
// into a map. Values may contain "=" so we split only on the first occurrence.
func parsePSEnvDump(lines []string) map[string]string {
	if len(lines) == 0 {
		return nil
	}
	env := make(map[string]string, len(lines))
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		idx := strings.Index(line, "=")
		if idx <= 0 {
			continue
		}
		k := line[:idx]
		v := line[idx+1:]
		if !isValidEnvKey(k) || psEnvKeysNotPersisted[k] || len(v) > maxPersistedEnvValueSize {
			continue
		}
		env[k] = v
	}
	return env
}

// psSingleQuote wraps a string in PowerShell single quotes, escaping embedded
// single quotes by doubling them (PowerShell convention: '' inside '...').
func psSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// Controller-level helpers that mirror the Linux createBashSession / runBashSession /
// closeBashSession pattern but store *powershellSession in bashSessionClientMap.

func (c *Controller) createPowershellSession(req *CreateContextRequest) (string, error) {
	if req.Cwd != "" {
		if err := os.MkdirAll(req.Cwd, os.ModePerm); err != nil {
			return "", err
		}
	}

	session := newPowershellSession(req.Cwd)
	if err := session.start(); err != nil {
		return "", fmt.Errorf("failed to start powershell session: %w", err)
	}

	c.bashSessionClientMap.Store(session.sessionID, session)
	log.Info("created powershell session %s", session.sessionID)
	return session.sessionID, nil
}

func (c *Controller) runPowershellSession(ctx context.Context, request *ExecuteCodeRequest) error {
	session := c.getPowershellSession(request.Context)
	if session == nil {
		return ErrContextNotFound
	}
	return session.run(ctx, request)
}

func (c *Controller) getPowershellSession(sessionID string) *powershellSession {
	if v, ok := c.bashSessionClientMap.Load(sessionID); ok {
		if s, ok := v.(*powershellSession); ok {
			return s
		}
	}
	return nil
}

func (c *Controller) closePowershellSession(sessionID string) error {
	session := c.getPowershellSession(sessionID)
	if session == nil {
		return ErrContextNotFound
	}
	if err := session.close(); err != nil {
		return err
	}
	c.bashSessionClientMap.Delete(sessionID)
	return nil
}

// CreateBashSession creates a persistent PowerShell session on Windows.
func (c *Controller) CreateBashSession(req *CreateContextRequest) (string, error) {
	return c.createPowershellSession(req)
}

// RunInBashSession runs code inside the PowerShell session on Windows.
func (c *Controller) RunInBashSession(ctx context.Context, req *ExecuteCodeRequest) error {
	return c.runPowershellSession(ctx, req)
}

// DeleteBashSession closes and removes the PowerShell session on Windows.
func (c *Controller) DeleteBashSession(sessionID string) error {
	return c.closePowershellSession(sessionID)
}

