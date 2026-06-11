#!/usr/bin/env node
'use strict'

const { spawnSync } = require('child_process')

const PLATFORMS = {
  'linux-x64': ['@ubermanu/jsv-linux-x64', 'bin/jsv'],
  'linux-arm64': ['@ubermanu/jsv-linux-arm64', 'bin/jsv'],
  'darwin-x64': ['@ubermanu/jsv-darwin-x64', 'bin/jsv'],
  'darwin-arm64': ['@ubermanu/jsv-darwin-arm64', 'bin/jsv'],
  'win32-x64': ['@ubermanu/jsv-win32-x64', 'bin/jsv.exe'],
}

const key = `${process.platform}-${process.arch}`
const entry = PLATFORMS[key]

if (!entry) {
  process.stderr.write(`jsv: unsupported platform: ${key}\n`)
  process.exit(1)
}

const [pkg, bin] = entry
let binary

try {
  binary = require.resolve(`${pkg}/${bin}`)
} catch {
  process.stderr.write(`jsv: could not find platform package ${pkg}\n`)
  process.exit(1)
}

const { status } = spawnSync(binary, process.argv.slice(2), { stdio: 'inherit' })
process.exit(status ?? 1)
