package com.example.demo.config;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import java.time.Duration;
import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/** Settings under {@code authority.*} in application.yml. */
@Data
@Validated
@ConfigurationProperties(prefix = "authority")
public class AuthorityProperties {

    @Valid
    private Jwt jwt = new Jwt();

    @Valid
    private Login login = new Login();

    @Data
    public static class Jwt {
        /** Base64-encoded HMAC key, at least 256 bits (32 bytes) once decoded. */
        @NotBlank
        private String secret;

        /** How long an issued token stays valid. */
        @NotNull
        private Duration expiration = Duration.ofHours(1);

        /** Value of the token's "iss" claim. */
        @NotBlank
        private String issuer = "authority";
    }

    @Data
    public static class Login {
        /** Failed attempts after which the account is locked. */
        @Min(1)
        private int maxAttempts = 5;
    }
}
