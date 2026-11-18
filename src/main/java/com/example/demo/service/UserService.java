package com.example.demo.service;

import com.example.demo.api.model.Credential;
import com.example.demo.config.AuthorityProperties;
import com.example.demo.mapper.CredentialMapper;
import com.example.demo.persistence.entity.CredentialEntity;
import com.example.demo.persistence.repository.CredentialRepository;
import com.example.demo.service.exception.BadRequestException;
import com.example.demo.service.exception.NotFoundException;
import java.util.List;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Create, read, update and delete users (rows of the credential table). */
@Service
@RequiredArgsConstructor
public class UserService {

    private final CredentialRepository repository;
    private final CredentialMapper mapper;
    private final PasswordEncoder passwordEncoder;
    private final AuthorityProperties properties;

    @Transactional(readOnly = true)
    public List<Credential> findAll() {
        return mapper.toApi(repository.findAll());
    }

    @Transactional(readOnly = true)
    public Credential findByUuid(String uuid) {
        return mapper.toApi(loadByUuid(uuid));
    }

    @Transactional(readOnly = true)
    public Credential findByUsername(String username) {
        return repository.findByUsername(username)
                .map(mapper::toApi)
                .orElseThrow(() -> new NotFoundException("User not found: " + username));
    }

    @Transactional
    public Credential create(Credential request) {
        if (repository.existsByUsername(request.getUsername())) {
            throw new BadRequestException("Username already taken: " + request.getUsername());
        }
        CredentialEntity entity = mapper.toEntity(request);
        entity.setPassword(encodePassword(request.getPassword()));
        if (entity.getAttempts() == null) {
            entity.setAttempts(0);
        }
        if (entity.getLocked() == null) {
            entity.setLocked(false);
        }
        if (entity.getNbConnections() == null) {
            entity.setNbConnections(0);
        }
        return mapper.toApi(repository.save(entity));
    }

    @Transactional
    public Credential update(String uuid, Credential request) {
        CredentialEntity entity = loadByUuid(uuid);
        if (!entity.getUsername().equals(request.getUsername())
                && repository.existsByUsername(request.getUsername())) {
            throw new BadRequestException("Username already taken: " + request.getUsername());
        }
        mapper.update(request, entity);
        entity.setPassword(encodePassword(request.getPassword()));
        return mapper.toApi(entity);
    }

    @Transactional
    public void delete(String uuid) {
        repository.delete(loadByUuid(uuid));
    }

    /**
     * Hashes the password. An empty password is stored as null (the "no password" convention)
     * when {@code authority.login.allow-empty-password} is on, and refused otherwise.
     */
    private String encodePassword(String rawPassword) {
        if (rawPassword.isEmpty()) {
            if (!properties.getLogin().isAllowEmptyPassword()) {
                throw new BadRequestException("Password must not be empty");
            }
            return null;
        }
        return passwordEncoder.encode(rawPassword);
    }

    private CredentialEntity loadByUuid(String uuid) {
        return repository.findById(uuid)
                .orElseThrow(() -> new NotFoundException("User not found: " + uuid));
    }
}
