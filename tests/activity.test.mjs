import { test } from "node:test"
import assert from "node:assert/strict"
import { load } from "./load.mjs"

const Activity = load("Activity.js")
const MB = 1024 * 1024

// Feed samples 1.5s apart at the given disk/net rates (MB/s) and collect
// each step's state and finished flag.
function run(rates, { netRates = [] } = {}) {
  let state
  let bytes = 0
  let net = 0
  const steps = []
  rates.forEach((rate, i) => {
    bytes += rate * MB * 1.5
    net += (netRates[i] || 0) * MB * 1.5
    const step = Activity.stepDisk(state, { bytes, net }, i * 1500)
    state = step.state
    steps.push(step)
  })
  return steps
}

test("spinner titles", () => {
  assert.equal(Activity.isSpinnerTitle("⠋ Building"), true)
  assert.equal(Activity.isSpinnerTitle("◐ BetterBar workspace widget"), true)
  assert.equal(Activity.isSpinnerTitle("✳ Idle agent"), false)
  assert.equal(Activity.isSpinnerTitle("⠀ blank braille"), false)
  assert.equal(Activity.isSpinnerTitle(""), false)
})

test("rate formatting", () => {
  assert.equal(Activity.formatRate(2.5 * MB), "2.5 MB/s")
  assert.equal(Activity.formatRate(51.4 * MB), "51 MB/s")
})

test("busy after three samples over the threshold, not before", () => {
  const steps = run([0, 5, 5, 5])
  assert.deepEqual(steps.map((s) => s.state.busy), [false, false, false, true])
})

test("a short burst never counts", () => {
  const steps = run([0, 5, 5, 0, 0, 0])
  assert.ok(steps.every((s) => !s.state.busy && !s.finished))
})

test("a dip shorter than four samples keeps it busy with the last real rate", () => {
  const steps = run([0, 5, 5, 5, 0, 0, 0, 5])
  assert.ok(steps.slice(3).every((s) => s.state.busy))
  assert.equal(Math.round(steps[5].state.rate / MB), 5)
})

test("idle after four quiet samples; short spells don't raise the dot", () => {
  const steps = run([0, 5, 5, 5, 0, 0, 0, 0])
  assert.equal(steps[7].state.busy, false)
  assert.equal(steps[7].finished, false)
})

test("a long spell ending is reported as finished", () => {
  const steps = run([0, ...Array(12).fill(5), 0, 0, 0, 0])
  assert.equal(steps.at(-1).state.busy, false)
  assert.equal(steps.at(-1).finished, true)
  assert.equal(steps.filter((s) => s.finished).length, 1)
})

test("network traffic during the spell makes it a download, and it sticks", () => {
  const steps = run([0, 5, 5, 5, 5, 5], { netRates: [0, 0, 0, 3, 0, 0] })
  assert.equal(steps[2].state.download, false)
  assert.deepEqual(steps.slice(3).map((s) => s.state.download), [true, true, true])
})

test("disk writes without network stay a plain run", () => {
  const steps = run([0, 5, 5, 5, 5])
  assert.equal(steps.at(-1).state.download, false)
})

test("parses disk-activity.sh output", () => {
  const samples = Activity.parseDiskLines("13963 1000 200\n\n17926 5 0\nbad line\n0 1 1\n")
  assert.deepEqual(Array.from(samples, (s) => ({ ...s })), [
    { pid: 13963, bytes: 1000, net: 200 },
    { pid: 17926, bytes: 5, net: 0 },
  ])
})

test("parses the herdr probe", () => {
  const snapshot = JSON.stringify({ result: { snapshot: { agents: [{ agent_status: "working" }, { agent_status: "done" }] } } })
  const parsed = Activity.parseHerdr("23264,999\n" + snapshot)
  assert.deepEqual([...parsed.pids], [23264, 999])
  assert.deepEqual([...parsed.statuses], ["working", "done"])
  assert.deepEqual([...Activity.parseHerdr("").statuses], [])
  assert.deepEqual([...Activity.parseHerdr("1\nnot json").statuses], [])
})

test("notification app names match window classes", () => {
  const key = Activity.notificationKey("Discord")
  assert.equal(Activity.notificationMatches(key, "chrome-discord.com__channels_@me-Default"), true)
  assert.equal(Activity.notificationMatches(Activity.notificationKey("Google Chrome"), "google-chrome"), true)
  assert.equal(Activity.notificationMatches(key, "steam"), false)
  assert.equal(Activity.notificationKey("notify-send"), "")
  assert.equal(Activity.notificationKey("omarchy-action"), "")
})

test("tooltip notes", () => {
  const base = { working: 0, blocked: 0, done: 0, spinning: 0, writing: 0, downloadRate: 0, unseen: false }
  assert.deepEqual([...Activity.notes({ ...base, downloadRate: 50 * MB })], ["Downloading · 50 MB/s"])
  assert.deepEqual([...Activity.notes({ ...base, writing: 1 })], ["Running"])
  assert.deepEqual([...Activity.notes({ ...base, spinning: 1, working: 2 })], ["2 agents running"])
  assert.deepEqual([...Activity.notes({ ...base, blocked: 1, done: 1, unseen: true })],
    ["1 agent needs input", "1 agent finished", "New activity"])
})
