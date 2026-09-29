// Loads a QML JavaScript resource (`.pragma library` file) into a fresh
// context so its top-level functions can be tested under Node.
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

export function load(name) {
  const path = fileURLToPath(new URL(`../${name}`, import.meta.url))
  const source = readFileSync(path, "utf8").replace(/^\.pragma .*$/m, "")
  const context = {}
  vm.runInNewContext(source, context, { filename: path })
  return context
}
