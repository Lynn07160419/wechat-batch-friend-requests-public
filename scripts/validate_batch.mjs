#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

function fail(message, code = 1) {
  process.stderr.write(`${message}\n`);
  process.exit(code);
}

const inputArg = process.argv[2];
if (!inputArg) {
  fail("Usage: node validate_batch.mjs <batch.json>", 1);
}

const inputPath = path.resolve(inputArg);
let payload;
try {
  payload = JSON.parse(fs.readFileSync(inputPath, "utf8"));
} catch (error) {
  fail(`Could not read valid JSON: ${error.message}`, 1);
}

const records = Array.isArray(payload) ? payload : payload?.records;
const config = Array.isArray(payload) ? {} : (payload?.config ?? {});
if (!Array.isArray(records)) {
  fail("Input must be an array or an object containing a records array.", 1);
}

const errors = [];
const warnings = [];
const rowKeys = new Map();
const identifiers = new Map();
const remarks = new Map();

const text = (value) => value == null ? "" : String(value).trim();
function addIssue(target, code, index, record, message, relatedRows = []) {
  target.push({
    code,
    record: index + 1,
    row: Number.isInteger(Number(record?.row)) ? Number(record.row) : null,
    relatedRows,
    message,
  });
}

function addToMap(map, key, index, record) {
  if (!key) return;
  const entry = { index, row: Number(record?.row) || null };
  if (!map.has(key)) map.set(key, []);
  map.get(key).push(entry);
}

function renderRemark(template, record) {
  const values = {
    name: text(record.name),
    department: text(record.department ?? record.dept),
    dept: text(record.dept ?? record.department),
    grade: text(record.grade),
    row: text(record.row),
  };
  return template.replace(/\{(name|department|dept|grade|row)\}/g, (_, key) => values[key]);
}

for (const [index, record] of records.entries()) {
  if (!record || typeof record !== "object" || Array.isArray(record)) {
    addIssue(errors, "INVALID_RECORD", index, record, "Record must be a JSON object.");
    continue;
  }

  const row = Number(record.row);
  const sheet = text(record.sheet) || "<default>";
  const name = text(record.name);
  const wechat = text(record.wechat);
  const phone = text(record.phone);
  const remark = text(record.remark);

  if (!Number.isInteger(row) || row <= 0) {
    addIssue(errors, "INVALID_ROW", index, record, "row must be a positive integer.");
  } else {
    addToMap(rowKeys, `${sheet}\u0000${row}`, index, record);
  }

  if (!name) {
    addIssue(errors, "MISSING_NAME", index, record, "name is required.");
  }
  if (!wechat && !phone) {
    addIssue(errors, "MISSING_IDENTIFIER", index, record, "At least one of wechat or phone is required.");
  }
  if (!remark) {
    addIssue(errors, "MISSING_REMARK", index, record, "remark is required.");
  }

  const recordIds = new Set();
  if (wechat) recordIds.add(`id:${wechat.toLocaleLowerCase("en-US")}`);
  if (phone) {
    const canonicalPhone = phone.replace(/[\s()\-]/g, "");
    recordIds.add(`phone:${canonicalPhone}`);
    if (!/^\+?\d{6,20}$/.test(canonicalPhone)) {
      addIssue(warnings, "PHONE_FORMAT", index, record, "phone contains an unusual format; verify it as text in the source.");
    }
  }
  for (const id of recordIds) addToMap(identifiers, id, index, record);
  if (remark) addToMap(remarks, remark, index, record);

  const template = text(config.remarkTemplate);
  if (template) {
    const expected = renderRemark(template, record);
    if (remark !== expected) {
      addIssue(errors, "REMARK_MISMATCH", index, record, "remark does not match config.remarkTemplate.");
    }
  }

  if (remark.length > 64) {
    addIssue(warnings, "LONG_REMARK", index, record, "remark exceeds 64 characters; verify WeChat does not truncate it.");
  }
}

for (const [key, entries] of rowKeys.entries()) {
  if (entries.length < 2) continue;
  const rows = entries.map((entry) => entry.row).filter(Boolean);
  for (const entry of entries) {
    addIssue(errors, "DUPLICATE_ROW", entry.index, records[entry.index], "The same sheet and row appears more than once.", rows);
  }
}

for (const entries of identifiers.values()) {
  const uniqueRecords = [...new Map(entries.map((entry) => [entry.index, entry])).values()];
  if (uniqueRecords.length < 2) continue;
  const rows = uniqueRecords.map((entry) => entry.row).filter(Boolean);
  for (const entry of uniqueRecords) {
    addIssue(errors, "DUPLICATE_IDENTIFIER", entry.index, records[entry.index], "An identifier is shared by multiple records.", rows);
  }
}

for (const entries of remarks.values()) {
  const uniqueRecords = [...new Map(entries.map((entry) => [entry.index, entry])).values()];
  if (uniqueRecords.length < 2) continue;
  const rows = uniqueRecords.map((entry) => entry.row).filter(Boolean);
  for (const entry of uniqueRecords) {
    addIssue(errors, "DUPLICATE_REMARK", entry.index, records[entry.index], "A remark is shared by multiple records.", rows);
  }
}

const result = {
  ok: errors.length === 0,
  input: path.basename(inputPath),
  recordCount: records.length,
  errorCount: errors.length,
  warningCount: warnings.length,
  errors,
  warnings,
};

process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
process.exit(errors.length === 0 ? 0 : 2);
