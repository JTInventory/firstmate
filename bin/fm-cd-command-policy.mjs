#!/usr/bin/env node
// Semantic policy for the primary-shell persistent-cd seatbelt.
//
// This file classifies command text only. It never evaluates, expands, sources,
// or runs the submitted command. The shell transport owns primary-checkout
// scoping and output shaping; this file owns the deny/allow decision.
import path from "node:path";
import { realpathSync } from "node:fs";

const REASON = "a persistent top-level directory change in the primary firstmate checkout is blocked; it would move the shell out of the home so a later firstmate-owned command runs inside a project clone. Reach the target without moving the shell - use git -C <dir> or an absolute path on the command itself - or scope the cd to a subshell like (cd <dir> && ...)";

function argument(name, args) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] || "" : "";
}

function normalize(value) {
  try {
    return realpathSync(value);
  } catch {
    return path.resolve(value);
  }
}

function splitTopLevel(source) {
  const segments = [];
  let start = 0;
  let depth = 0;
  let quote = "";
  let escaped = false;
  const push = (end) => {
    const text = source.slice(start, end).trim();
    if (text) segments.push({ depth, text });
    start = end;
  };

  for (let index = 0; index < source.length; index += 1) {
    const char = source[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (char === "'") quote = "";
      continue;
    }
    if (quote === '"') {
      if (char === "\\") escaped = true;
      else if (char === '"') quote = "";
      continue;
    }
    if (char === "'") {
      quote = char;
      continue;
    }
    if (char === '"') {
      quote = char;
      continue;
    }
    if (char === "(") {
      depth += 1;
      continue;
    }
    if (char === ")") {
      depth = Math.max(0, depth - 1);
      continue;
    }
    if (depth === 0 && (char === ";" || char === "\n")) {
      push(index);
      start = index + 1;
      continue;
    }
    if (depth === 0 && (char === "|" || char === "&")) {
      push(index);
      if (source[index + 1] === char) index += 1;
      start = index + 1;
    }
  }
  push(source.length);
  return segments;
}

function words(source) {
  const result = [];
  let word = "";
  let quote = "";
  let escaped = false;
  const push = () => {
    if (word) result.push(word);
    word = "";
  };
  for (const char of source) {
    if (escaped) {
      word += char;
      escaped = false;
      continue;
    }
    if (quote === "'") {
      if (char === "'") quote = "";
      else word += char;
      continue;
    }
    if (quote === '"') {
      if (char === '"') quote = "";
      else if (char === "\\") escaped = true;
      else word += char;
      continue;
    }
    if (char === "'") quote = char;
    else if (char === '"') quote = char;
    else if (/\s/.test(char)) push();
    else word += char;
  }
  push();
  return result;
}

function isInside(root, candidate) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function hasDynamicExpansion(target) {
  return target.startsWith("~") || [...target].some((char) => "$`*?[]{}".includes(char));
}

function denies(command, home) {
  const projects = normalize(path.join(home, "projects"));
  for (const segment of splitTopLevel(command)) {
    if (segment.depth !== 0) continue;
    const tokens = words(segment.text);
    let index = 0;
    while (tokens[index] && /^(env|builtin|command)$/.test(tokens[index])) index += 1;
    if (!tokens[index] || !/^(cd|pushd)$/.test(tokens[index])) continue;
    let targetIndex = index + 1;
    while (tokens[targetIndex] === "-L" || tokens[targetIndex] === "-P" || tokens[targetIndex] === "--") targetIndex += 1;
    const target = tokens[targetIndex];
    if (!target) continue;
    if (hasDynamicExpansion(target)) return true;
    if (isInside(projects, normalize(path.resolve(home, target)))) return true;
  }
  return false;
}

const args = process.argv.slice(2);
const home = argument("--home", args);
const command = argument("--command", args);
if (!home || !command) {
  process.stdout.write(JSON.stringify({ decision: "allow" }) + "\n");
} else if (denies(command, home)) {
  process.stdout.write(JSON.stringify({ decision: "deny", reason: REASON }) + "\n");
} else {
  process.stdout.write(JSON.stringify({ decision: "allow" }) + "\n");
}
