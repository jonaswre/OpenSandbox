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
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/alibaba/opensandbox/execd/pkg/jupyter/execute"
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

//nolint:gocognit
func (s *powershellSession) run(ctx context.Context, request *ExecuteCodeRequest) error {
	s.mu.Lock()
	if !s.started {
		s.mu.Unlock()
		return errors.New("session not started")
	}

	envSnapshot := copyEnvMap(s.env)
	cwd := s.cwd
	if request.Cwd != "" {
		cwd = request.Cwd
	}
	sessionID := s.sessionID
	s.mu.Unlock()

	startAt := time.Now()
	if request.Hooks.OnExecuteInit != nil {
		request.Hooks.OnExecuteInit(sessionID)
	}

	wait := request.Timeout
	if wait <= 0 {
		wait = 24 * 3600 * time.Second
	}

	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()

	script := buildWrappedPSScript(request.Code, envSnapshot, cwd)
	scriptFile, err := os.CreateTemp("", "execd_ps_*.ps1")
	if err != nil {
		return fmt.Errorf("create script file: %w", err)
	}
	scriptPath := scriptFile.Name()
	if _, err := scriptFile.WriteString(script); err != nil {
		_ = scriptFile.Close()
		_ = os.Remove(scriptPath)
		return fmt.Errorf("write script file: %w", err)
	}
	if err := scriptFile.Close(); err != nil {
		_ = os.Remove(scriptPath)
		return fmt.Errorf("close script file: %w", err)
	}
	defer func() { _ = os.Remove(scriptPath) }()

	// Use getShell() for consistency with command execution (prefers pwsh over powershell).
	shell := getShell()
	cmd := exec.CommandContext(ctx, shell,
		"-NoProfile",
		"-NonInteractive",
		"-ExecutionPolicy", "Bypass",
		"-File", scriptPath,
	)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		log.Error("start powershell session failed: %v (command: %q)", err, request.Code)
		return fmt.Errorf("start powershell: %w", err)
	}
	defer s.untrackCurrentProcess()
	s.trackCurrentProcess(cmd.Process.Pid)

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	var (
		envLines []string
		pwdLine  string
		exitCode *int
		inEnv    bool
	)

	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == psEnvDumpStartMarker:
			inEnv = true
		case line == psEnvDumpEndMarker:
			inEnv = false
		case strings.HasPrefix(line, psExitMarkerPrefix):
			if code, err := strconv.Atoi(strings.TrimPrefix(line, psExitMarkerPrefix)); err == nil {
				exitCode = &code			}
		case strings.HasPrefix(line, psPwdMarkerPrefix):
			pwdLine = strings.TrimPrefix(line, psPwdMarkerPrefix)
		default:
			if inEnv {
				envLines = append(envLines, line)
				continue
			}
			if request.Hooks.OnExecuteStdout != nil {
				request.Hooks.OnExecuteStdout(line)
			}
		}
	}

	scanErr := scanner.Err()
	waitErr := cmd.Wait()

	if scanErr != nil {
		log.Error("read stdout failed: %v (command: %q)", scanErr, request.Code)
		return fmt.Errorf("read stdout: %w", scanErr)
	}

	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		log.Error("timeout after %s while running command: %q", wait, request.Code)
		return fmt.Errorf("timeout after %s while running command %q", wait, request.Code)
	}

	if exitCode == nil && cmd.ProcessState != nil {
		code := cmd.ProcessState.ExitCode() //nolint:staticcheck
		exitCode = &code                   	}

	updatedEnv := parsePSEnvDump(envLines)
	s.mu.Lock()
	if len(updatedEnv) > 0 {
		s.env = updatedEnv
	}
	if pwdLine != "" {
		s.cwd = pwdLine
	}
	s.mu.Unlock()

	var exitErr *exec.ExitError
	if waitErr != nil && !errors.As(waitErr, &exitErr) {
		log.Error("command wait failed: %v (command: %q)", waitErr, request.Code)
		return waitErr
	}

	userExitCode := 0
	if exitCode != nil {
		userExitCode = *exitCode
	}

	if userExitCode != 0 {
		errMsg := fmt.Sprintf("command exited with code %d", userExitCode)
		if waitErr != nil {
			errMsg = waitErr.Error()
		}
		if request.Hooks.OnExecuteError != nil {
			request.Hooks.OnExecuteError(&execute.ErrorOutput{
				EName:     "CommandExecError",
				EValue:    strconv.Itoa(userExitCode),
				Traceback: []string{errMsg},
			})
		}
		log.Error("CommandExecError: %s (command: %q)", errMsg, request.Code)
		return nil
	}

	if request.Hooks.OnExecuteComplete != nil {
		request.Hooks.OnExecuteComplete(time.Since(startAt))
	}

	return nil
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

