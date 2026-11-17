package com.example.demo.web;

import com.example.demo.api.AuthenticationApi;
import com.example.demo.api.model.ApiResponseString;
import com.example.demo.api.model.Login;
import com.example.demo.service.AuthService;
import io.jsonwebtoken.Claims;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.bind.annotation.RestController;

/** Login and logout endpoints ({@code /sessions}). Paths and validation come from the generated {@link AuthenticationApi}. */
@RestController
@RequiredArgsConstructor
public class CredentialController implements AuthenticationApi {

    private final AuthService authService;
    /** Request-scoped proxy injected by Spring; used only as a fallback for the client address. */
    private final HttpServletRequest request;

    @Override
    public ResponseEntity<ApiResponseString> loginSession(Login login, String xForwardedFor) {
        String clientIp = xForwardedFor != null ? xForwardedFor : request.getRemoteAddr();
        String token = authService.login(login.getUsername(), login.getPassword(), clientIp);
        return ResponseEntity.ok(new ApiResponseString(HttpStatus.OK.value(), "Authentication successful").data(token));
    }

    /** Requires a valid bearer token (enforced by SecurityConfig); that token is revoked. */
    @Override
    public ResponseEntity<ApiResponseString> logoutSession() {
        Authentication authentication = SecurityContextHolder.getContext().getAuthentication();
        authService.logout((Claims) authentication.getCredentials());
        return ResponseEntity.ok(new ApiResponseString(HttpStatus.OK.value(), "Logout successful"));
    }
}
