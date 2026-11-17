package com.example.demo.security;

import com.example.demo.config.AuthorityProperties;
import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.SignatureAlgorithm;
import io.jsonwebtoken.io.Decoders;
import io.jsonwebtoken.security.Keys;
import java.security.Key;
import java.time.Clock;
import java.time.Instant;
import java.util.Date;
import java.util.List;
import java.util.UUID;
import org.springframework.stereotype.Service;

/** Issues and verifies the HS256 JWTs returned by the login endpoint. */
@Service
public class JwtService {

    static final String ROLES_CLAIM = "roles";

    private final Key key;
    private final AuthorityProperties.Jwt settings;
    private final Clock clock;

    public JwtService(AuthorityProperties properties, Clock clock) {
        this.settings = properties.getJwt();
        this.clock = clock;
        byte[] secret = Decoders.BASE64.decode(settings.getSecret());
        if (secret.length < 32) {
            throw new IllegalStateException("authority.jwt.secret must decode to at least 32 bytes (256 bits)");
        }
        this.key = Keys.hmacShaKeyFor(secret);
    }

    public String issue(String subjectUuid, String username, List<String> roles) {
        Instant now = clock.instant();
        return Jwts.builder()
                .setId(UUID.randomUUID().toString())
                .setIssuer(settings.getIssuer())
                .setSubject(subjectUuid)
                .claim("username", username)
                .claim(ROLES_CLAIM, roles)
                .setIssuedAt(Date.from(now))
                .setExpiration(Date.from(now.plus(settings.getExpiration())))
                .signWith(key, SignatureAlgorithm.HS256)
                .compact();
    }

    /**
     * Verifies signature, issuer and expiry.
     *
     * @throws JwtException if the token is invalid or expired
     */
    public Claims parse(String token) {
        return Jwts.parserBuilder()
                .setSigningKey(key)
                .requireIssuer(settings.getIssuer())
                .setClock(() -> Date.from(clock.instant()))
                .build()
                .parseClaimsJws(token)
                .getBody();
    }
}
