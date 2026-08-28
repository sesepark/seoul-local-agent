#!/bin/zsh
set -eu

MODEL_FILE=/private/tmp/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M.gguf
MODEL_URL='https://huggingface.co/DavidAU/Qwen3.6-27B-Fable-Fusion-711-Uncensored-Heretic-NM-DAU-NEO-MAX-MTP-GGUF/resolve/main/Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-Q4_K_M.gguf?download=true'
MODEL_NAME=qwen36-fable-27b-mtp-q4
MODEFILE=/Users/sehwan/Projects/local_llm/Modelfile.qwen36-fable-27b-mtp-q4
LOG_DIR=/private/tmp/qwen36-mtp-setup
mkdir -p "$LOG_DIR"

# Resume after transient network failures or sleep/wake cycles.
until /usr/bin/curl -L --fail --continue-at - --output "$MODEL_FILE" "$MODEL_URL"; do
  /bin/sleep 15
done

/usr/local/bin/ollama create "$MODEL_NAME" -f "$MODEFILE" >"$LOG_DIR/create.log" 2>&1
/usr/local/bin/ollama show "$MODEL_NAME" --modelfile >"$LOG_DIR/model-info.log" 2>&1
/usr/local/bin/ollama run "$MODEL_NAME" 'Reply with exactly: LOCAL_LLM_OK' >"$LOG_DIR/short-test.log" 2>&1
/usr/local/bin/ollama run "$MODEL_NAME" 'Write a concise Python function that returns whether a string is a palindrome, ignoring case and non-alphanumeric characters.' >"$LOG_DIR/coding-test.log" 2>&1
/usr/local/bin/ollama ps >"$LOG_DIR/loaded-ps.log" 2>&1
/bin/ps -ax -o pid,ppid,%cpu,%mem,rss,command >"$LOG_DIR/loaded-processes.log" 2>&1
/usr/bin/memory_pressure >"$LOG_DIR/loaded-memory-pressure.log" 2>&1
/usr/bin/vm_stat >"$LOG_DIR/loaded-vm-stat.log" 2>&1

# Ollama's unmodified default keep-alive is five minutes. Allow a margin, then verify unload.
/bin/sleep 315
/usr/local/bin/ollama ps >"$LOG_DIR/unloaded-ps.log" 2>&1
/bin/ps -ax -o pid,ppid,%cpu,%mem,rss,command >"$LOG_DIR/unloaded-processes.log" 2>&1
/usr/bin/memory_pressure >"$LOG_DIR/unloaded-memory-pressure.log" 2>&1

# This is a one-shot setup job, not a persistent launchd configuration.
/bin/launchctl remove com.sehwan.qwen36-mtp-setup || true
