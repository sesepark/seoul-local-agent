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


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--model", default="qwen3.6:35b-a3b-nvfp4")
    p.add_argument("--batch", type=int, default=6, help="앱의 정밀=6, 균형=3")
    p.add_argument("--think", action="store_true", help="구조화 출력과 함께 켜면 JSON이 깨진다")
    p.add_argument("--temp", type=float, default=0.1)
    p.add_argument("--num-ctx", type=int, default=16384)
    p.add_argument("--num-predict", type=int, default=2600)
    p.add_argument("--timeout", type=int, default=900)
    p.add_argument("--label", default="")
    p.add_argument("--out", default="")
    args = p.parse_args()

    system = PROMPT.read_text(encoding="utf-8")
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
        "label": args.label or f"{args.model} batch{args.batch}",
        "model": args.model, "batch": args.batch, "think": args.think, "temp": args.temp,
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
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if args.out:
        Path(args.out).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
