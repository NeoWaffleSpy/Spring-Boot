package com.example.demo.config;

import org.openapitools.jackson.nullable.JsonNullableModule;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class JacksonConfig {

    /** Needed so the generated models' JsonNullable fields serialize as plain values. */
    @Bean
    JsonNullableModule jsonNullableModule() {
        return new JsonNullableModule();
    }
}
