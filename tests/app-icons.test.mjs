import { test } from "node:test"
import assert from "node:assert/strict"
import { load } from "./load.mjs"

const AppIcons = load("AppIcons.js")

const discord = { id: "Discord", icon: "omarchy-discord", execString: "omarchy-launch-webapp https://discord.com/channels/@me" }
const discordOther = { id: "DiscordAlt", icon: "discord-alt", execString: "omarchy-launch-webapp https://discord.com/app" }
const github = { id: "GitHub", icon: "github", command: ["omarchy-launch-webapp", "https://github.com/"] }
const foot = { id: "foot", icon: "foot", execString: "foot" }

test("web app class maps to its URL key", () => {
  assert.deepEqual({ ...AppIcons.webAppKey("chrome-discord.com__channels_@me-Default") },
    { key: "discord.com__channels_@me", host: "discord.com" })
  assert.equal(AppIcons.webAppKey("brave-github.com__-Profile_1").host, "github.com")
  assert.equal(AppIcons.webAppKey("google-chrome"), null)
  assert.equal(AppIcons.webAppKey("foot"), null)
})

test("finds the desktop entry launching the same URL", () => {
  const entries = [foot, discordOther, discord, github]
  assert.equal(AppIcons.findWebAppEntry("chrome-discord.com__channels_@me-Default", entries), discord)
})

test("falls back to an entry on the same host", () => {
  assert.equal(AppIcons.findWebAppEntry("chrome-discord.com__login-Default", [foot, discordOther]), discordOther)
})

test("reads the URL from a command list and a root path", () => {
  assert.equal(AppIcons.findWebAppEntry("chrome-github.com__-Default", [foot, github]), github)
})

test("ignores classes that aren't web apps", () => {
  assert.equal(AppIcons.findWebAppEntry("google-chrome", [discord]), null)
})

test("icon candidates try the entry icon, then app id variants", () => {
  assert.deepEqual([...AppIcons.iconCandidates("org.gnome.Nautilus", "nautilus-icon")],
    ["nautilus-icon", "org.gnome.Nautilus", "org.gnome.nautilus", "nautilus"])
  assert.deepEqual([...AppIcons.iconCandidates("Steam", "")], ["Steam", "steam"])
})
