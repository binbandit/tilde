#!/bin/sh
# Older tilde versions wrote project hooks pointing at Contents/Helpers/tilde-agent-hook.
# Keep those hooks successful after upgrading without reading hook input or touching project/home data.
printf '{}\n'
exit 0
