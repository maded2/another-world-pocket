#!/bin/sh
cd "$(dirname "$0")"
quartus_map a1probe.qpf -c a1probe 2>&1 | tail -40
