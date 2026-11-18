package com.example.demo.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.example.demo.api.model.Credential;
import com.example.demo.config.AuthorityProperties;
import com.example.demo.mapper.CredentialMapper;
import com.example.demo.persistence.entity.CredentialEntity;
import com.example.demo.persistence.repository.CredentialRepository;
import com.example.demo.security.JBCryptPasswordEncoder;
import com.example.demo.service.exception.BadRequestException;
import java.util.Optional;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mapstruct.factory.Mappers;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

@ExtendWith(MockitoExtension.class)
class UserServiceTest {

    @Mock
    private CredentialRepository repository;

    private AuthorityProperties properties;
    private UserService userService;

    @BeforeEach
    void setUp() {
        properties = new AuthorityProperties();
        userService = new UserService(repository, Mappers.getMapper(CredentialMapper.class),
                new JBCryptPasswordEncoder(4), properties);
    }

    private CredentialEntity createAndCaptureSaved(String password) {
        when(repository.existsByUsername("jane")).thenReturn(false);
        when(repository.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        userService.create(new Credential("jane", password));
        ArgumentCaptor<CredentialEntity> saved = ArgumentCaptor.forClass(CredentialEntity.class);
        verify(repository).save(saved.capture());
        return saved.getValue();
    }

    @Test
    void passwordIsStoredAsBcryptHash() {
        assertThat(createAndCaptureSaved("Jane123!").getPassword()).startsWith("$2a$");
    }

    @Test
    void emptyPasswordIsStoredAsNullWhenAllowed() {
        properties.getLogin().setAllowEmptyPassword(true);

        assertThat(createAndCaptureSaved("").getPassword()).isNull();
    }

    @Test
    void emptyPasswordIsRefusedOnCreateWhenNotAllowed() {
        when(repository.existsByUsername("jane")).thenReturn(false);

        assertThatThrownBy(() -> userService.create(new Credential("jane", "")))
                .isInstanceOf(BadRequestException.class)
                .hasMessage("Password must not be empty");
        verify(repository, never()).save(any());
    }

    @Test
    void emptyPasswordIsRefusedOnUpdateWhenNotAllowed() {
        CredentialEntity existing = new CredentialEntity();
        existing.setUuid("uuid-1");
        existing.setUsername("jane");
        existing.setPassword("$2a$04$existinghash");
        when(repository.findById("uuid-1")).thenReturn(Optional.of(existing));

        assertThatThrownBy(() -> userService.update("uuid-1", new Credential("jane", "")))
                .isInstanceOf(BadRequestException.class);
    }

    @Test
    void emptyPasswordClearsStoredPasswordOnUpdateWhenAllowed() {
        properties.getLogin().setAllowEmptyPassword(true);
        CredentialEntity existing = new CredentialEntity();
        existing.setUuid("uuid-1");
        existing.setUsername("jane");
        existing.setPassword("$2a$04$existinghash");
        when(repository.findById("uuid-1")).thenReturn(Optional.of(existing));

        userService.update("uuid-1", new Credential("jane", ""));

        assertThat(existing.getPassword()).isNull();
    }
}
