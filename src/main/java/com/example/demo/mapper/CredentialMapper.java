package com.example.demo.mapper;

import com.example.demo.api.model.Credential;
import com.example.demo.api.model.CredentialRole;
import com.example.demo.persistence.entity.CredentialEntity;
import com.example.demo.persistence.entity.CredentialRoleEmbeddable;
import java.util.List;
import org.mapstruct.BeanMapping;
import org.mapstruct.Mapper;
import org.mapstruct.Mapping;
import org.mapstruct.MappingTarget;
import org.mapstruct.NullValuePropertyMappingStrategy;

@Mapper
public interface CredentialMapper {

    /** API view of a user. The password hash is never sent back. */
    @Mapping(target = "password", ignore = true)
    Credential toApi(CredentialEntity entity);

    List<Credential> toApi(List<CredentialEntity> entities);

    /** New entity from a create request. UUID and password are set by the service. */
    @Mapping(target = "uuid", ignore = true)
    @Mapping(target = "password", ignore = true)
    CredentialEntity toEntity(Credential credential);

    /**
     * Applies an update request. UUID and password are handled by the service;
     * counters and flags left out of the request keep their current values.
     */
    @BeanMapping(nullValuePropertyMappingStrategy = NullValuePropertyMappingStrategy.IGNORE)
    @Mapping(target = "uuid", ignore = true)
    @Mapping(target = "password", ignore = true)
    void update(Credential credential, @MappingTarget CredentialEntity entity);

    CredentialRole toApi(CredentialRoleEmbeddable role);

    CredentialRoleEmbeddable toEmbeddable(CredentialRole role);
}
