import { test } from "node:test"
import assert from "node:assert/strict"
import { load } from "./load.mjs"

const Windows = load("Windows.js")

const win = (name, at, extra = {}) => ({ name, lastIpcObject: { at, pid: 42, class: name }, ...extra })

test("accessors prefer the Wayland data, then Hyprland's IPC snapshot", () => {
  const t = win("foot", [0, 0], { wayland: { appId: "footclient", title: "shell" }, workspace: { id: 3 } })
  assert.equal(Windows.appId(t), "footclient")
  assert.equal(Windows.title(t), "shell")
  assert.equal(Windows.pid(t), 42)
  assert.equal(Windows.workspaceId(t), 3)
  assert.equal(Windows.appId(win("steam", null)), "steam")
  assert.equal(Windows.pid(null), -1)
  assert.equal(Windows.workspaceId({}), -1)
})

test("sorts left to right, then top to bottom", () => {
  const list = [win("c", [900, 0]), win("a", [0, 500]), win("b", [0, 0])]
  assert.deepEqual(Windows.sortByPosition(list, false).map((t) => t.name), ["b", "a", "c"])
})

test("a vertical bar sorts top to bottom first", () => {
  const list = [win("c", [900, 0]), win("a", [0, 500]), win("b", [0, 0])]
  assert.deepEqual(Windows.sortByPosition(list, true).map((t) => t.name), ["b", "c", "a"])
})

test("windows without a position go last, in their original order", () => {
  const list = [win("x", null), win("b", [10, 0]), win("y", null), win("a", [0, 0])]
  assert.deepEqual(Windows.sortByPosition(list, false).map((t) => t.name), ["a", "b", "x", "y"])
})

test("addresses compare with or without 0x", () => {
  assert.equal(Windows.sameAddress("0x55a0d76080a0", "55a0d76080a0"), true)
  assert.equal(Windows.sameAddress("0x1", "0x2"), false)
})
