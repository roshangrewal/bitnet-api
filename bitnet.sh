#!/bin/bash
# BitNet API management script
# Usage: ./bitnet.sh {start|stop|restart|status|logs}

PIDFILE="/tmp/bitnet.pid"
LOGFILE="/tmp/bitnet.log"
PORT=8100

start() {
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "Already running (pid=$(cat $PIDFILE))"
        return 1
    fi
    export PATH=$HOME/miniconda3/bin:$PATH
    eval "$(conda shell.bash hook)"
    conda activate bitnet-cpp
    cd /data/bitnet-api
    export API_PORT=$PORT
    export THREADS=8
    export MAX_CONCURRENT=1000
    export RATE_LIMIT_RPM=3600
    export API_KEYS="sk-bitnet-G0ewUFUl2w9NAdF5WugLZ-WK-T0gkOzzJrO5oxCAn_w"
    setsid uvicorn server.app:app --host 0.0.0.0 --port $PORT < /dev/null > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2
    if curl -s http://localhost:$PORT/health > /dev/null 2>&1; then
        echo "✅ Started on port $PORT (pid=$(cat $PIDFILE))"
    else
        echo "⚠️  Process started but health check failed. Check: ./bitnet.sh logs"
    fi
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
        echo "✅ Stopped"
    else
        fuser -k $PORT/tcp 2>/dev/null && echo "✅ Stopped (via port)" || echo "Not running"
    fi
}

status() {
    if [ -f "$PIDFILE" ] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        echo "Running (pid=$(cat $PIDFILE))"
        curl -s http://localhost:$PORT/health | python3 -m json.tool
    else
        echo "Not running"
    fi
}

logs() {
    tail -${2:-50} "$LOGFILE"
}

case "$1" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; sleep 1; start ;;
    status)  status ;;
    logs)    logs "$@" ;;
    *)       echo "Usage: ./bitnet.sh {start|stop|restart|status|logs}" ;;
esac
