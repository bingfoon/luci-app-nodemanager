-- nodemanager/const.lua — Shared constants
-- SPDX-License-Identifier: Apache-2.0

local M = {}

M.NM_PROVIDER_NAME = "nm-nodes"
M.NM_GROUP_NAME    = "\240\159\143\160 住宅节点"
M.NM_PROVIDER_FILE = "nm_proxies.yaml"
M.NM_PREFIX        = "[NM] "

M.DNS_KEYS = {
	"proxy-server-nameserver",
	"default-nameserver",
	"direct-nameserver",
	"nameserver",
}

M.SAFE_PREFIXES = {"/etc/nikki/", "/tmp/", "/usr/share/nodemanager/"}

M.DEVICE_POLICY_PATH = "/usr/share/nodemanager/device_policy.json"

return M
