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
	"time"

	"github.com/alibaba/opensandbox/execd/pkg/jupyter/execute"
	"github.com/alibaba/opensandbox/execd/pkg/log"
)

// markerSet holds the delimiter strings used to parse structured output
// emitted by the wrapped script.
type markerSet struct {
	envDumpStart string
	envDumpEnd   string
	exitPrefix   string
	pwdPrefix    string
}

// sessionRunConfig holds platform-specific callbacks for the shared session runner.
type sessionRunConfig struct {
	markers     markerSet
	buildScript func(command string, env map[string]string, cwd string) string
	parseEnv    func(lines []string) map[string]string
	// buildCmd is called with a temp script file path.  Used when the platform
	// needs a file-based invocation (e.g. bash on Linux).
	buildCmd func(ctx context.Context, scriptPath string) *exec.Cmd
	// buildCmdFromScript, when non-nil, is called with the raw script string.
	// When set, no temp file is created and buildCmd is ignored.
	// Used by platforms that support stdin-based script delivery (e.g. PowerShell).
	buildCmdFromScript func(ctx context.Context, script string) *exec.Cmd
}

// sessionState abstracts the state that both bashSession (Linux) and
// powershellSession (Windows) expose to the shared runner.
type sessionState interface {
	// lockAndGetState acquires the session lock, validates that the session is
	// started, snapshots env/cwd/sessionID, then releases the lock.
	lockAndGetState() (env map[string]string, cwd string, sessionID string, err error)
	// trackProcess records the pid of the active child process.
	trackProcess(pid int)
	// untrackProcess clears the tracked pid (called on run return).
	untrackProcess()
	// updateEnvAndCwd persists the new environment map and working directory
	// into the session under the session's own mutex.
	updateEnvAndCwd(env map[string]string, cwd string)
}

// runSessionScript is the shared run-loop skeleton used by both bashSession
// (Linux) and powershellSession (Windows).  All platform-specific behaviour is
// supplied through cfg and state.
//
//nolint:gocognit
func runSessionScript(ctx context.Context, request *ExecuteCodeRequest, state sessionState, cfg sessionRunConfig) error {
	envSnapshot, cwd, sessionID, err := state.lockAndGetState()
	if err != nil {
		return err
	}

	// Override cwd when the request specifies one.
	if request.Cwd != "" {
		cwd = request.Cwd
	}

	startAt := time.Now()
	if request.Hooks.OnExecuteInit != nil {
		request.Hooks.OnExecuteInit(sessionID)
	}

	wait := request.Timeout
	if wait <= 0 {
		wait = 24 * 3600 * time.Second // cap at 24 hours
	}

	ctx, cancel := context.WithTimeout(ctx, wait)
	defer cancel()

	script := cfg.buildScript(request.Code, envSnapshot, cwd)

	var cmd *exec.Cmd
	if cfg.buildCmdFromScript != nil {
		// Stdin-based delivery: no temp file needed.
		cmd = cfg.buildCmdFromScript(ctx, script)
	} else {
		scriptFile, err := os.CreateTemp("", "execd_script_*")
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
		cmd = cfg.buildCmd(ctx, scriptPath)
	}

	// Do not pass envSnapshot via cmd.Env to avoid "argument list too long"
	// when the session environment is large.  The script file already has the
	// full set of "export"/"$env:" assignments at the top.
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("stdout pipe: %w", err)
	}
	cmd.Stderr = cmd.Stdout

	if err := cmd.Start(); err != nil {
		log.Error("start session failed: %v (command: %q)", err, request.Code)
		return fmt.Errorf("start process: %w", err)
	}
	defer state.untrackProcess()
	state.trackProcess(cmd.Process.Pid)

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), 16*1024*1024)

	var (
		envLines []string
		pwdLine  string
		exitCode *int
		inEnv    bool
	)

	m := cfg.markers
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == m.envDumpStart:
			inEnv = true
		case line == m.envDumpEnd:
			inEnv = false
		case strings.HasPrefix(line, m.exitPrefix):
			if code, err := strconv.Atoi(strings.TrimPrefix(line, m.exitPrefix)); err == nil {
				exitCode = &code //nolint:ineffassign
			}
		case strings.HasPrefix(line, m.pwdPrefix):
			pwdLine = strings.TrimPrefix(line, m.pwdPrefix)
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
		exitCode = &code                    //nolint:ineffassign
	}

	updatedEnv := cfg.parseEnv(envLines)
	state.updateEnvAndCwd(updatedEnv, pwdLine)

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
