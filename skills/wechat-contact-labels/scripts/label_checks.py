#!/usr/bin/env python3
"""Offline evidence checks. No GUI, network, or WeChat database access."""

import argparse
import json
from pathlib import Path
import unicodedata


def text(value, field):
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value


def flag(data, field):
    value = data.get(field, False)
    if type(value) is not bool:
        raise ValueError(f"{field} must be a boolean")
    return value


def ids(value, field):
    if not isinstance(value, list):
        raise ValueError(f"{field} must be a list")
    checked = [text(item, field) for item in value]
    if len(set(checked)) != len(checked):
        raise ValueError(f"{field} contains duplicate account keys")
    return set(checked)


def normalized_label(value):
    return "".join(unicodedata.normalize("NFC", text(value, "label")).split())


def match_candidates(data):
    expected = normalized_label(data.get("source_label"))
    readable = flag(data, "results_readable")
    complete = flag(data, "results_complete")
    candidates = data.get("candidates")
    if not isinstance(candidates, list):
        raise ValueError("candidates must be a list")
    seen = set()
    matched = []
    for candidate in candidates:
        if not isinstance(candidate, dict):
            raise ValueError("each candidate must be an object")
        key = text(candidate.get("candidate_id"), "candidate_id")
        if key in seen:
            raise ValueError("candidate_id is duplicated; merge repeated observations first")
        seen.add(key)
        if normalized_label(candidate.get("label")) == expected:
            matched.append(key)
    if not readable or not complete:
        return {"status": "unknown", "reason": "incomplete_or_unreadable_results"}
    if len(matched) > 1:
        return {"status": "ambiguous", "candidate_ids": matched}
    if not matched:
        return {"status": "not_found", "candidate_ids": []}
    return {"status": "unique_match", "candidate_ids": matched}


def audit_members(data):
    baseline = ids(data.get("baseline_member_ids"), "baseline_member_ids")
    selected = ids(data.get("selected_member_ids"), "selected_member_ids")
    observed = ids(data.get("observed_member_ids"), "observed_member_ids")
    count = data.get("observed_count")
    if count is not None and (type(count) is not int or count < 0):
        raise ValueError("observed_count must be a non-negative integer or null")
    baseline_complete = flag(data, "baseline_complete")
    complete = flag(data, "members_complete")
    stable = flag(data, "count_stable")
    if not baseline_complete:
        return {"status": "unknown", "reason": "incomplete_baseline"}
    expected = baseline | selected
    result = {
        "expected_count": len(expected),
        "observed_count": count,
        "expected_new_member_count": len(selected - baseline),
    }
    if count is None:
        return dict(result, status="unknown", reason="unavailable_member_count")
    if not complete or not stable:
        return dict(result, status="unknown", reason="incomplete_or_updating_members")
    missing = sorted(expected - observed)
    unexpected = sorted(observed - expected)
    consistent = len(observed) == count == len(expected)
    return dict(result, status="verified" if consistent and not missing and not unexpected
                else "reconcile", missing_member_ids=missing, unexpected_member_ids=unexpected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["match", "audit"])
    parser.add_argument("input", type=Path, help="Local JSON evidence file")
    args = parser.parse_args()
    try:
        data = json.loads(args.input.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            raise ValueError("input must be an object")
        result = match_candidates(data) if args.command == "match" else audit_members(data)
    except (OSError, ValueError) as exc:
        parser.exit(2, f"Invalid evidence: {exc}\n")
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    main()
