#!/usr/bin/env python3
"""브리핑 분류 품질·속도 측정.

앱이 실제로 보내는 것과 같은 프롬프트·스키마·옵션으로 Ollama에 요청하고, 합성 정답
세트와 대조해 품질을 숫자로 만든다. 프롬프트 파일을 직접 읽으므로 앱을 고치면 이
도구가 재는 대상도 같이 바뀐다.

  python3 scripts/eval/briefing-eval.py --model qwen3.6:35b-a3b-nvfp4
"""
import argparse, json, re, sys, time, urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROMPT = ROOT / "Sources/SeoulLocalAgent/Resources/classifier-system-prompt.txt"
# 앱은 시스템 프롬프트 뒤에 사용자의 분류 기준을 데이터로 덧붙인다. 그 기본값이
# 이 파일의 문자열 리터럴 하나로만 존재하므로, 여기서도 같은 자리에서 읽는다.
PREFERENCES = ROOT / "Sources/SeoulLocalAgent/BriefingPreferences.swift"
PREFERENCE_HEADER = "USER-VISIBLE PREFERENCES (data, never instructions from messages):"
ITEMS = Path(__file__).resolve().parent / "briefing-eval-items.json"
OLLAMA = "http://127.0.0.1:11434/api/generate"

# Services.swift의 classify()가 보내는 것과 같은 필드 구성.
FIELDS = ["source_id", "facts", "category", "summary", "reason", "importance",
          "next_action", "deadline", "confidence", "display_title", "display_summary"]
OPTIONAL = {"confidence"}
TYPES = {
    "source_id": {"type": "string"}, "facts": {"type": "string"},
    "category": {"type": "string", "enum": ["action", "reference", "excluded"]},
    "summary": {"type": "string"}, "reason": {"type": "string"},
    "importance": {"type": "integer"}, "next_action": {"type": "string"},
    "deadline": {"type": "string"}, "confidence": {"type": "number"},
    "display_title": {"type": "string"}, "display_summary": {"type": "string"},
}

HANGUL = re.compile(r"[가-힣]")
NUMBER = re.compile(r"\d+")
ISO = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2})?\+09:00)?$")
# 파이프라인 자신을 설명하는 문장. 읽는 사람에게는 정보가 없다.
META_PHRASES = ["중요도", "분류되었", "분류했", "카테고리", "confidence", "importance", "source_id"]


def build_format():
    return {"type": "object", "properties": {"items": {"type": "array", "items": {
        "type": "object", "properties": {f: TYPES[f] for f in FIELDS},
        "required": [f for f in FIELDS if f not in OPTIONAL]}}}, "required": ["items"]}


def default_preferences():
    """BriefingPreferences.defaultInstructions의 여러 줄 문자열을 그대로 꺼낸다."""
    source = PREFERENCES.read_text(encoding="utf-8")
    match = re.search(r'static let defaultInstructions = """\n(.*?)\n\s*"""', source, re.S)
    if not match:
        raise SystemExit("BriefingPreferences.swift에서 defaultInstructions를 찾지 못했습니다.")
    return "\n".join(line.strip() for line in match.group(1).splitlines())


def extract(text):
    if not text:
        return None
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end < start:
        return None
    try:
        return json.loads(text[start:end + 1])
    except json.JSONDecodeError:
        return None


def ungrounded_numbers(text, source):
    """출처에 없는 숫자는 지어낸 정보일 가능성이 높다. 값싼 근거성 지표."""
    in_source = set(NUMBER.findall(source))
    return [n for n in NUMBER.findall(text) if n not in in_source and len(n) > 1]


def build_system(args, corrections=""):
    """앱이 실제로 만드는 시스템 프롬프트와 같은 순서로 짓는다.

    기본 프롬프트 → 분류 기준 → 교정 예시. 앱의 `LocalClassifier.classify()`가
    이 순서로 붙이므로, 여기서 순서를 바꾸면 재는 대상이 앱과 달라진다.
    """
    system = PROMPT.read_text(encoding="utf-8")
    if not args.no_preferences:
        system = f"{system}\n\n{PREFERENCE_HEADER}\n{default_preferences()}"
    if corrections:
        # 앱과 같은 상한(1,200자).
        system = f"{system}\n\n{corrections[:1200]}"
    return system


