#!/usr/bin/env nu
# Generated process-compose files against real stacks; the suite is Python for its
# process and port inspection.
const suite = (path self | path dirname | path join process_compose_test.py)

def main [] {
	with-env {MISE_LOCKED: '0'} { ^mise exec python@3.14.7 -- python3 $suite }
}
