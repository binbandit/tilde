#!/bin/sh
# Only emit CLI responses. Never execute the supplied agent command.
printf '%s\n' "$*" >> "$HERDR_TEST_LOG"
case "$1 $2" in
    "status server") printf '{"running":true}\n' ;;
    "agent focus")
        if [ "$HERDR_TEST_FOCUS" = existing ] || { [ "$HERDR_TEST_FOCUS" = started ] && [ -f "$HERDR_TEST_STARTED" ]; }; then
            printf '{"result":{"agent":{"name":"j-scratch"}}}\n'
        else
            printf '{"error":{"code":"agent_not_running"}}\n' >&2
            exit 1
        fi
        ;;
    "workspace create") printf '{"result":{"root_pane":{"pane_id":"w1:p1"}}}\n' ;;
    "agent start")
        : > "$HERDR_TEST_STARTED"
        if [ "$HERDR_TEST_START_STATUS" -ne 0 ]; then
            printf '{"error":{"code":"%s","message":"scratch startup rejected"}}\n' "$HERDR_TEST_START_ERROR" >&2
        else
            printf '{"result":{"agent":{"name":"j-scratch"}}}\n'
        fi
        exit "$HERDR_TEST_START_STATUS"
        ;;
    "pane run") exit "$HERDR_TEST_PANE_STATUS" ;;
    *) exit 3 ;;
esac
