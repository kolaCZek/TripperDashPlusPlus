"""
fake_dash — Royal Enfield Tripper TFT emulator.

Provides a Dockerized test harness that speaks the K1G control plane on
UDP/2002 and accepts RTP H.264 video on UDP/5000 — exactly what the real
Tripper dash does. Used by the TripperDash++ iOS app development workflow
to avoid running tests against a parked motorcycle outside.

Reference: kolaCZek/better-dash (Python phone-side implementation).
This package implements the *bike side* of the same protocol.
"""

__version__ = "0.1.0"
