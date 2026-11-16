#!/bin/sh
# The dev daemon's SHELL under `make run SHELL_GATE=1` (#380). It holds each new
# shell, before its first byte of output, while the gate file exists, so a QA
# runner can act before a shell's first output (spec 2611.0015 S28). The cap
# lets the shell go if a runner dies with the gate up.
i=0
while [ -n "$TARMAC_QA_SHELL_GATE" ] && [ -e "$TARMAC_QA_SHELL_GATE" ] && [ "$i" -lt 600 ]; do
	sleep 0.05
	i=$((i + 1))
done
exec "${TARMAC_QA_SHELL:-/bin/zsh}" "$@"
