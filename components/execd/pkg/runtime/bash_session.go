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

//go:build !windows
// +build !windows

package runtime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"

	"github.com/alibaba/opensandbox/execd/pkg/log"
)

const (
	envDumpStartMarker = "__ENV_DUMP_START__"
	envDumpEndMarker   = "__ENV_DUMP_END__"
	exitMarkerPrefix   = "__EXIT_CODE__:"
	pwdMarkerPrefix    = "__PWD__:"
)

func (c *Controller) createBashSession(req *CreateContextRequest) (string, error) {
	if req.Cwd != "" {
		err := os.MkdirAll(req.Cwd, os.ModePerm)
		if err != nil {
			return "", err
		}
	}

	session := newBashSession(req.Cwd)
	if err := session.start(); err != nil {
		return "", fmt.Errorf("failed to start bash session: %w", err)
	}

	c.bashSessionClientMap.Store(session.config.Session, session)
	log.Info("created bash session %s", session.config.Session)
	return session.config.Session, nil
}

func (c *Controller) runBashSession(ctx context.Context, request *ExecuteCodeRequest) error {
	session := c.getBashSession(request.Context)
	if session == nil {
		return ErrContextNotFound
	}

	return session.run(ctx, request)
}

func (c *Controller) getBashSession(sessionId string) *bashSession {
	if v, ok := c.bashSessionClientMap.Load(sessionId); ok {
		if s, ok := v.(*bashSession); ok {
			return s
		}
	}
	return nil
}

func (c *Controller) closeBashSession(sessionId string) error {
	session := c.getBashSession(sessionId)
	if session == nil {
		return ErrContextNotFound
	}

	err := session.close()
	if err != nil {
		return err
	}

	c.bashSessionClientMap.Delete(sessionId)
	return nil
}

func (c *Controller) CreateBashSession(req *CreateContextRequest) (string, error) {
	return c.createBashSession(req)
}

func (c *Controller) RunInBashSession(ctx context.Context, req *ExecuteCodeRequest) error {
	return c.runBashSession(ctx, req)
}

func (c *Controller) DeleteBashSession(sessionID string) error {
	return c.closeBashSession(sessionID)
}

func newBashSession(cwd string) *bashSession {
	config := &bashSessionConfig{
		Session:        uuidString(),
		StartupTimeout: 5 * time.Second,
	}

	env := make(map[string]string)
	for _, kv := range os.Environ() {
		if k, v, ok := splitEnvPair(kv); ok {
			env[k] = v
		}
	}

	return &bashSession{
		config: config,
		env:    env,
		cwd:    cwd,
	}
}

func (s *bashSession) start() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.started {
		return errors.New("session already started")
	}

	s.started = true
	return nil
}

func (s *bashSession) trackCurrentProcess(pid int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentProcessPid = pid
}

func (s *bashSession) untrackCurrentProcess() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.currentProcessPid = 0
}

// lockAndGetState implements sessionState for bashSession.
func (s *bashSession) lockAndGetState() (map[string]string, string, string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.started {
		return nil, "", "", errors.New("session not started")
	}
	return copyEnvMap(s.env), s.cwd, s.config.Session, nil
}

// trackProcess implements sessionState for bashSession.
func (s *bashSession) trackProcess(pid int) {
	s.trackCurrentProcess(pid)
}

// untrackProcess implements sessionState for bashSession.
func (s *bashSession) untrackProcess() {
	s.untrackCurrentProcess()
}

// updateEnvAndCwd implements sessionState for bashSession.
func (s *bashSession) updateEnvAndCwd(env map[string]string, cwd string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(env) > 0 {
		s.env = env
	}
	if cwd != "" {
		s.cwd = cwd
	}
}

func (s *bashSession) run(ctx context.Context, request *ExecuteCodeRequest) error {
	cfg := sessionRunConfig{
		markers: markerSet{
			envDumpStart: envDumpStartMarker,
			envDumpEnd:   envDumpEndMarker,
			exitPrefix:   exitMarkerPrefix,
			pwdPrefix:    pwdMarkerPrefix,
		},
		buildScript: buildWrappedScript,
		parseEnv:    parseExportDump,
		buildCmd: func(ctx context.Context, scriptPath string) *exec.Cmd {
			cmd := exec.CommandContext(ctx, "bash", "--noprofile", "--norc", scriptPath)
			cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
			return cmd
		},
	}
	return runSessionScript(ctx, request, s, cfg)
}

func buildWrappedScript(command string, env map[string]string, cwd string) string {
	var b strings.Builder

	keys := make([]string, 0, len(env))
	for k := range env {
		v := env[k]
		if isValidEnvKey(k) && !envKeysNotPersisted[k] && len(v) <= maxPersistedEnvValueSize {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	for _, k := range keys {
		b.WriteString("export ")
		b.WriteString(k)
		b.WriteString("=")
		b.WriteString(shellEscape(env[k]))
		b.WriteString("\n")
	}

	if cwd != "" {
		b.WriteString("cd ")
		b.WriteString(shellEscape(cwd))
		b.WriteString("\n")
	}

	b.WriteString(command)
	if !strings.HasSuffix(command, "\n") {
		b.WriteString("\n")
	}

	b.WriteString("__USER_EXIT_CODE__=$?\n")
	b.WriteString("printf \"\\n%s\\n\" \"" + envDumpStartMarker + "\"\n")
	b.WriteString("export -p\n")
	b.WriteString("printf \"%s\\n\" \"" + envDumpEndMarker + "\"\n")
	b.WriteString("printf \"" + pwdMarkerPrefix + "%s\\n\" \"$(pwd)\"\n")
	b.WriteString("printf \"" + exitMarkerPrefix + "%s\\n\" \"$__USER_EXIT_CODE__\"\n")
	b.WriteString("exit \"$__USER_EXIT_CODE__\"\n")

	return b.String()
}

// envKeysNotPersisted are not carried across runs (prompt/display vars).
var envKeysNotPersisted = map[string]bool{
	"PS1": true, "PS2": true, "PS3": true, "PS4": true,
	"PROMPT_COMMAND": true,
}

func parseExportDump(lines []string) map[string]string {
	if len(lines) == 0 {
		return nil
	}
	env := make(map[string]string, len(lines))
	for _, line := range lines {
		k, v, ok := parseExportLine(line)
		if !ok || envKeysNotPersisted[k] || len(v) > maxPersistedEnvValueSize {
			continue
		}
		env[k] = v
	}
	return env
}

func parseExportLine(line string) (string, string, bool) {
	const prefix = "declare -x "
	if !strings.HasPrefix(line, prefix) {
		return "", "", false
	}
	rest := strings.TrimSpace(strings.TrimPrefix(line, prefix))
	if rest == "" {
		return "", "", false
	}
	name, value := rest, ""
	if eq := strings.Index(rest, "="); eq >= 0 {
		name = rest[:eq]
		raw := rest[eq+1:]
		if unquoted, err := strconv.Unquote(raw); err == nil {
			value = unquoted
		} else {
			value = strings.Trim(raw, `"`)
		}
	}
	if !isValidEnvKey(name) {
		return "", "", false
	}
	return name, value, true
}

func shellEscape(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}

func (s *bashSession) close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	pid := s.currentProcessPid
	s.currentProcessPid = 0
	s.started = false
	s.env = nil
	s.cwd = ""

	if pid != 0 {
		if err := syscall.Kill(-pid, syscall.SIGKILL); err != nil {
			log.Warning("kill session process group %d: %v (process may have already exited)", pid, err)
		}
	}
	return nil
}

func uuidString() string {
	return uuid.New().String()
}
