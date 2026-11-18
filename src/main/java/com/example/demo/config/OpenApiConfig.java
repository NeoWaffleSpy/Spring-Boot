package com.example.demo.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.security.SecurityScheme;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/**
 * Base document for springdoc. The generated interfaces mark protected operations with
 * {@code @SecurityRequirement(name = "bearerAuth")}, but the generator doesn't declare the scheme
 * itself, so it is declared here. This is what makes Swagger UI show the "Authorize" button and locks.
 */
@Configuration
public class OpenApiConfig {

    /** Must match the name used under components.securitySchemes in api.yaml. */
    public static final String BEARER_SCHEME = "bearerAuth";

    @Bean
    OpenAPI authorityOpenApi() {
        return new OpenAPI()
                .info(new Info()
                        .title("Authority Component API")
                        .description("API for user authentication and management")
                        .version("1.0.0"))
                .components(new Components()
                        .addSecuritySchemes(BEARER_SCHEME, new SecurityScheme()
                                .type(SecurityScheme.Type.HTTP)
                                .scheme("bearer")
                                .bearerFormat("JWT")
                                .description("Token returned in \"data\" by POST /sessions")));
    }
}
