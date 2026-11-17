package com.example.demo.service;

import com.example.demo.config.AuthorityProperties;
import com.example.demo.persistence.entity.CredentialEntity;
import com.example.demo.persistence.entity.CredentialRoleEmbeddable;
import com.example.demo.persistence.repository.CredentialRepository;
import com.example.demo.security.JwtService;
import com.example.demo.security.TokenDenylist;
import com.example.demo.service.exception.AuthenticationFailedException;
import io.jsonwebtoken.Claims;
import java.time.Clock;
import java.util.List;
import java.util.Objects;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Login (password check, attempt counting, token issue) and logout (token revocation). */
@Slf4j
@Service
@RequiredArgsConstructor
public class AuthService {

    /** Same message for unknown user and wrong password, so usernames can't be probed. */
    static final String INVALID_CREDENTIALS = "Invalid username or password";

    private final CredentialRepository repository;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;
    private final TokenDenylist denylist;
    private final AuthorityProperties properties;
    private final Clock clock;

    /**
     * Checks the password and returns a signed JWT.
     *
     * <p>A wrong password increments {@code attempts} and locks the account once
     * {@code authority.login.max-attempts} is reached. A successful login resets
     * {@code attempts} and increments {@code nb_connection}.
     *
     * <p>{@code noRollbackFor} keeps the attempt counter update when login fails.
     *
     * @throws AuthenticationFailedException if the login is refused
     */
    @Transactional(noRollbackFor = AuthenticationFailedException.class)
    public String login(String username, String password, String clientIp) {
        CredentialEntity user = repository.findByUsername(username).orElse(null);
        if (user == null) {
            // Hash anyway so an unknown user takes as long as a wrong password
            passwordEncoder.encode(password);
            log.info("Login refused for unknown user '{}' from {}", username, clientIp);
            throw new AuthenticationFailedException(INVALID_CREDENTIALS);
        }

        if (!passwordEncoder.matches(password, user.getPassword())) {
            int attempts = Objects.requireNonNullElse(user.getAttempts(), 0) + 1;
            user.setAttempts(attempts);
            if (attempts >= properties.getLogin().getMaxAttempts()) {
                user.setLocked(true);
            }
            log.info("Wrong password for '{}' from {} (attempt {})", username, clientIp, attempts);
            throw new AuthenticationFailedException(INVALID_CREDENTIALS);
        }

        if (Boolean.TRUE.equals(user.getLocked())) {
            log.info("Login refused for locked user '{}' from {}", username, clientIp);
            throw new AuthenticationFailedException("Account locked");
        }
        if (user.getExpirationDate() != null && !user.getExpirationDate().toInstant().isAfter(clock.instant())) {
            log.info("Login refused for expired user '{}' from {}", username, clientIp);
            throw new AuthenticationFailedException("Account expired");
        }

        user.setAttempts(0);
        user.setNbConnections(Objects.requireNonNullElse(user.getNbConnections(), 0) + 1);

        List<String> roles = user.getRoles().stream()
                .map(CredentialRoleEmbeddable::getArguments)
                .filter(Objects::nonNull)
                .toList();
        log.info("User '{}' logged in from {}", username, clientIp);
        return jwtService.issue(user.getUuid(), user.getUsername(), roles);
    }

    /** Revokes the token used for the current request until it expires. */
    public void logout(Claims claims) {
        denylist.revoke(claims.getId(), claims.getExpiration().toInstant());
        log.info("User '{}' logged out", claims.get("username"));
    }
}
