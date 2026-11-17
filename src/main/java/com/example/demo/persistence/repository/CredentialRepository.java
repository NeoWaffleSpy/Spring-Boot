package com.example.demo.persistence.repository;

import com.example.demo.persistence.entity.CredentialEntity;
import java.util.Optional;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.stereotype.Repository;

@Repository
public interface CredentialRepository extends JpaRepository<CredentialEntity, String> {

    Optional<CredentialEntity> findByUsername(String username);

    boolean existsByUsername(String username);
}
