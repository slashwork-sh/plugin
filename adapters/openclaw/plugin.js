// slashwork OpenClaw plugin entry.
//
// The only file that imports the OpenClaw SDK, so `index.js` (all the routing
// logic) stays unit-testable without an OpenClaw install. OpenClaw loads this
// through `openclaw.extensions` in package.json.

import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

import { register } from "./index.js";

export default definePluginEntry({
  id: "slashwork",
  name: "slashwork",
  description:
    "Route self-contained sessions_spawn spawns to the slashwork offload network, and earn credits running other users' tasks.",
  register,
});
