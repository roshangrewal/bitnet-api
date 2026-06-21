#!/bin/bash
# BitNet API management — manages FastAPI router + llama-server backends
# Usage: ./bitnet.sh {start|stop|restart|status|logs}

cd /data/bitnet-api

PIDFILE="/tmp/bitnet.pid"
LOGFILE="/tmp/bitnet.log"
PORT=8100
BACKEND_PORTS=(8101 8102 8103)

start_backends() {
    bash start_servers.sh
}

stop_backends() {
    for port in "${BACKEND_PORTS[@]}"; do
        pidfile="/tmp/llama-server-${port}.pid"
        if [ -f "$pidfile" ]; then
            kill $(cat "$pidfile") 2>/dev/null
            rm -f "$pidfile"
        fi
    done
    pkill -f "llama-server.*--port 810[123]" 2>/dev/null
    echo "✅ Backends stopped"
}

start_api() {
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "API already running (pid=$(cat $PIDFILE))"
        return 1
    fi
    export PATH=$HOME/miniconda3/bin:$PATH
    eval "$(conda shell.bash hook)"
    conda activate bitnet-cpp
    export API_PORT=$PORT
    export THREADS=8
    export MAX_CONCURRENT=1000
    export RATE_LIMIT_RPM=3600
    export REQUEST_TIMEOUT=300
    export API_KEYS="sk-bitnet-G0ewUFUl2w9NAdF5WugLZ-WK-T0gkOzzJrO5oxCAn_w"
    setsid uvicorn server.app:app --host 0.0.0.0 --port $PORT < /dev/null > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if curl -s http://localhost:$PORT/health > /dev/null 2>&1; then
        echo "✅ API started on port $PORT (pid=$(cat $PIDFILE))"
    else
        echo "⚠️  API process started but health check failed. Check: ./bitnet.sh logs"
    fi
}

stop_api() {
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
        echo "✅ API stopped"
    else
        fuser -k $PORT/tcp 2>/dev/null && echo "✅ API stopped (via port)" || echo "API not running"
    fi
}

start() {
    echo "--- Starting backends ---"
    start_backends
    echo
    echo "--- Starting API ---"
    start_api
}

stop() {
    stop_api
    stop_backends
}

status() {
    echo "=== API (port $PORT) ==="
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "Running (pid=$(cat $PIDFILE))"
        curl -s http://localhost:$PORT/health | python3 -m json.tool 2>/dev/null
    else
        echo "Not running"
    fi
    echo
    echo "=== Backends ==="
    for port in "${BACKEND_PORTS[@]}"; do
        pidfile="/tmp/llama-server-${port}.pid"
        if [ -f "$pidfile" ] && kill -0 $(cat "$pidfile") 2>/dev/null; then
            echo "Port $port: Running (pid=$(cat $pidfile))"
        else
            echo "Port $port: Not running"
        fi
    done
}

logs() {
    tail -${2:-50} "$LOGFILE"
}

logs_backend() {
    port=${2:-8101}
    tail -${3:-50} "/tmp/llama-server-${port}.log"
}

case "$1" in
    start)          start ;;
    stop)           stop ;;
    restart)        stop; sleep 2; start ;;
    status)         status ;;
    logs)           logs "$@" ;;
    logs-backend)   logs_backend "$@" ;;
    start-backends) start_backends ;;
    stop-backends)  stop_backends ;;
    *)              echo "Usage: ./bitnet.sh {start|stop|restart|status|logs|logs-backend [port]|start-backends|stop-backends}" ;;
esac
