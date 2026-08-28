#!/usr/bin/env python3
"""Create a local MLX 8-bit Qwen3-ASR model without replacing the source."""

import json
import shutil
from pathlib import Path

import mlx.core as mx
import mlx.utils as mlx_utils
from mlx_qwen3_asr.config import Qwen3ASRConfig
from mlx_qwen3_asr.convert import quantize_model, remap_weights
from mlx_qwen3_asr.load_models import _load_safetensors, _resolve_path
from mlx_qwen3_asr.model import Qwen3ASRModel

SOURCE = "Qwen/Qwen3-ASR-0.6B"
DESTINATION = Path.home() / ".cache" / "seoul-local-agent" / "Qwen3-ASR-0.6B-8bit"


def main() -> None:
    source = _resolve_path(SOURCE)
    raw_config = json.loads((source / "config.json").read_text())
    config = Qwen3ASRConfig.from_dict(raw_config)
    weights = {key: value.astype(mx.float16) for key, value in remap_weights(_load_safetensors(source)).items()}

    model = Qwen3ASRModel(config)
    model.load_weights(list(weights.items()))
    quantize_model(model, bits=8, group_size=64)
    mx.eval(model.parameters())

    DESTINATION.mkdir(parents=True, exist_ok=True)
    mx.save_safetensors(str(DESTINATION / "weights.safetensors"), dict(mlx_utils.tree_flatten(model.parameters())))
    for filename in ("config.json", "tokenizer.json", "tokenizer_config.json", "vocab.json", "merges.txt", "special_tokens_map.json", "preprocessor_config.json"):
        candidate = source / filename
        if candidate.exists():
            shutil.copy2(candidate, DESTINATION / filename)
    (DESTINATION / "quantization_config.json").write_text(json.dumps({"bits": 8, "group_size": 64}, indent=2))
    print(DESTINATION)


if __name__ == "__main__":
    main()
