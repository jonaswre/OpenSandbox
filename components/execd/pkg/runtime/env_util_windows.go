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

package runtime

import "strings"

// isValidEnvKey checks that key is a valid Windows environment variable name.
// Windows env var names are permissive: any non-empty string that does not
// contain '=' is valid (e.g. "ProgramFiles(x86)", "CommonProgramFiles(x86)").
func isValidEnvKey(key string) bool {
	return key != "" && !strings.Contains(key, "=")
}
