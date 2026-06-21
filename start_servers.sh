#!/bin/bash
cd /data/bitnet-api

MODELS=(
  "Falcon3-3B-Instruct-1.58bit:8101:4"
  "Falcon3-7B-Instruct-1.58bit:8102:4"
  "Falcon3-10B-Instruct-1.58bit:8103:4"
)

for entry in "${MODELS[@]}"; do
  IFS=":" read -r MODEL PORT THREADS <<< "$entry"
  PIDFILE="/tmp/llama-server-${PORT}.pid"

  if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
    echo "[$MODEL] already running on port $PORT"
    continue
  fi

  echo -n "[$MODEL] starting on port $PORT (threads=$THREADS, ctx=4096)..."
  setsid build/bin/llama-server \
    -m "models/${MODEL}/ggml-model-i2_s.gguf" \
    -c 4096 -t $THREADS -n 4096 -ngl 0 \
    --host 127.0.0.1 --port $PORT -cb -b 1 \
    </dev/null > "/tmp/llama-server-${PORT}.log" 2>&1 &
  echo $! > "$PIDFILE"
  echo " pid=$!"
done

echo "Waiting for models to load..."
for entry in "${MODELS[@]}"; do
  IFS=":" read -r MODEL PORT THREADS <<< "$entry"
  for i in $(seq 1 24); do
    if curl -s --max-time 5 "http://127.0.0.1:${PORT}/health" | grep -q ok; then
      echo "[$MODEL] ✅ ready on port $PORT"
      break
    fi
    [ $i -eq 24 ] && echo "[$MODEL] ⚠️  not ready on port $PORT"
    sleep 5
  done
done
