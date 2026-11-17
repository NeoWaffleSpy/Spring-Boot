package com.example.demo.security;

import java.time.Clock;
import java.time.Instant;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.stereotype.Component;

/**
 * Tokens revoked by logout, keyed by their "jti" claim, kept until they would have expired anyway.
 *
 * <p>In memory only: revocations are lost on restart and not shared between instances.
 * Replace with a shared store (database table, Redis) before running more than one instance.
 */
@Component
public class TokenDenylist {

    private final Map<String, Instant> revoked = new ConcurrentHashMap<>();
    private final Clock clock;

    public TokenDenylist(Clock clock) {
        this.clock = clock;
    }

    public void revoke(String tokenId, Instant expiresAt) {
        purgeExpired();
        revoked.put(tokenId, expiresAt);
    }

    public boolean isRevoked(String tokenId) {
        Instant expiresAt = revoked.get(tokenId);
        return expiresAt != null && expiresAt.isAfter(clock.instant());
    }

    private void purgeExpired() {
        Instant now = clock.instant();
        revoked.values().removeIf(expiresAt -> !expiresAt.isAfter(now));
    }
}
