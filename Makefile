# TripperDash++ — top-level Makefile
#
# Convenience wrapper around the most common dev tasks. Anything more
# specialised (Xcode signing, IPA build, etc.) lives in the iOS project's
# own scripts.

.PHONY: help fake-dash-build fake-dash-up fake-dash-down fake-dash-logs \
        fake-dash-test fake-dash-shell fake-dash-clean \
        fake-dash-btn-left fake-dash-btn-right fake-dash-btn-down fake-dash-btn-click \
        fake-dash-sniff fake-dash-snap-mark fake-dash-snap-diff fake-dash-snap-dump

FAKE_DASH_DIR := tools/fake_dash
COMPOSE := docker compose -f $(FAKE_DASH_DIR)/docker-compose.yml

help:  ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

## ─── fake_dash (Tripper TFT emulator) ───────────────────────────────

fake-dash-build:  ## Build the fake_dash Docker image
	$(COMPOSE) build

fake-dash-up:  ## Start fake_dash in the background
	$(COMPOSE) up -d
	@echo ""
	@echo "fake_dash is up:"
	@echo "  - K1G  control plane: udp://0.0.0.0:2000"
	@echo "  - RTP  H.264 sink:    udp://0.0.0.0:5000"
	@echo "  - Captures:           $(FAKE_DASH_DIR)/captures/"
	@echo "  - Logs:               make fake-dash-logs"

fake-dash-down:  ## Stop fake_dash
	$(COMPOSE) down --remove-orphans

fake-dash-logs:  ## Tail fake_dash container logs
	$(COMPOSE) logs -f --tail=100

fake-dash-test:  ## Run the fake_dash pytest suite (in container)
	$(COMPOSE) run --rm fake_dash pytest -q

fake-dash-shell:  ## Drop into a shell in the running container
	$(COMPOSE) exec fake_dash /bin/bash

fake-dash-clean:  ## Remove captures and persistent RSA keys (DESTRUCTIVE)
	rm -rf $(FAKE_DASH_DIR)/captures/* $(FAKE_DASH_DIR)/keys/*

fake-dash-btn-left:   ## Send joystick LEFT to all known phone peers
	$(COMPOSE) exec fake_dash python -m fake_dash button left
fake-dash-btn-right:  ## Send joystick RIGHT
	$(COMPOSE) exec fake_dash python -m fake_dash button right
fake-dash-btn-down:   ## Send joystick DOWN
	$(COMPOSE) exec fake_dash python -m fake_dash button down
fake-dash-btn-click:  ## Send joystick CLICK (select / confirm)
	$(COMPOSE) exec fake_dash python -m fake_dash button click

## ─── nav-info TLV sniffer (capture OEM-app setting bytes) ────────────

fake-dash-sniff:  ## Start fake_dash with the nav-info TLV sniffer enabled
	FAKE_DASH_SNIFF=1 $(COMPOSE) up -d
	@echo ""
	@echo "fake_dash is up WITH --sniff:"
	@echo "  - Point the ORIGINAL Royal Enfield app at this bike, start nav."
	@echo "  - Baseline the wire state:   make fake-dash-snap-mark"
	@echo "  - Flip a setting in the app (12/24h, bubble bottom row)…"
	@echo "  - See what byte changed:     make fake-dash-snap-diff"
	@echo "  - List all nav fields:       make fake-dash-snap-dump"
	@echo "  - Live field log:            make fake-dash-logs"

fake-dash-snap-mark:  ## Sniffer: snapshot current nav-info wire state as baseline
	$(COMPOSE) exec fake_dash python -m fake_dash snap mark
fake-dash-snap-diff:  ## Sniffer: show what changed since the baseline (the toggle's byte)
	$(COMPOSE) exec fake_dash python -m fake_dash snap diff
fake-dash-snap-dump:  ## Sniffer: list every nav-info field currently seen
	$(COMPOSE) exec fake_dash python -m fake_dash snap dump