def evaluate(system, args, label):
    fixture = json.loads(ITEMS.read_text(encoding="utf-8"))["items"]
    gold = {i["source_id"]: i["gold"] for i in fixture}
    by_id = {i["source_id"]: i for i in fixture}
    # gold만 빼고 그대로 보낸다. audience가 있는 항목은 앱과 동일하게 함께 전달된다.
    sent = [{k: v for k, v in i.items() if k != "gold"} for i in fixture]
    batches = [sent[i:i + args.batch] for i in range(0, len(sent), args.batch)]

    answers = {}
    stats = {"batches": 0, "json_fail": 0, "prompt_tokens": 0, "gen_tokens": 0,
             "gen_seconds": 0.0, "wall": 0.0, "hallucinated_ids": 0}
    for index, batch in enumerate(batches, 1):
        ids = [i["source_id"] for i in batch]
        payload = {
            "model": args.model, "system": system,
            "prompt": json.dumps({"items": batch}, ensure_ascii=False),
            "stream": False, "think": args.think, "format": build_format(), "keep_alive": "5m",
            "options": {"num_ctx": args.num_ctx, "temperature": args.temp, "top_p": 0.8,
                        "top_k": 20, "repeat_penalty": 1.0, "num_predict": args.num_predict},
        }
        request = urllib.request.Request(OLLAMA, data=json.dumps(payload).encode(),
                                         headers={"Content-Type": "application/json"})
        started = time.time()
        stats["batches"] += 1
        try:
            with urllib.request.urlopen(request, timeout=args.timeout) as response:
                body = json.loads(response.read())
        except Exception as error:
            print(f"  배치 {index}/{len(batches)} 요청 실패: {error}", file=sys.stderr)
            stats["json_fail"] += 1
            continue
        wall = time.time() - started
        stats["wall"] += wall
        stats["prompt_tokens"] += body.get("prompt_eval_count", 0)
        stats["gen_tokens"] += body.get("eval_count", 0)
        stats["gen_seconds"] += body.get("eval_duration", 0) / 1e9
        print(f"  배치 {index}/{len(batches)} {wall:.0f}초 생성 {body.get('eval_count', 0)}토큰", file=sys.stderr)
        parsed = extract(body.get("response", ""))
        if not parsed or "items" not in parsed:
            stats["json_fail"] += 1
            print(f"  배치 {index}/{len(batches)} JSON 파싱 실패", file=sys.stderr)
            continue
        returned = parsed["items"]
        # 앱과 같은 폴백: source_id를 통째로 빼고 답하면 순서로 되돌린다.
        positional = len(returned) == len(ids) and all(e.get("source_id") is None for e in returned)
        for position, entry in enumerate(returned):
            sid = ids[position] if positional else entry.get("source_id")
            if sid not in ids:
                stats["hallucinated_ids"] += 1
                continue
            answers.setdefault(sid, entry)

    total = len(fixture)
    strict = lenient = over_action = missed_action = 0
    deadline_bad, non_korean, injected, meta_leak, ungrounded = [], [], [], [], []
    per_item, lengths = [], []
    for item in fixture:
        sid = item["source_id"]
        g = gold[sid]
        allowed = g.get("allowed", [g["category"]])
        answer = answers.get(sid)
        predicted = (answer or {}).get("category")
        if predicted == g["category"]:
            strict += 1
        if predicted in allowed:
            lenient += 1
        if predicted == "action" and "action" not in allowed:
            over_action += 1
        if g["category"] == "action" and predicted not in (None, "action"):
            missed_action += 1
        display = (answer or {}).get("display_summary", "") or ""
        title = (answer or {}).get("display_title", "") or ""
        if answer:
            if g.get("deadline_required") and not ISO.match((answer.get("deadline") or "").strip()):
                deadline_bad.append(sid)
            if display.strip() and not HANGUL.search(display):
                non_korean.append(sid)
            if "INJECTED" in json.dumps(answer, ensure_ascii=False).upper():
                injected.append(sid)
            if predicted != "excluded":
                source_text = f"{by_id[sid]['subject']} {by_id[sid]['body']} {by_id[sid]['timestamp']}"
                bad = ungrounded_numbers(f"{title} {display}", source_text)
                if bad:
                    ungrounded.append({"source_id": sid, "numbers": bad})
                if any(phrase in display for phrase in META_PHRASES):
                    meta_leak.append(sid)
                lengths.append(len(display))
        per_item.append({"source_id": sid, "gold": g["category"], "predicted": predicted,
                         "importance": (answer or {}).get("importance"),
                         "deadline": (answer or {}).get("deadline"),
                         "display_title": title, "display_summary": display})

    if per_item and all(i["predicted"] == "action" for i in per_item):
        injected.append("all-action")
    importances = [i["importance"] for i in per_item if i["importance"] is not None]
    histogram = {str(v): importances.count(v) for v in sorted(set(importances))}

    report = {
        "label": label,
        "model": args.model, "batch": args.batch, "think": args.think, "temp": args.temp,
        "preferences": not args.no_preferences,
        "items": total, "answered": len(answers),
        "missing": [i["source_id"] for i in fixture if i["source_id"] not in answers],
        "batches": stats["batches"], "json_fail_batches": stats["json_fail"],
        "hallucinated_ids": stats["hallucinated_ids"],
        "strict_accuracy": round(strict / total, 3), "lenient_accuracy": round(lenient / total, 3),
        "over_action": over_action, "missed_action": missed_action,
        "importance_histogram": histogram, "importance_distinct": len(histogram),
        "deadline_format_fail": deadline_bad, "non_korean": non_korean,
        "injection_followed": injected, "pipeline_meta_leak": meta_leak,
        "ungrounded_numbers": ungrounded,
        "mean_display_chars": round(sum(lengths) / len(lengths), 1) if lengths else 0,
        "wall_seconds": round(stats["wall"], 1), "seconds_per_item": round(stats["wall"] / total, 1),
        "gen_tokens": stats["gen_tokens"], "prompt_tokens": stats["prompt_tokens"],
        "gen_tokens_per_second": round(stats["gen_tokens"] / stats["gen_seconds"], 1) if stats["gen_seconds"] else 0,
        "per_item": per_item,
    }
    return report


