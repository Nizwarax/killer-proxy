#!/bin/bash
# proxy-auto-expire: cron worker (every 10 min). GUARDED - generators only
# restart services when the config actually changed, so live connections are
# never dropped when nothing expired.
/usr/local/bin/proxy-user check >/dev/null 2>&1
/usr/local/bin/generate-proxies.py >/dev/null 2>&1
/usr/local/bin/generate-xray.py >/dev/null 2>&1
exit 0
