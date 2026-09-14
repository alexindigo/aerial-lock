/*
 * takeover.h / takeover.cpp — in-process takeover-release for a stuck lock.
 *
 * Same contract as the standalone binary (d26a) but callable in-process:
 * bind ext_session_lock_manager_v1, lock(), then unlock_and_destroy on
 * grant. Zero Qt dependency — wayland-client only.
 */
#pragma once

class Takeover
{
public:
    enum class Outcome { Recovered, Refused, NoSocket, Inconclusive };

    // Block for up to timeoutMs waiting for locked/finished; then act.
    static Outcome run(int timeoutMs);
};
