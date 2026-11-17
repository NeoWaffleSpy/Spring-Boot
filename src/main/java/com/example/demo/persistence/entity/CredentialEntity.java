package com.example.demo.persistence.entity;

import jakarta.persistence.CollectionTable;
import jakarta.persistence.Column;
import jakarta.persistence.ElementCollection;
import jakarta.persistence.Entity;
import jakarta.persistence.FetchType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.PrePersist;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;
import lombok.ToString;

/**
 * Maps the {@code credential} table.
 *
 * <p>Column names are set explicitly because some don't follow Spring's default
 * camelCase to snake_case naming (e.g. {@code nb_connection}).
 * The legacy {@code expirationdate} (bytea) column is intentionally not mapped;
 * {@code expiration_date} (timestamptz) is used instead.
 */
@Entity
@Table(name = "credential")
@Getter
@Setter
@NoArgsConstructor
@ToString(exclude = {"password", "roles"})
public class CredentialEntity {

    @Id
    @Column(name = "uuid", length = 255, nullable = false, updatable = false)
    private String uuid;

    @Column(name = "username", length = 255)
    private String username;

    @Column(name = "password", length = 255)
    private String password;

    @Column(name = "surname", length = 255)
    private String surname;

    @Column(name = "firstname", length = 255)
    private String firstname;

    @Column(name = "comment", length = 255)
    private String comment;

    @Column(name = "attempts")
    private Integer attempts;

    @Column(name = "locked")
    private Boolean locked;

    @Column(name = "nb_connection")
    private Integer nbConnections;

    @Column(name = "expiration_date", columnDefinition = "timestamp(6) with time zone")
    private OffsetDateTime expirationDate;

    /** Rows of {@code credential_roles}, linked by {@code credential_uuid}. */
    @ElementCollection(fetch = FetchType.EAGER)
    @CollectionTable(name = "credential_roles", joinColumns = @JoinColumn(name = "credential_uuid"))
    private List<CredentialRoleEmbeddable> roles = new ArrayList<>();

    @PrePersist
    void assignUuid() {
        if (uuid == null) {
            uuid = UUID.randomUUID().toString();
        }
    }
}
