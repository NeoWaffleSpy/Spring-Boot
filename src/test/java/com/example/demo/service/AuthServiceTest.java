package com.example.demo.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.when;

import com.example.demo.config.AuthorityProperties;
import com.example.demo.persistence.entity.CredentialEntity;
import com.example.demo.persistence.entity.CredentialRoleEmbeddable;
import com.example.demo.persistence.repository.CredentialRepository;
import com.example.demo.security.JBCryptPasswordEncoder;
import com.example.demo.security.JwtService;
import com.example.demo.security.TokenDenylist;
import com.example.demo.service.exception.AuthenticationFailedException;
import io.jsonwebtoken.Claims;
import java.time.Clock;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.Base64;
import java.util.List;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class AuthServiceTest {

    private static final Instant NOW = Instant.parse("2026-01-01T10:00:00Z");

    @Mock
    private CredentialRepository repository;

    private final JBCryptPasswordEncoder encoder = new JBCryptPasswordEncoder(4);
    private final Clock clock = Clock.fixed(NOW, ZoneOffset.UTC);
    private JwtService jwtService;
    private TokenDenylist denylist;
    private AuthService authService;
    private AuthorityProperties properties;

    @BeforeEach
    void setUp() {
        properties = new AuthorityProperties();
        properties.getJwt().setSecret(Base64.getEncoder().encodeToString(new byte[32]));
        properties.getLogin().setMaxAttempts(3);
        jwtService = new JwtService(properties, clock);
        denylist = new TokenDenylist(clock);
        authService = new AuthService(repository, encoder, jwtService, denylist, properties, clock);
    }

    private CredentialEntity user(String password) {
        CredentialEntity user = new CredentialEntity();
        user.setUuid("uuid-1");
        user.setUsername("john.doe");
        user.setPassword(encoder.encode(password));
        user.setAttempts(0);
        user.setLocked(false);
        user.setNbConnections(4);
        user.setRoles(List.of(new CredentialRoleEmbeddable("ADMINISTRATOR")));
        return user;
    }

    @Test
    void loginReturnsTokenAndUpdatesCounters() {
        CredentialEntity user = user("secret");
        user.setAttempts(2);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        String token = authService.login("john.doe", "secret", "10.0.0.1");

        Claims claims = jwtService.parse(token);
        assertThat(claims.getSubject()).isEqualTo("uuid-1");
        assertThat(claims.get("roles", List.class)).containsExactly("ADMINISTRATOR");
        assertThat(user.getAttempts()).isZero();
        assertThat(user.getNbConnections()).isEqualTo(5);
    }

    @Test
    void wrongPasswordCountsAttemptAndLocksAtMax() {
        CredentialEntity user = user("secret");
        user.setAttempts(1);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login("john.doe", "wrong", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage(AuthService.INVALID_CREDENTIALS);
        assertThat(user.getAttempts()).isEqualTo(2);
        assertThat(user.getLocked()).isFalse();

        assertThatThrownBy(() -> authService.login("john.doe", "wrong", "ip"))
                .isInstanceOf(AuthenticationFailedException.class);
        assertThat(user.getAttempts()).isEqualTo(3);
        assertThat(user.getLocked()).isTrue();
    }

    @Test
    void unknownUserGetsSameMessageAsWrongPassword() {
        when(repository.findByUsername("nobody")).thenReturn(Optional.empty());

        assertThatThrownBy(() -> authService.login("nobody", "x", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage(AuthService.INVALID_CREDENTIALS);
    }

    @Test
    void lockedAccountIsRefusedEvenWithRightPassword() {
        CredentialEntity user = user("secret");
        user.setLocked(true);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login("john.doe", "secret", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage("Account locked");
        assertThat(user.getNbConnections()).isEqualTo(4);
    }

    @Test
    void expiredAccountIsRefused() {
        CredentialEntity user = user("secret");
        user.setExpirationDate(OffsetDateTime.ofInstant(NOW.minusSeconds(1), ZoneOffset.UTC));
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login("john.doe", "secret", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage("Account expired");
    }

    @Test
    void nullPasswordLogsInWithEmptyPasswordWhenAllowed() {
        properties.getLogin().setAllowEmptyPassword(true);
        CredentialEntity user = user("unused");
        user.setPassword(null);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        String token = authService.login("john.doe", "", "ip");

        assertThat(jwtService.parse(token).getSubject()).isEqualTo("uuid-1");
    }

    @Test
    void nullPasswordStillRejectsNonEmptyPasswordWhenAllowed() {
        properties.getLogin().setAllowEmptyPassword(true);
        CredentialEntity user = user("unused");
        user.setPassword(null);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login("john.doe", "anything", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage(AuthService.INVALID_CREDENTIALS);
    }

    @Test
    void nullPasswordIsRefusedWhenEmptyPasswordsAreNotAllowed() {
        CredentialEntity user = user("unused");
        user.setPassword(null);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user));

        assertThatThrownBy(() -> authService.login("john.doe", "", "ip"))
                .isInstanceOf(AuthenticationFailedException.class)
                .hasMessage(AuthService.INVALID_CREDENTIALS);
        assertThat(user.getAttempts()).isEqualTo(1);
    }

    @Test
    void emptyPasswordDoesNotMatchARealPasswordEvenWhenAllowed() {
        properties.getLogin().setAllowEmptyPassword(true);
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user("secret")));

        assertThatThrownBy(() -> authService.login("john.doe", "", "ip"))
                .isInstanceOf(AuthenticationFailedException.class);
    }

    @Test
    void logoutRevokesTheToken() {
        when(repository.findByUsername("john.doe")).thenReturn(Optional.of(user("secret")));
        Claims claims = jwtService.parse(authService.login("john.doe", "secret", "ip"));

        authService.logout(claims);

        assertThat(denylist.isRevoked(claims.getId())).isTrue();
    }
}