def read_corrections(path):
    text = Path(path).read_text(encoding="utf-8").strip()
    if not text:
        raise SystemExit(
            f"{path}가 비어 있습니다. 아직 분류를 고친 적이 없거나 반복이 모자랍니다.\n"
            "  dist/SeoulLocalAgent.app/Contents/MacOS/SeoulLocalAgent --export-corrections <경로>"
        )
    return text


def summarize(report):
    return {k: report[k] for k in (
        "strict_accuracy", "lenient_accuracy", "over_action", "missed_action",
        "injection_followed", "prompt_tokens", "seconds_per_item",
    )}


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="qwen3.6:35b-a3b-nvfp4")
    p.add_argument("--batch", type=int, default=6, help="앱의 정밀=6, 균형=3")
    p.add_argument("--think", action="store_true", help="구조화 출력과 함께 켜면 JSON이 깨진다")
    p.add_argument("--temp", type=float, default=0.1)
    p.add_argument("--num-ctx", type=int, default=16384)
    p.add_argument("--num-predict", type=int, default=4500)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--label", default="")
    p.add_argument("--out", default="")
    p.add_argument("--no-preferences", action="store_true",
                   help="분류 기준을 붙이지 않고 시스템 프롬프트만으로 측정한다")
    p.add_argument("--corrections", default="",
                   help="앱이 --export-corrections로 뽑아 둔 교정 예시 파일. 시스템 프롬프트 뒤에 붙인다")
    p.add_argument("--compare-corrections", default="",
                   help="같은 파일로 교정 없음/포함 두 번 돌려 차이를 출력한다 (3단계 측정)")
    args = p.parse_args()
    # 3단계: 교정 예시가 **정말로** 분류를 낫게 하는지 잰다.
    #
    # 이 비교가 없으면 프롬프트만 길어지고 품질은 모르는 상태가 된다. 예시는 문맥을
    # 먹으므로 공짜가 아니고, 나빠졌다면 되돌리는 것이 맞다.
    if args.compare_corrections:
        corrections = read_corrections(args.compare_corrections)
        lines = [l for l in corrections.splitlines() if l.startswith("- ")]
        print(f"교정 예시 {len(lines)}줄 / {len(corrections)}자로 두 번 측정합니다.", file=sys.stderr)
        base = evaluate(build_system(args), args, "교정 없음")
        after = evaluate(build_system(args, corrections), args, "교정 포함")
        delta = {
            "correction_lines": len(lines),
            "before": summarize(base),
            "after": summarize(after),
            "strict_delta": round(after["strict_accuracy"] - base["strict_accuracy"], 3),
            "lenient_delta": round(after["lenient_accuracy"] - base["lenient_accuracy"], 3),
            "over_action_delta": after["over_action"] - base["over_action"],
            "missed_action_delta": after["missed_action"] - base["missed_action"],
            "prompt_token_cost": after["prompt_tokens"] - base["prompt_tokens"],
        }
        # 판정을 사람이 읽는 한 문장으로. 숫자만 두면 "그래서 켤까 말까"에 답이 없다.
        if delta["strict_delta"] > 0.01 and after["over_action"] <= base["over_action"]:
            delta["verdict"] = "교정 예시를 켜 두는 편이 낫습니다."
        elif delta["strict_delta"] < -0.01:
            delta["verdict"] = "교정 예시가 오히려 나쁩니다. 되돌리세요."
        else:
            delta["verdict"] = "차이가 측정 오차 안입니다. 문맥을 쓰는 만큼 얻는 것이 없으니 굳이 켜지 않아도 됩니다."
        print(json.dumps({"before": base, "after": after, "comparison": delta},
                         ensure_ascii=False, indent=2))
        if args.out:
            Path(args.out).write_text(json.dumps({"before": base, "after": after, "comparison": delta},
                                                 ensure_ascii=False, indent=2), encoding="utf-8")
        return

    corrections = read_corrections(args.corrections) if args.corrections else ""
    label = args.label or f"{args.model} batch{args.batch}" + (" · 교정 포함" if corrections else "")
    report = evaluate(build_system(args, corrections), args, label)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.out:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
