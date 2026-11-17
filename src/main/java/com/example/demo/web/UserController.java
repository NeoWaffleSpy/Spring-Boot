package com.example.demo.web;

import com.example.demo.api.UsersApi;
import com.example.demo.api.model.ApiResponseCredential;
import com.example.demo.api.model.ApiResponseCredentialList;
import com.example.demo.api.model.ApiResponseString;
import com.example.demo.api.model.Credential;
import com.example.demo.service.UserService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.RestController;

/** User management endpoints ({@code /users}). Paths and validation come from the generated {@link UsersApi}. */
@RestController
@RequiredArgsConstructor
public class UserController implements UsersApi {

    private final UserService userService;

    @Override
    public ResponseEntity<ApiResponseCredentialList> getAllUsers() {
        return ResponseEntity.ok(new ApiResponseCredentialList(HttpStatus.OK.value(), "Users retrieved successfully")
                .data(userService.findAll()));
    }

    @Override
    public ResponseEntity<ApiResponseCredential> getUserByUuid(String uuid) {
        return ok("User retrieved successfully", userService.findByUuid(uuid));
    }

    @Override
    public ResponseEntity<ApiResponseCredential> getUserByUsername(String username) {
        return ok("User retrieved successfully", userService.findByUsername(username));
    }

    @Override
    public ResponseEntity<ApiResponseCredential> createUser(Credential credential) {
        Credential created = userService.create(credential);
        return ResponseEntity.status(HttpStatus.CREATED)
                .body(new ApiResponseCredential(HttpStatus.CREATED.value(), "User created successfully").data(created));
    }

    @Override
    public ResponseEntity<ApiResponseCredential> updateUser(String uuid, Credential credential) {
        return ok("User updated successfully", userService.update(uuid, credential));
    }

    @Override
    public ResponseEntity<ApiResponseString> deleteUser(String uuid) {
        userService.delete(uuid);
        return ResponseEntity.ok(new ApiResponseString(HttpStatus.OK.value(), "User deleted successfully"));
    }

    private static ResponseEntity<ApiResponseCredential> ok(String message, Credential credential) {
        return ResponseEntity.ok(new ApiResponseCredential(HttpStatus.OK.value(), message).data(credential));
    }
}
